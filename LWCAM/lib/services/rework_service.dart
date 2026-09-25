// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart';

import '../models/node_config.dart';
import 'node_config_service.dart';
import 'pg_client.dart';
import 'pg_statements.dart' as st;

/// One outstanding recapture request: an image QC rejected, with everything the
/// capture side needs to re-photograph it and put the new file where LWIP will
/// pick it up.
class ReworkItem {
  final int reworkId;
  final String projectKey;
  final String projectId;
  final String boxName;
  final int folderSeq;
  final String folderName;

  /// The folder's PROCESSED (LWIP output) directory, as stored in
  /// capture_folders.folder_path. The input path is derived from it — see
  /// [ReworkService.inputFileFor].
  final String folderPath;
  final String qcStatus;
  final String imageName;
  final String reason;
  final String reworkType;
  final DateTime? requestedAt;
  final bool isCreatedThumbnail;

  /// The folder's CURRENT cloud metadata, column name → value (see
  /// [st.kFolderMetadataColumns]). QC edits these same columns, so the operator's
  /// edit form must be seeded from here rather than from LWCAM's local row —
  /// which still holds what was keyed at capture time and would revert QC's
  /// corrections. Repeated on every item of a folder; take the first.
  final Map<String, Object?> folderMetadata;

  /// 1-based page position of this image within its folder, and the folder's
  /// page count. Derived by the worklist query from (image_created_at, id) 鈥?
  /// the order QC itself pages a folder in, and the order the NEXT reviewer
  /// will see. 0 means unknown (an older query, or an image the folder scan
  /// could not place).
  ///
  /// It is the capture/DB page order, NOT a replay of what the rejecting
  /// reviewer saw: reject_task discards the draft without committing, so
  /// uncommitted reorders or deletions in that session are not reflected here.
  final int pageNumber;
  final int pageCount;

  const ReworkItem({
    required this.reworkId,
    required this.projectKey,
    required this.projectId,
    required this.boxName,
    required this.folderSeq,
    required this.folderName,
    required this.folderPath,
    required this.qcStatus,
    required this.imageName,
    required this.reason,
    required this.reworkType,
    this.requestedAt,
    this.isCreatedThumbnail = false,
    this.folderMetadata = const {},
    this.pageNumber = 0,
    this.pageCount = 0,
  });

  /// Groups items into one card per folder in the UI.
  String get folderKey => '$projectKey|$boxName|$folderSeq';

  /// `'07 / 24'`, or empty when the position is unknown. Two-digit padding, the
  /// same shape as the QC review rail's page badge.
  String get pageLabel =>
      pageNumber <= 0 ? '' : '${pageNumber.toString().padLeft(2, '0')} / $pageCount';
}

/// Reads the QC → capture recapture worklist from PostgreSQL, and resolves the
/// LWIP input file a recaptured image must overwrite.
///
/// Short-lived connections (the same pattern as [UserDirectoryService] and
/// DeviceRegistry): the worklist is opened by hand a few times a shift, so
/// there is no pooled connection worth holding.
class ReworkService {
  Future<Connection?> _open() async {
    if (!Get.isRegistered<NodeConfigService>()) return null;
    try {
      final config = await Get.find<NodeConfigService>().load();
      final host = config.pgHost?.trim() ?? '';
      if (!config.syncEnabled || host.isEmpty) return null;
      return await openPgConnection(
        host: host,
        port: config.pgPort,
        database: config.pgDatabase ?? '',
        user: config.pgUser ?? '',
        password: config.pgPassword ?? '',
        useSsl: config.pgUseSsl,
      );
    } catch (e) {
      print('ℹ️ Rework: PG unreachable ($e).');
      return null;
    }
  }

