// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../db/upload_stats_db.dart';

/// Tails LWIP's completion journal (`state.json`) and reports each finished
/// folder into the DB exactly once. For every completed, non-retry entry not
/// already in the processing ledger, it reads the output manifest, requires a
/// matching fingerprint and a usable `source_identity` (the marker LWCAM
/// wrote), then calls [UploadStatsDB.recordFolderProcessing] — which updates
/// local pipeline columns and enqueues the `capture_folder_processing` outbox
/// row the existing SyncService drains. One DB-write code path.
class ProcessingReportService extends GetxController {
  final UploadStatsDB db;
  final String deviceId;
  final String stateFilePath;
  final Duration tickInterval;

  Timer? _timer;
  bool _ticking = false;

  /// Suspends the tick without tearing the timer down. Set while the device DB
  /// is being rebuilt — this service reopens the same file every 15s on a
  /// co-located capture+processing station, which would race the promotion.
  bool paused = false;

  ProcessingReportService({
    required this.db,
    required this.deviceId,
    required this.stateFilePath,
    this.tickInterval = const Duration(seconds: 15),
  });

  @override
  void onInit() {
    super.onInit();
    _timer = Timer.periodic(tickInterval, (_) => pollOnce());
    pollOnce();
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }

  static const String _manifestName = '.deskew_crop_manifest.json';

  /// One scan of the state journal. Reentrancy-guarded (a slow scan never
  /// overlaps the next timer fire). Never throws.
  Future<void> pollOnce() async {
    if (paused || _ticking) return;
    _ticking = true;
    try {
      final completed = await _readCompleted();
      for (final entry in completed.entries) {
        final inputPath = entry.key;
        final record = entry.value;
        if (record is! Map) continue;
        if (record['retry_required'] == true) continue;
        final fingerprint = record['fingerprint']?.toString() ?? '';
        final outputFolder = record['output_folder']?.toString() ?? '';
        if (fingerprint.isEmpty || outputFolder.isEmpty) continue;

        if (await db.isProcessingReported(
            inputPath: inputPath, fingerprint: fingerprint)) {
          continue;
        }

        final manifest = await _readManifest(outputFolder);
        if (manifest == null) continue; // not readable yet — next tick
        // Output must correspond to THIS completion (the journal entry is
        // written only after the atomic publish, but guard anyway).
        if (manifest['source_fingerprint']?.toString() != fingerprint) continue;

        final identity = manifest['source_identity'];
        final hasIdentity = identity is Map &&
            (identity['project_key']?.toString().isNotEmpty ?? false) &&
            (identity['box_name']?.toString().isNotEmpty ?? false) &&
            identity['folder_seq'] != null;
        if (!hasIdentity) {
          print('⚠️ Processed folder has no usable identity marker — not '
              'reporting: $outputFolder');
          await db.recordProcessingSkip(
              inputPath: inputPath, fingerprint: fingerprint);
          continue;
        }

        final thumbs = manifest['thumbnails'];
        final created = thumbs is Map && thumbs['created'] == true;
        final dirName =
            (thumbs is Map ? thumbs['dirname']?.toString() : null) ?? 'thumbs';
        // Must match LWIP's own writer (cloud_report.py) exactly: NULL when
        // thumbnails were not created, never a path that doesn't exist.
        final thumbnailPath = created ? p.join(outputFolder, dirName) : null;

        await db.recordFolderProcessing(
          deviceId: deviceId,
          identity: Map<String, dynamic>.from(identity),
          folderPath: outputFolder,
          thumbnailPath: thumbnailPath,
          isCreatedThumbnail: created,
          inputPath: inputPath,
          fingerprint: fingerprint,
        );
        print('🖼️ Reported processed folder to the DB: $outputFolder');
      }
    } catch (e) {
      print('⚠️ Processing report tick failed: $e');
    } finally {
      _ticking = false;
    }
  }

  Future<Map<String, dynamic>> _readCompleted() async {
    try {
      final f = File(stateFilePath);
      if (!await f.exists()) return const {};
      final data = jsonDecode(await f.readAsString());
      if (data is! Map) return const {};
      final completed = data['completed'];
      return completed is Map ? Map<String, dynamic>.from(completed) : const {};
    } catch (_) {
      return const {}; // torn/partial (LWIP writes atomically) — next tick
    }
  }

  Future<Map<String, dynamic>?> _readManifest(String outputFolder) async {
    try {
      final f = File(p.join(outputFolder, _manifestName));
      if (!await f.exists()) return null;
      final data = jsonDecode(await f.readAsString());
      return data is Map ? Map<String, dynamic>.from(data) : null;
    } catch (_) {
      return null;
    }
  }
}
