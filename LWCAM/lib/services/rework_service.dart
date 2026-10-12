// ignore_for_file: avoid_print

// Recapture side of QC rejects in LWCAM: reads the list of images the QC
// Platform sent back, and finds the LWIP input file each new photo replaces.
// Used by the rework flow in the box list and gallery.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart';

import '../models/node_config.dart';
import 'fs_probe.dart';
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
  /// Whether LWIP made thumbnails for this folder; null when this PC cannot
  /// read LWIP's manifest (then the PG column is left untouched).
  final bool? isCreatedThumbnail;

  /// The folder's CURRENT cloud metadata, column name → value (see
  /// [st.kFolderMetadataColumns]). QC edits these same columns, so the operator's
  /// edit form must be seeded from here rather than from LWCAM's local row —
  /// which still holds what was keyed at capture time and would revert QC's
  /// corrections. Repeated on every item of a folder; take the first.
  final Map<String, Object?> folderMetadata;

  /// 1-based page position of this image within its folder, and the folder's
  /// page count. Derived by the worklist query from (image_created_at, id) —
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
    this.isCreatedThumbnail,
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
      NodeConfig? config;
      try {
        config = await Get.find<NodeConfigService>().load();
      } catch (_) {}
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
            isCreatedThumbnail: await _thumbnailCreated(config, folderPath),
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

  /// LWIP's manifest says whether it made thumbnails. It lives in LWIP's OUTPUT
  /// folder, which is only reachable here as [NodeConfig.processingOutputRoot]
  /// + the folder's `<date>\<folder>` tail (the same tail-swap as
  /// [inputFileFor]) or, on a one-PC station, LWIP's own path. Null when
  /// neither can be read - the caller must then NOT write the column, because
  /// false would wrongly claim "no thumbnails" for a folder that has them.
  static Future<bool?> _thumbnailCreated(
    NodeConfig? config,
    String folderPath,
  ) async {
    if (folderPath.trim().isEmpty) return null;
    final outputRoot = config?.processingOutputRoot?.trim() ?? '';
    final tail = _dateTail(folderPath);
    final candidates = [
      if (outputRoot.isNotEmpty && tail != null) p.joinAll([outputRoot, ...tail]),
      folderPath,
    ];
    for (final dir in candidates) {
      final file = File(p.join(dir, '.deskew_crop_manifest.json'));
      if (await probeExists(file) != FsProbe.found) continue;
      try {
        final manifest = jsonDecode(await file.readAsString().timeout(kFsProbeTimeout));
        final thumbnails = manifest is Map ? manifest['thumbnails'] : null;
        return thumbnails is Map && thumbnails['created'] == true;
      } catch (_) {
        continue;
      }
    }
    return null;
  }

  @visibleForTesting
  static Future<bool?> thumbnailCreatedForTest(NodeConfig? c, String folderPath) =>
      _thumbnailCreated(c, folderPath);

  /// `<date>\<folder>` from LWIP's folder path, or null. The date is searched
  /// from the END and must have a folder after it (a Volume can itself be
  /// eight digits). Any `..`, drive letter or NUL in the tail refuses.
  static List<String>? _dateTail(String folderPath) {
    final segments = folderPath
        .trim()
        .split(RegExp(r'[\\/]+'))
        .where((segment) => segment.isNotEmpty)
        .toList();
    for (var i = segments.length - 2; i >= 0; i--) {
      if (_dateSegment.hasMatch(segments[i])) {
        final tail = segments.sublist(i);
        if (tail.any((s) => s == '..' || s.contains(':') || s.contains('\x00'))) {
          return null;
        }
        return tail;
      }
    }
    return null;
  }

  // ── Input-path resolution ────────────────────────────────────────────────

  /// The INPUT file a recaptured image must overwrite, or null when it is not
  /// on this station. Overwriting it changes the folder's fingerprint, which is
  /// what makes LWIP reprocess it and flips qc_status back to PENDING.
  ///
  /// [folderPath] is where LWIP put the processed folder, spelt as LWIP's own
  /// PC sees it (`C:\LWIP\2.Batches\20260924\<folder>`) - often not a path
  /// this PC can open. What it shares with the original is its tail: LWIP
  /// mirrors its input, so `<date>\<folder>` under its output is the same
  /// under its input, and its input is this station's own image destination,
  /// where the originals were copied. Keep the tail, swap the head - the rule
  /// QC's `relocate_under` uses. (Until 2026-09-28 Station Setup asked for
  /// both LWIP folders instead, and the output one had to be typed exactly as
  /// LWIP spells it, which its label said the opposite of.)
  ///
  /// The date is searched from the END and must have a folder after it: a
  /// Volume, and so a folder name, can itself be eight digits (`19450512`).
  ///
  /// [ReworkInput.status] keeps three cases apart: found, not found, and the
  /// share could not be asked in time ([FsProbe.unreachable] - LWIP's input
  /// share is down; the UI must not blame "another station" for that).
  /// Async and time-bounded: this used to be a sync existsSync() on a UNC path
  /// called from build code, freezing the window for the SMB timeout.
  ///
  /// The file is null unless it was found: a recapture REPLACES an original,
  /// and a folder captured on a station with another destination is not here
  /// to replace - writing to a guessed path could clobber an unrelated image.
  static Future<ReworkInput> inputFileFor(
    NodeConfig config, {
    required String folderPath,
    required String imageName,
  }) async {
    final destination = config.destinationPath?.trim() ?? '';
    if (destination.isEmpty || imageName.trim().isEmpty) return ReworkInput.none;
    // Both values come from the database (another PC wrote them): a plain
    // file name only, and no `..` or drive letter anywhere in the tail.
    if (imageName != p.basename(imageName) ||
        imageName.contains(RegExp(r'[\\/:\x00-\x1f]')) ||
        imageName.contains('..')) {
      return ReworkInput.none;
    }
    final tail = _dateTail(folderPath);
    if (tail == null) return ReworkInput.none;
    final path = p.joinAll([destination, ...tail, imageName]);
    if (!p.isWithin(destination, path)) return ReworkInput.none;
    final file = File(path);
    switch (await probeExists(file)) {
      case FsProbe.found:
        return ReworkInput(FsProbe.found, file);
      case FsProbe.notFound:
        return ReworkInput.none;
      case FsProbe.unreachable:
        return const ReworkInput(FsProbe.unreachable, null);
    }
  }

  static final _dateSegment = RegExp(r'^\d{8}$');
}

/// Result of [ReworkService.inputFileFor].
class ReworkInput {
  final FsProbe status;
  final File? file;
  const ReworkInput(this.status, this.file);

  /// Not resolvable here: no destination, a bad path, or the file is absent.
  static const none = ReworkInput(FsProbe.notFound, null);

  bool get unreachable => status == FsProbe.unreachable;
}