  /// The operator's outstanding requests, in folder page order within a folder.
  ///
  /// Throws when PostgreSQL is unreachable: an empty list would read as "no
  /// rework to do", which is a dangerous thing to show an operator when the
  /// truth is "we could not ask".
  Future<List<ReworkItem>> fetchOpenRework(String username) async {
    final conn = await _open();
    if (conn == null) {
      throw StateError(
          'Cannot reach the database. Rework requests come from QC — check the '
          'connection in LWCam Admin → Station Setup.');
    }
    try {
      final stmt = st.selectOpenReworkSql(username);
      final result = await conn.execute(
        Sql.named(stmt.sql),
        parameters: stmt.parameters,
      );
      final items = <ReworkItem>[];
      for (final row in result) {
        final folderPath = row[6]?.toString() ?? '';
        items.add(ReworkItem(
            reworkId: (row[0] as num).toInt(),
            projectKey: row[1]?.toString() ?? '',
            projectId: row[2]?.toString() ?? '',
            boxName: row[3]?.toString() ?? '',
            folderSeq: (row[4] as num?)?.toInt() ?? 0,
            folderName: row[5]?.toString() ?? '',
            folderPath: folderPath,
            qcStatus: row[7]?.toString() ?? '',
            imageName: row[8]?.toString() ?? '',
            reason: row[9]?.toString() ?? '',
            reworkType: row[10]?.toString() ?? '',
            requestedAt: row[11] is DateTime ? row[11] as DateTime : null,
            isCreatedThumbnail: await _thumbnailCreated(folderPath),
            // The metadata columns trail the 12 fixed ones, in
            // kFolderMetadataColumns order — see selectOpenReworkSql.
            folderMetadata: {
              for (var i = 0; i < st.kFolderMetadataColumns.length; i++)
                st.kFolderMetadataColumns[i]: row[12 + i],
            },
            // Trailing the metadata block, so both sides move together when a
            // 15th metadata column arrives.
            pageNumber:
                (row[12 + st.kFolderMetadataColumns.length] as num?)?.toInt() ??
                0,
            pageCount:
                (row[13 + st.kFolderMetadataColumns.length] as num?)?.toInt() ??
                0,
          ));
      }
      return items;
    } finally {
      try {
        await conn.close();
      } catch (_) {}
    }
  }

  Future<bool> _thumbnailCreated(String folderPath) async {
    if (folderPath.trim().isEmpty) return false;
    try {
      final manifest = jsonDecode(
          await File(p.join(folderPath, '.deskew_crop_manifest.json')).readAsString());
      final thumbnails = manifest is Map ? manifest['thumbnails'] : null;
      return thumbnails is Map && thumbnails['created'] == true;
    } catch (_) {
      return false;
    }
  }

  // ── Input-path resolution ────────────────────────────────────────────────

  /// LWIP's input root, as this station sees it.
  static String? effectiveInputRoot(NodeConfig config) {
    final explicit = config.processingInputRoot?.trim() ?? '';
    if (explicit.isNotEmpty) return explicit;
    final destination = config.destinationPath?.trim() ?? '';
    return destination.isEmpty ? null : destination;
  }

  /// LWIP's output root, as this station sees it.
  static String effectiveOutputRoot(NodeConfig config, String inputRoot) {
    final explicit = config.processingOutputRoot?.trim() ?? '';
    return explicit.isNotEmpty ? explicit : '${inputRoot}_processed';
  }

  /// The INPUT file a recaptured image must overwrite, or null when it cannot be
  /// resolved on this station.
  ///
  /// LWIP mirrors input to output, so the folder's path relative to the output
  /// root is also its path relative to the input root. Overwriting this file
  /// changes the folder's fingerprint, which is what makes LWIP reprocess it and
  /// ultimately flips qc_status back to PENDING.
  ///
  /// Returns null when the station's roots are unconfigured or when
  /// [folderPath] sits outside this station's output root — i.e. the folder was
  /// captured elsewhere and cannot be reworked here.
  static File? inputFileFor(
    NodeConfig config, {
    required String folderPath,
    required String imageName,
  }) {
    final inputRoot = effectiveInputRoot(config);
    if (inputRoot == null || folderPath.trim().isEmpty || imageName.trim().isEmpty) {
      return null;
    }
    final outputRoot = effectiveOutputRoot(config, inputRoot);
    final normalizedFolder = p.normalize(folderPath);
    final normalizedOutput = p.normalize(outputRoot);
    if (!p.isWithin(normalizedOutput, normalizedFolder)) return null;
    final relative = p.relative(normalizedFolder, from: normalizedOutput);
    return File(p.join(inputRoot, relative, imageName));
  }
}
