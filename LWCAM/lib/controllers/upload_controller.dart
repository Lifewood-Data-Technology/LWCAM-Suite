// Transfer engine of the capture app (LWCAM). Takes the staged photos and copies
// them into the destination folder that the next pipeline stage (LWIP deskew/
// crop) watches, one YYYYMMDD folder per day. In box mode each keyed folder
// gets its own subfolder and its metadata goes into the CSV and database rows.
// Things to know before editing: a reconnect after a dropped share does not
// use up one of the 3 attempts per file (but is capped), a copy counts only
// after its size is verified, and Normal Mode (keying off) must behave as it
// always did, so every box-mode difference sits behind `if (box != null)`.
// ignore_for_file: unnecessary_brace_in_string_interps, avoid_print, unused_field

import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:lwcam/pages/upload_status_page.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:lwcam/pages/settings_page.dart';
import 'package:lwcam/auth/auth_controller.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/models/batch_metadata.dart' show csvEscape;
import 'package:lwcam/models/metadata_template.dart' show kFixedFieldCsvColumns;
import 'package:lwcam/services/windows_notification_service.dart';
import 'package:lwcam/services/audit_log_service.dart';
import 'package:lwcam/services/file_lock_service.dart';
import 'package:lwcam/services/safe_copy.dart';
import 'package:lwcam/services/transfer_alert_presenter.dart';
import 'package:lwcam/services/fs_probe.dart';
import 'package:lwcam/services/transfer_destination_service.dart';
import 'package:lwcam/theme/app_colors.dart';

/// One keyed folder of a capture box: its destination subfolder name plus the
/// metadata stamped on every image row it owns (Box→Folders workflow).
class BoxFolderInfo {
  final String folderName;
  final String? coverTag;
  final String? imageTags;
  final String? title;
  final String? volume;
  final String? startDate;
  final String? endDate;
  final String? archivalRefNo;
  final String? recordType;

  /// The template's fixed-field values (see kFixedFieldCsvColumns), keyed by
  /// CSV/DB column name, resolved for THIS folder. Per-folder (not per-box)
  /// because a §8.3 field can be MAPPED from a keyed field (e.g. Language
  /// mapped from Title) and so can vary folder-to-folder.
  final Map<String, String?> fixedFieldValues;

  const BoxFolderInfo({
    required this.folderName,
    this.coverTag,
    this.imageTags,
    this.title,
    this.volume,
    this.startDate,
    this.endDate,
    this.archivalRefNo,
    this.recordType,
    this.fixedFieldValues = const {},
  });
}

/// Marks a call to [UploadController.uploadAll] as a capture-box transfer
/// (Box→Folders workflow, metadata keying ON). Guarded `if (box != null)`
/// branches are the ONLY behavior differences: images land in one destination
/// subfolder per keyed folder, and CSV/DB rows carry the owning folder's
/// metadata.
class BoxTransferContext {
  final int boxId;
  final String boxDetails;

  /// Keyed by staged SOURCE basename (the device filename each staged file
  /// keeps) → the owning folder's info.
  final Map<String, BoxFolderInfo> infoBySourceName;

  const BoxTransferContext({
    required this.boxId,
    required this.boxDetails,
    required this.infoBySourceName,
  });
}

/// Outcome of one [UploadController.uploadAll] batch.
class UploadBatchResult {
  final int completed;
  final int failed;
  final int missing;
  final int sizeMismatch;
  final int totalQueued;

  const UploadBatchResult({
    required this.completed,
    required this.failed,
    required this.missing,
    required this.sizeMismatch,
    required this.totalQueued,
  });

  bool get isFullSuccess =>
      failed == 0 &&
      missing == 0 &&
      sizeMismatch == 0 &&
      completed == totalQueued;
}

/// Thrown when a transfer is interrupted by an I/O / connection issue
class UploadInterruptionException implements Exception {
  final String message;
  UploadInterruptionException(this.message);

  @override
  String toString() => message;
}

/// Thrown when a transfer timeout occurs
class TransferTimeoutException implements Exception {
  final String message;
  final String filename;
  TransferTimeoutException(this.message, {required this.filename});

  @override
  String toString() => message;
}

/// Thrown when transfer stalls (no progress for X seconds)
class TransferStallException implements Exception {
  final String message;
  final String filename;
  TransferStallException(this.message, {required this.filename});

  @override
  String toString() => message;
}

// ========== TRANSFER TIMEOUTS & STALL DETECTION ==========
const Duration _copyOperationTimeout = Duration(minutes: 10);
const Duration _stallTimeout = Duration(seconds: 30);
const int _stallCheckIntervalMs = 5000;

/// Reconnect cycles allowed per file before an interruption is treated as an
/// ordinary failed attempt. A reconnect deliberately does NOT consume one of
/// the 3 attempts (waiting out a flaky NAS is not a failure), but it has to be
/// bounded — an unbounded resume loop can never leave the attempt.
const int _maxReconnectsPerFile = 10;

class _BatchArtifacts {
  final String operatorId;
  final DateTime startTime;
  final int totalQueued;
  final File localCsvFile;
  final File localTransferRecordsTxtFile;
  final File localSummaryLogFile;
  final File localErrorLogFile;
  final File localInterruptionLogFile;
  final File localTransferLogFile;

  const _BatchArtifacts({
    required this.operatorId,
    required this.startTime,
    required this.totalQueued,
    required this.localCsvFile,
    required this.localTransferRecordsTxtFile,
    required this.localSummaryLogFile,
    required this.localErrorLogFile,
    required this.localInterruptionLogFile,
    required this.localTransferLogFile,
  });
}

/// Copies staged photos to the transfer destination (a share or drive that the
/// next stage reads from) with progress, retries, reconnect handling and size
/// verification, and writes the per-batch CSV and logs. Despite the name this
/// is the local transfer step, not the S3 upload service.
class UploadController extends GetxController {
  final SettingsController s = Get.find<SettingsController>();
  final AuthController auth = Get.find<AuthController>();
  final FileLockService fileLockService = FileLockService();

  AuditLogService? get _auditOrNull =>
      Get.isRegistered<AuditLogService>() ? Get.find<AuditLogService>() : null;

  var files = <File>[]; // source files queued
  var isUploading = false.obs;
  var progress =
      0.0.obs; // overall upload progress (0–1, avg of file progresses)
  var statusMessage = "".obs;
  var uploads = <UploadStatus>[].obs;

  /// Where this batch's critical-error/reconnect/summary alerts go — set at
  /// the top of [uploadAll] from its `alerts` param, reset to the default in
  /// `finally`. Normal Mode never passes one, so [DialogAlertPresenter] (byte-
  /// identical to the original always-modal behavior) is always in effect
  /// there.
  TransferAlertPresenter _currentAlerts = const DialogAlertPresenter();

  Future<void> _logAlert({
    required String title,
    required String message,
    bool warning = false,
    bool error = false,
    bool interruption = false,
  }) async {
    final prefix = warning ? '⚠️' : 'ℹ️';
    final logLine = "[${DateTime.now()}] $prefix $title - $message\n";

    try {
      await _appendLog(logLine);
      if (error) {
        await _appendError(logLine);
      }
      if (interruption) {
        await _appendInterruption(logLine);
      }
    } catch (_) {
      // Ignore logging failures to avoid cascading errors.
    }

    try {
      await _showWindowsNotificationPopup(
        title: title,
        message: message,
        warning: warning,
      );
    } catch (_) {
      // Ignore notification failures.
    }
  }

  // 🔹 NEW: preparing state
  var isPreparing = false.obs;
  var preparingCurrent = 0.obs;
  var preparingTotal = 0.obs;
  var preparingLabel = "".obs;

  _BatchArtifacts? _currentBatchArtifacts;
  // Tracks whether the in-flight/most recent batch was a capture-box
  // transfer, so the manual single-file retryUpload() (triggered from the
  // "Upload Failed" dialog, well after uploadAll's own box parameter is out
  // of scope) reads the same folder mapping instead of misdirecting the
  // retried file.
  BoxTransferContext? _currentBox;

  /// The day dir the current/last batch landed in, so a box-mode retryUpload
  /// goes back into the same dir instead of today's.
  Directory? _currentDestDir;
  Future<void> _artifactWriteQueue = Future.value();

  /// The folder info owning [srcFile] in a box transfer, else null.
  BoxFolderInfo? _boxInfoFor(File srcFile) =>
      _currentBox?.infoBySourceName[p.basename(srcFile.path)];

  /// Destination path for a file: inside its folder's subdir in box mode,
  /// directly in [destDir] otherwise (Normal Mode unchanged).
  String _destPathFor(Directory destDir, File srcFile, String filename) {
    final sub = _boxInfoFor(srcFile)?.folderName;
    return (sub == null || sub.isEmpty)
        ? p.join(destDir.path, filename)
        : p.join(destDir.path, sub, filename);
  }

  int _compareFilesByName(File a, File b) {
    return p
        .basename(a.path)
        .toLowerCase()
        .compareTo(p.basename(b.path).toLowerCase());
  }

  Future<void> _runSerializedArtifactWrite(Future<void> Function() action) {
    _artifactWriteQueue = _artifactWriteQueue
        .catchError((_) {})
        .then((_) => action());
    return _artifactWriteQueue;
  }

  // ---------------------- PREPARING STATE API --------------------------
  void startPreparing({
    int total = 0,
    String label = "Preparing items for upload…",
  }) {
    isPreparing.value = true;
    preparingCurrent.value = 0;
    preparingTotal.value = total;
    preparingLabel.value = label;
  }

  /// Call this from your ADB/prepareFiles logic to show real numbers.
  /// Example: updatePreparing(current: 5, total: 40, label: "Pulling from device…");
  void updatePreparing({int? current, int? total, String? label}) {
    if (current != null) preparingCurrent.value = current;
    if (total != null) preparingTotal.value = total;
    if (label != null && label.isNotEmpty) preparingLabel.value = label;
  }

  void finishPreparing() {
    isPreparing.value = false;
    preparingLabel.value = "";
    preparingCurrent.value = 0;
    preparingTotal.value = 0;
  }

  // ---------------------- PREPARE UPLOADS --------------------------
  void prepareUploads(List<File> newFiles) {
    files.clear();
    uploads.clear();

    final sortedFiles = [...newFiles]..sort(_compareFilesByName);
    files.addAll(sortedFiles);

    for (final file in sortedFiles) {
      uploads.add(
        UploadStatus(filename: file.uri.pathSegments.last, size: "…"),
      );
    }
    // Sizes are display-only — stat asynchronously instead of one
    // lengthSync per file on the UI isolate.
    unawaited(_fillUploadSizes(sortedFiles));

    progress.value = 0.0;
    statusMessage.value = "Ready to upload ${files.length} files";
  }

  Future<void> _fillUploadSizes(List<File> sortedFiles) async {
    for (var i = 0; i < sortedFiles.length && i < uploads.length; i++) {
      try {
        final kb = await sortedFiles[i].length() / 1024;
        uploads[i].size = "${kb.toStringAsFixed(1)} KB";
      } catch (_) {
        // File vanished — the upload itself will surface the real error.
      }
    }
    uploads.refresh();
  }

  void addFiles(List<File> newFiles) => prepareUploads(newFiles);

  // ---------------------- MAIN UPLOAD METHOD --------------------------
  /// [destinationDir] — box mode passes the box's persisted day dir (decided
  /// once per box by UploadStatsDB.markCaptureBoxTransferStarted, so a retry
  /// never opens a second YYYYMMDD dir for the same folders). Normal Mode
  /// leaves it null and lands on today's.
  Future<UploadBatchResult?> uploadAll({
    required String boxDetails,
    BoxTransferContext? box,
    TransferAlertPresenter? alerts,
    Directory? destinationDir,
  }) async {
    _currentAlerts = alerts ?? const DialogAlertPresenter();
    finishPreparing();

    if (files.isEmpty) {
      showStatus("No files to upload");
      return null;
    }
    if (s.destinationPath.value.isEmpty) {
      showStatus(
        "Destination not configured — set it in LWCam Admin's Station Setup.",
      );
      return null;
    }

    final startTime = DateTime.now();
    final operatorId = auth.deviceId.value.trim().isEmpty
        ? 'UNKNOWN'
        : auth.deviceId.value.trim();

    final destDir = destinationDir != null
        ? await destinationDir.create(recursive: true)
        : await TransferDestinationService.ensureDirectoryForDate(
            s.destinationPath.value,
            startTime,
          );
    _currentDestDir = destDir;

    final logsDir = Directory(p.join(destDir.path, 'logs'));
    if (!await logsDir.exists()) await logsDir.create(recursive: true);

    // Box mode: images land in one subfolder per keyed folder (CSV + logs stay
    // at the date level, exactly like Normal Mode).
    if (box != null) {
      final distinctSubdirs = box.infoBySourceName.values
          .map((i) => i.folderName)
          .toSet();
      for (final sub in distinctSubdirs) {
        if (sub.isEmpty) continue;
        final d = Directory(p.join(destDir.path, sub));
        if (!await d.exists()) await d.create(recursive: true);
      }
    }

    await _auditOrNull?.log(
      AuditActions.transferStart,
      details: {'files': files.length, 'box': boxDetails},
    );

    isUploading.value = true;
    progress.value = 0.0;
    _updateOverallProgress();

    final batchTimestamp = DateTime.now()
        .toIso8601String()
        .replaceAll(':', '-')
        .replaceAll('.', '_');

    final artifactPrefix = operatorId;

    final csvFileName = '${artifactPrefix}_upload_records_$batchTimestamp.csv';
    final transferRecordsTxtName =
        '${artifactPrefix}_transfer_records_$batchTimestamp.txt';
    final summaryLogName = '${artifactPrefix}_summary_log_$batchTimestamp.txt';
    final errorLogName = '${artifactPrefix}_error_log_$batchTimestamp.txt';
    final interruptionLogName =
        '${artifactPrefix}_interruption_log_$batchTimestamp.txt';
    final transferLogName =
        '${artifactPrefix}_transfer_log_$batchTimestamp.txt';

    final artifacts = _BatchArtifacts(
      operatorId: operatorId,
      startTime: startTime,
      totalQueued: uploads.length,
      localCsvFile: File(p.join(destDir.path, csvFileName)),
      localTransferRecordsTxtFile: File(
        p.join(destDir.path, transferRecordsTxtName),
      ),
      localSummaryLogFile: File(p.join(logsDir.path, summaryLogName)),
      localErrorLogFile: File(p.join(logsDir.path, errorLogName)),
      localInterruptionLogFile: File(p.join(logsDir.path, interruptionLogName)),
      localTransferLogFile: File(p.join(logsDir.path, transferLogName)),
    );
    _currentBatchArtifacts = artifacts;
    _currentBox = box;

    await _initializeBatchArtifacts(
      artifacts,
      boxDetails: boxDetails,
      box: box,
    );

    const int maxConcurrent = 12;
    final tasks = <Future>[];
    int completed = 0;
    int failed = 0;

    final statsDb = UploadStatsDB();
    TransferProtectionHandle? dbProtection;

    try {
      dbProtection = await statsDb.acquireTransferProtection(
        deviceId: auth.deviceId.value,
        scanningOpr: auth.username.value,
      );
      await _appendLog(
        "[${DateTime.now()}] 🔒 Database transfer protection acquired for device ${auth.deviceId.value}.\n",
      );
    } catch (e) {
      isUploading.value = false;
      _updateOverallProgress();
      await _appendInterruption(
        "[${DateTime.now()}] ❌ Failed to acquire database transfer protection: $e\n",
      );
      showStatus("Database protection could not be enabled");
      await _showWindowsNotificationPopup(
        title: 'LWCAM',
        message:
            'Transfer could not start because database protection could not be enabled for ${auth.deviceId.value}.',
        warning: true,
      );
      await _auditOrNull?.log(
        AuditActions.transferFailed,
        details: {'reason': 'db_protection_failed', 'box': boxDetails},
      );
      _currentBatchArtifacts = null;
      _currentBox = null;
      return null;
    }

    try {
      final overwriteExisting = s.includeUploaded.value;
      final uploadedBaseNamesRaw = await UploadStatsDB().getUploadedBaseNames(
        auth.deviceId.value,
      );
      // Full recorded filenames — a destination file NOT in this set is not
      // ours to overwrite (another PC's image, or a pre-.part torn copy):
      // the name allocator skips it to the next _NNN suffix and logs it.
      final recordedFilenames = await UploadStatsDB().getUploadedFilenames(
        auth.deviceId.value,
      );

      String _normalizeBaseName(String name) {
        var n = name.trim();
        final dotIdx = n.lastIndexOf('.');
        if (dotIdx != -1) {
          n = n.substring(0, dotIdx);
        }
        n = n.replaceFirst(RegExp(r'_\d{3}$'), '');
        return n;
      }

      final uploadedBaseNames = uploadedBaseNamesRaw
          .map((e) => _normalizeBaseName(e))
          .toSet();

      // ========== LOCK SOURCE FILES TO PREVENT MODIFICATIONS ==========
      await _appendLog(
        "[${DateTime.now()}] 🔒 Attempting to lock source files...\n",
      );

      for (final file in files) {
        if (fileLockService.isLockableFile(file.path)) {
          try {
            await fileLockService.acquireLock(file.path);
            await _appendLog(
              "[${DateTime.now()}] 🔒 Locked source file: ${p.basename(file.path)}\n",
            );
          } catch (lockError) {
            await _showCriticalErrorDialog(
              title: '🔒 FILE IS IN USE',
              message:
                  '${p.basename(file.path)}\n\n'
                  'This file is currently open or locked.\n\n'
                  'Action: Close the file and retry the transfer.',
            );
            await _appendError(
              "[${DateTime.now()}] ❌ Could not lock file: ${file.path}\n$lockError\n",
            );
            await _auditOrNull?.log(
              AuditActions.transferFailed,
              details: {
                'reason': 'file_lock_failed',
                'file': p.basename(file.path),
                'box': boxDetails,
              },
            );
            isUploading.value = false;
            _updateOverallProgress();
            return null;
          }
        }
      }

      final usedNames = <String>{};

      for (int i = 0; i < files.length; i++) {
        final srcFile = files[i];

        final date = await _getImageDate(srcFile);
        final formatted = _formatDate(date);
        final ext = p.extension(srcFile.path).toLowerCase();
        final baseName = "${auth.deviceId.value}_IMG_${formatted}";
        final isAlreadyInDb = uploadedBaseNames.contains(baseName);

        // Box mode: name uniqueness is resolved inside the file's folder
        // subdir (where it will actually land). uploads[i].filename stays the
        // BARE generated name — every consumer joins the subdir via
        // _destPathFor, keeping DB/CSV rows and dedup regexes unchanged.
        final boxSub =
            box?.infoBySourceName[p.basename(srcFile.path)]?.folderName;
        final effectiveDestDir = (boxSub == null || boxSub.isEmpty)
            ? destDir
            : Directory(p.join(destDir.path, boxSub));

        final destFile = await _resolveTargetFileForBaseName(
          destDir: effectiveDestDir,
          baseName: baseName,
          ext: ext,
          reservedNames: usedNames,
          overwriteExisting: overwriteExisting,
          alreadyInDb: isAlreadyInDb,
          recordedFilenames: recordedFilenames,
        );

        uploads[i].filename = p.basename(destFile.path);
      }

      // NOTE: crash/restart recovery is carried by the per-file DB records
      // (written only after a verified copy) + the batch-start skip logic +
      // the orphan-overwrite rule in generateUniqueTargetFile — a JSON
      // resume-by-index checkpoint used to live here, but names are
      // allocated fresh from disk state each run, so a saved index could
      // never match after a real restart.
      for (int i = 0; i < files.length; i++) {
        final index = i;
        tasks.add(
          _uploadSingleFile(index, boxDetails, destDir, artifacts)
              .then((_) async {
                completed++;
                showStatus("Uploaded $completed/${uploads.length}");
              })
              .catchError((e) async {
                failed++;
                final safeName = (index >= 0 && index < files.length)
                    ? files[index].uri.pathSegments.last
                    : 'unknown';
                await _appendError(
                  "[${DateTime.now()}] ❌ Error uploading $safeName: $e\n",
                );
              }),
        );

        if (tasks.length >= maxConcurrent) {
          await Future.wait(tasks);
          tasks.clear();
        }
      }

      if (tasks.isNotEmpty) await Future.wait(tasks);
      await _artifactWriteQueue;

      final endTime = DateTime.now();
      final totalDuration = endTime.difference(startTime);

      int missing = 0;
      int sizeMismatch = 0;
      final missingFiles = <String>[];
      final sizeMismatchFiles = <String>[];

      for (int i = 0; i < uploads.length; i++) {
        final u = uploads[i];
        final src = files[i];
        final dest = File(_destPathFor(destDir, src, u.filename));

        // Async stats: the destination is typically a NAS — synchronous
        // exists/length here blocked the UI isolate once per file (and for
        // tens of seconds each on a flaky share).
        if (!await dest.exists()) {
          missing++;
          missingFiles.add(u.filename);
          final msg =
              "[${DateTime.now()}] ⚠️ Missing file after upload: ${u.filename}\n";
          await _appendLog(msg);
          await _appendError(msg);
        } else {
          final srcLenVerify = await src.length();
          final destLenVerify = await dest.length();
          if (srcLenVerify != destLenVerify) {
            sizeMismatch++;
            sizeMismatchFiles.add(u.filename);
            final msg =
                "[${DateTime.now()}] ⚠️ Size mismatch after upload: ${u.filename} ($srcLenVerify vs $destLenVerify)\n";
            await _appendLog(msg);
            await _appendError(msg);
            try {
              await dest.delete();
            } catch (_) {}
          }
        }
      }

      await _appendSummary(
        "\nVerification Summary:\n"
        "Missing Files: $missing\n"
        "Size Mismatches: $sizeMismatch\n"
        "--------------------------------------------------\n",
      );

      if (missingFiles.isNotEmpty || sizeMismatchFiles.isNotEmpty) {
        final buf = StringBuffer();
        buf.writeln("\nProblem Files Detail:");
        if (missingFiles.isNotEmpty) {
          buf.writeln("Missing:");
          for (final name in missingFiles) {
            buf.writeln("  - $name");
          }
        }
        if (sizeMismatchFiles.isNotEmpty) {
          buf.writeln("Size mismatches (file deleted, not transferred):");
          for (final name in sizeMismatchFiles) {
            buf.writeln("  - $name");
          }
        }
        buf.writeln("--------------------------------------------------");
        await _appendSummary(buf.toString());
      }

      await _appendSummary(
        "\nFinal Transfer Summary:\n"
        "Start Time: ${startTime.toIso8601String()}\n"
        "End Time:   ${endTime.toIso8601String()}\n"
        "Total Duration: ${totalDuration.inMinutes} min ${totalDuration.inSeconds % 60} sec\n"
        "Total Files Queued: ${uploads.length}\n"
        "Successful Transfers: $completed\n"
        "Failed Transfers: $failed\n"
        "--------------------------------------------------\n",
      );

      if (missing > 0 || sizeMismatch > 0) {
        _currentAlerts.showFilesNotTransferred(
          missing: missing,
          sizeMismatch: sizeMismatch,
        );
      }

      final hasIssues = failed > 0 || missing > 0 || sizeMismatch > 0;
      final notificationTitle = hasIssues
          ? 'LWCAM transfer completed with issues'
          : 'LWCAM transfer completed';
      final notificationMessage = hasIssues
          ? 'Device ${auth.deviceId.value}: transferred $completed/${uploads.length}. Failed: $failed. Missing: $missing. Size mismatches: $sizeMismatch.'
          : 'Device ${auth.deviceId.value}: transferred $completed/${uploads.length} images successfully.';
      // A successful box transfer finishes while its operator is already back
      // on the capture grid; its completed state is shown on the box list.
      // Keep warnings, and preserve the normal-mode completion notification.
      if (box == null || hasIssues) {
        await _showWindowsNotificationPopup(
          title: notificationTitle,
          message: notificationMessage,
          warning: hasIssues,
        );
      }

      isUploading.value = false;
      showStatus("✅ All uploads finished");
      _updateOverallProgress();

      Future.delayed(const Duration(seconds: 5), () {
        if (!isUploading.value) {
          progress.value = 0.0;
          uploads.clear();
        }
      });

      await printDbLocation(auth.deviceId.value);

      // Write final summary to transfer records TXT file
      await _writeFinalSummaryToTransferRecordsTxt(
        artifacts: artifacts,
        endTime: endTime,
        totalDuration: totalDuration,
        completed: completed,
        failed: failed,
        missingFiles: missingFiles,
        sizeMismatchFiles: sizeMismatchFiles,
      );

      final batchResult = UploadBatchResult(
        completed: completed,
        failed: failed,
        missing: missing,
        sizeMismatch: sizeMismatch,
        totalQueued: uploads.length,
      );

      await _auditOrNull?.log(
        AuditActions.transferComplete,
        details: {
          'box': boxDetails,
          'completed': completed,
          'failed': failed,
          'missing': missing,
          'size_mismatch': sizeMismatch,
        },
      );

      return batchResult;
    } finally {
      // ALWAYS release all file locks first
      try {
        await _appendLog(
          "[${DateTime.now()}] 🔓 Releasing all source file locks...\n",
        );
        await fileLockService.releaseAllLocks();
        await _appendLog("[${DateTime.now()}] ✅ All file locks released.\n");
      } catch (e) {
        await _appendLog(
          "[${DateTime.now()}] ⚠️ Error releasing file locks: $e\n",
        );
      }

      if (dbProtection case final protection) {
        try {
          await statsDb.releaseTransferProtection(protection);
          await _appendLog(
            "[${DateTime.now()}] 🔓 Database transfer protection released for device ${auth.deviceId.value}.\n",
          );
        } catch (e) {
          await _appendLog(
            "[${DateTime.now()}] ⚠️ Failed to release database transfer protection: $e\n",
          );
          await _appendInterruption(
            "[${DateTime.now()}] ⚠️ Failed to release database transfer protection: $e\n",
          );
        }
      }

      if (isUploading.value) {
        isUploading.value = false;
        _updateOverallProgress();
      }
      _currentBatchArtifacts = null;
      _currentAlerts = const DialogAlertPresenter();
    }
  }

  // ---------------------- RESOLVE TARGET FILE (DB + DISK AWARE) --------------------------
  Future<File> _resolveTargetFileForBaseName({
    required Directory destDir,
    required String baseName,
    required String ext,
    required Set<String> reservedNames,
    required bool overwriteExisting,
    required bool alreadyInDb,
    Set<String>? recordedFilenames,
  }) async {
    // If user chose "ALL Images" AND DB says this base was uploaded before,
    // we try to reuse an existing file on disk so we OVERWRITE instead of
    // creating ..._002, ..._003.
    if (overwriteExisting && alreadyInDb) {
      final existing = await _pickExistingFileForBaseName(
        destDir: destDir,
        baseName: baseName,
        ext: ext,
        reservedNames: reservedNames,
      );
      if (existing != null) {
        return existing;
      }
    }

    // Otherwise (new image, or overwriteExisting=false, or file missing),
    // we generate a new unique filename with _NNN suffix.
    return generateUniqueTargetFile(
      destDir,
      baseName,
      ext,
      reservedNames: reservedNames,
      recordedFilenames: recordedFilenames,
    );
  }

  /// Try to find an existing file on disk that matches this base name.
  /// This checks:
  ///   1) baseName.ext   (for backward compatibility with older unsuffixed files)
  ///   2) baseName_001.ext
  ///   3) baseName_002.ext
  ///   ...
  Future<File?> _pickExistingFileForBaseName({
    required Directory destDir,
    required String baseName,
    required String ext,
    required Set<String> reservedNames,
  }) async {
    final candidates = <String>[];

    // backward-compat unsuffixed (in case older runs created them)
    candidates.add("$baseName$ext");

    // standard suffixed candidates
    for (int i = 1; i <= 999; i++) {
      final suffix = i.toString().padLeft(3, '0');
      candidates.add("${baseName}_$suffix$ext");
    }

    for (final name in candidates) {
      if (reservedNames.contains(name)) continue;
      final f = File(p.join(destDir.path, name));
      if (await f.exists()) {
        reservedNames.add(name);
        return f;
      }
    }

    return null;
  }

  // ---------------------- SAFE SINGLE FILE UPLOAD (WITH LIVE PROGRESS) -------------------
  Future<void> _uploadSingleFile(
    int index,
    String boxDetails,
    Directory destDir,
    _BatchArtifacts artifacts,
  ) async {
    final status = uploads[index];
    final srcFile = files[index];
    final originalName = srcFile.uri.pathSegments.last;
    final stopwatch = Stopwatch()..start();

    status.progress.value = 0.0;
    status.color.value = Get.theme.extension<LifewoodColors>()!.info;
    status.icon.value = Icons.hourglass_bottom;
    status.showError.value = false;
    status.errorMsg.value = "";
    _updateOverallProgress();

    Exception? lastError;
    StackTrace? lastStack;
    var durableCopyCommitted = false;
    var reconnects = 0;

    int attempt = 1;
    while (attempt <= 3) {
      File? destFile;
      try {
        print(
          "🚚 [${index + 1}/${uploads.length}] Starting upload for $originalName (attempt $attempt)",
        );

        final ext = p.extension(srcFile.path).toLowerCase();
        final destPath = _destPathFor(destDir, srcFile, status.filename);
        destFile = File(destPath);

        final srcLen = await srcFile.length();

        // Never re-copy a committed file. The destination name is allocated
        // ONCE per batch, so a retry resolves this same path — and the copy
        // opens it FileMode.write, which truncates on open. Re-running it
        // after the durable commit would zero a file upload_records already
        // records as verified, and the cleanup guards below (correctly) then
        // refuse to delete the wreckage. Only the metadata step can fail
        // post-commit, so that is all a retry needs to redo.
        if (!durableCopyCommitted) {
          await _copyFileWithProgress(srcFile, destFile, status);

          final destLen = await destFile.length();
          if (srcLen != destLen) {
            // Safe to delete: the enclosing guard means this partial belongs
            // to the current attempt and was never committed.
            if (await destFile.exists()) {
              await destFile.delete();
            }
            throw Exception(
              "Size mismatch after copy for $destPath ($srcLen vs $destLen)",
            );
          }
        } else {
          print(
            "↩️ Copy already committed for $originalName — retrying metadata only",
          );
        }

        try {
          final createdAt = DateTime.now();
          final db = UploadStatsDB();
          final operatorName = auth.username.value.isEmpty
              ? 'Unknown'
              : auth.username.value;
          final fileName = p.basename(destFile.path);

          final format = ext.replaceFirst('.', '');
          // Box mode: the row gains the owning folder's name + metadata. New
          // cells are RFC-4180-escaped (csvEscape); the original 6 cells keep
          // their naive quoting so keying-off output stays byte-identical.
          final boxInfo = _boxInfoFor(srcFile);
          final fixedValues = boxInfo?.fixedFieldValues;
          final csvLine = boxInfo != null
              ? '"$operatorName",'
                    '"${auth.deviceId.value}",'
                    '"$boxDetails",'
                    '${csvEscape(boxInfo.folderName)},'
                    '"$fileName",'
                    '"$format",'
                    '"${createdAt.toIso8601String()}",'
                    '${csvEscape(boxInfo.coverTag)},'
                    '${csvEscape(boxInfo.imageTags)},'
                    '${csvEscape(boxInfo.title)},'
                    '${csvEscape(boxInfo.volume)},'
                    '${csvEscape(boxInfo.startDate)},'
                    '${csvEscape(boxInfo.endDate)},'
                    '${csvEscape(boxInfo.archivalRefNo)},'
                    '${csvEscape(boxInfo.recordType)},'
                    '${kFixedFieldCsvColumns.map((c) => csvEscape(fixedValues?[c])).join(',')}'
              : '"$operatorName",'
                    '"${auth.deviceId.value}",'
                    '"$boxDetails",'
                    '"$fileName",'
                    '"$format",'
                    '"${createdAt.toIso8601String()}"';

          if (!durableCopyCommitted) {
            await _runSerializedArtifactWrite(() async {
              await _appendCsvLine(csvLine);
              await _appendTransferRecordTxt('$csvLine\n');
              await _appendSummary(
                '[${DateTime.now()}] ✅ $fileName transferred successfully '
                '(${(srcLen / (1024 * 1024)).toStringAsFixed(2)} MB)\n',
              );
              await _appendLog(
                '[${DateTime.now()}] ✅ Metadata committed for $fileName\n',
              );

              // This idempotent row is the durable "file + required
              // artifacts committed" marker. Keep it last so a crash before
              // this point never causes Box Mode to skip an incomplete file.
              await db.insertUploadRecord(
                deviceId: auth.deviceId.value,
                scanningOpr: operatorName,
                boxDetails: boxDetails,
                filename: fileName,
                format: format,
                createdAt: createdAt,
                coverTag: boxInfo?.coverTag,
                imageTags: boxInfo?.imageTags,
                title: boxInfo?.title,
                volume: boxInfo?.volume,
                startDate: boxInfo?.startDate,
                endDate: boxInfo?.endDate,
                archivalRefNo: boxInfo?.archivalRefNo,
                recordType: boxInfo?.recordType,
                place: fixedValues?['place'],
                language: fixedValues?['language'],
                recordCustodian: fixedValues?['record_custodian'],
                digitizingEntity: fixedValues?['digitizing_entity'],
                captureOperatorId: fixedValues?['capture_operator_id'],
                captureOperatorName: fixedValues?['capture_operator_name'],
              );
            });
            durableCopyCommitted = true;
          }

          // Final irreversible step: only point PostgreSQL at the generated
          // name after the destination file and local transfer record exist.
          if (_currentBox != null && fileName != originalName) {
            final reported = await db.reportCaptureImageTransferName(
              deviceId: auth.deviceId.value,
              deviceName: originalName,
              finalName: fileName,
            );
            if (!reported) {
              throw StateError(
                'Could not durably record transfer name '
                '$originalName → $fileName',
              );
            }
          }
        } catch (metaError, metaStack) {
          if (!durableCopyCommitted && await destFile.exists()) {
            await destFile.delete();
          }
          await _appendLog(
            "[${DateTime.now()}] ❌ Meta error for ${p.basename(destFile.path)}: $metaError\n",
          );
          await _appendError(
            "[${DateTime.now()}] ❌ Meta error for ${p.basename(destFile.path)}: $metaError\n",
          );
          debugPrint(metaStack.toString());
          throw Exception(
            "Meta update failed for ${p.basename(destFile.path)}: $metaError",
          );
        }

        stopwatch.stop();
        final secs = stopwatch.elapsedMilliseconds / 1000;
        final speedMBps =
            (srcLen / (1024 * 1024)) / (secs == 0 ? 0.0001 : secs);

        status.progress.value = 1.0;
        status.color.value = Get.theme.extension<LifewoodColors>()!.success;
        status.icon.value = Icons.check_circle;
        _updateOverallProgress();

        print(
          "✅ Finished upload for $originalName as ${p.basename(destFile.path)} "
          "in ${secs.toStringAsFixed(2)}s @ ${speedMBps.toStringAsFixed(2)} MB/s",
        );
        return;
      } catch (e, st) {
        lastError = Exception(e.toString());
        lastStack = st;

        await _appendLog(
          "[${DateTime.now()}] ❌ Attempt $attempt failed for $originalName: $e\n",
        );
        await _appendError(
          "[${DateTime.now()}] ❌ Attempt $attempt failed for $originalName: $e\n",
        );
        debugPrint(st.toString());

        // Handle critical timeout/stall errors - fail immediately
        if (e is TransferTimeoutException) {
          await _showCriticalErrorDialog(
            title: '⏱️ TRANSFER TIMEOUT',
            message:
                'File: ${status.filename}\n\n'
                'Transfer took too long (>10 minutes).\n\n'
                'Possible causes:\n'
                '• Destination is offline or very slow\n'
                '• Network connection interrupted\n'
                '• Disk is not responding\n\n'
                'Action: Check destination and connection, then retry.',
          );
          isUploading.value = false;
          _updateOverallProgress();
          rethrow;
        }

        if (e is TransferStallException) {
          await _showCriticalErrorDialog(
            title: '🛑 TRANSFER STALLED',
            message:
                'File: ${status.filename}\n\n'
                'Transfer made no progress for 30 seconds.\n\n'
                'Possible causes:\n'
                '• Destination write is blocked\n'
                '• Network connection froze\n'
                '• Disk is full or locked\n\n'
                'Action: Check destination connection and disk space, then retry.',
          );
          isUploading.value = false;
          _updateOverallProgress();
          rethrow;
        }

        // `continue` below skips both the cleanup and attempt++, so without a
        // bound an interrupt/reconnect cycle loops forever on the same attempt.
        // Past the bound this falls through and counts as a normal failure.
        if (e is UploadInterruptionException &&
            reconnects < _maxReconnectsPerFile) {
          reconnects++;
          showStatus("Connection interrupted, waiting to resume upload…");

          try {
            await _waitForDestinationAvailable(destDir);
            continue;
          } catch (waitError) {
            await _appendLog(
              "[${DateTime.now()}] ⏱️ Gave up waiting for destination for $originalName: $waitError\n",
            );
            await _appendInterruption(
              "[${DateTime.now()}] ⏱️ Gave up waiting for destination for $originalName: $waitError\n",
            );
            await _showCriticalErrorDialog(
              title: 'Network reconnect failed',
              message:
                  'The destination could not be reached after multiple reconnect attempts.\n\n'
                  'Please verify the network path, reconnect the destination, and retry.',
            );
          }
        }

        if (!durableCopyCommitted) {
          try {
            if (status.filename.isNotEmpty) {
              final destPath = _destPathFor(destDir, srcFile, status.filename);
              final maybeDest = File(destPath);
              if (await maybeDest.exists()) {
                await maybeDest.delete();
                print("🧹 Deleted partial file: $destPath");
              }
            } else if (destFile != null && await destFile.exists()) {
              await destFile.delete();
              print("🧹 Deleted partial file: ${destFile.path}");
            }
          } catch (cleanupErr) {
            debugPrint(
              "⚠️ Failed to cleanup partial file for $originalName: $cleanupErr",
            );
          }
        }

        if (attempt < 3) {
          await Future.delayed(const Duration(seconds: 1));
          print("🔁 Retrying $originalName (attempt ${attempt + 1}/3)");
        }

        attempt++;
      }
    }

    await _markUploadFailed(
      status,
      "Upload failed after 3 attempts: $lastError",
    );
    _updateOverallProgress();

    throw lastError ??
        Exception("Unknown upload failure for $originalName\n$lastStack");
  }

  // ---------------------- CONNECTION HELPERS --------------------------
  Future<bool> _checkConnectionAvailable(Directory destDir) async {
    try {
      // Async + bounded: existsSync() here blocked the UI isolate for the SMB
      // timeout every 5 s while the LWIP share was down.
      if (await probeExists(destDir) != FsProbe.found) {
        return false;
      }
      final testFile = File(p.join(destDir.path, '.connection_test'));
      await () async {
        await testFile.writeAsString('ok', mode: FileMode.write);
        await testFile.delete();
      }().timeout(kFsProbeTimeout);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _waitForDestinationAvailable(Directory destDir) async {
    const checkInterval = Duration(seconds: 3);
    const maxWait = Duration(minutes: 1);
    final start = DateTime.now();

    final destPath = destDir.path;

    await _appendInterruption(
      "[${DateTime.now()}] 🔌 Connection / destination not available. Attempting to restore: $destPath\n",
    );

    // Try with auto-wait for 1 minute first
    while (DateTime.now().difference(start) < maxWait) {
      try {
        if (await _checkConnectionAvailable(destDir)) {
          await _appendInterruption(
            "[${DateTime.now()}] ✅ Connection restored to destination: $destPath\n",
          );
          await _logAlert(
            title: 'Connection restored',
            message: 'Destination is available again. Resuming uploads...',
            warning: false,
            interruption: true,
          );
          return;
        }
      } catch (_) {
        // ignore and keep waiting
      }

      await Future.delayed(checkInterval);
    }

    // Auto-wait failed. Show manual reconnect button dialog.
    await _appendInterruption(
      "[${DateTime.now()}] ⏱️ Automatic reconnect attempts exhausted. Prompting user for manual reconnect: $destPath\n",
    );
    await _logAlert(
      title: 'Connection failed',
      message:
          'Automatic reconnect attempts failed. Please manually verify the connection.',
      warning: true,
      error: true,
      interruption: true,
    );

    await _currentAlerts.waitForReconnect(
      destDir: destDir,
      destPath: destPath,
      checkConnection: () => _checkConnectionAvailable(destDir),
    );
    await _appendInterruption(
      "[${DateTime.now()}] ✅ Connection restored to destination: $destPath\n",
    );
    await _logAlert(
      title: 'Connection restored',
      message: 'Destination is available. Resuming uploads...',
      warning: false,
      interruption: true,
    );
  }

  // ---------------------- UNIQUE NAME GENERATOR (_NNN SUFFIX, ORIGINAL STYLE) ----------
  /// Allocates the destination filename `baseName_NNN.ext`. Static (no
  /// instance state) so tests can drive it against a temp dir directly.
  ///
  /// [recordedFilenames] is kept for callers/logging: a candidate that exists
  /// on disk but is NOT recorded in this PC's DB is somebody else's file (or a
  /// torn copy from a build before `.part` copies) - it is NEVER overwritten
  /// (another PC on the same share, or a colliding device id, would lose an
  /// image); the next suffix is taken and the skip is logged. Interrupted
  /// copies of this build live at `<name>.part`, not under the final name.
  static Future<File> generateUniqueTargetFile(
    Directory destDir,
    String baseName, // e.g. "SAX03_IMG_20251028_125306"
    String ext, { // e.g. ".jpg"
    Set<String>? reservedNames,
    Set<String>? recordedFilenames,
  }) async {
    int counter = 1;

    while (true) {
      final suffix = counter.toString().padLeft(3, '0'); // 001, 002, 003...
      final candidateName = "${baseName}_$suffix$ext";
      final alreadyReserved =
          reservedNames != null && reservedNames.contains(candidateName);
      final candidate = File(p.join(destDir.path, candidateName));

      if (!alreadyReserved) {
        if (!await File(longPath(candidate.path)).exists()) {
          reservedNames?.add(candidateName);
          return candidate;
        }
        if (recordedFilenames != null &&
            !recordedFilenames.contains(candidateName)) {
          debugPrint('ℹ️ $candidateName exists in ${destDir.path} but this PC '
              'has no record of it - keeping it, using the next name.');
        }
      }

      counter++;
    }
  }

  // ---------------------- FILE COPY WITH PROGRESS (TIMEOUT AWARE) --------------------------
  /// Copies to `<dest>.part` and renames it into place only when the copy and
  /// the size check succeeded, so an interrupted copy never sits under the
  /// final name (and never overwrites a file that is already there).
  Future<void> _copyFileWithProgress(
    File src,
    File dest,
    UploadStatus status,
  ) async {
    final part = File(longPath('${dest.path}.part'));
    try {
      await _copyToFile(src, part, status);
      if (await src.length() != await part.length()) {
        throw Exception('Size mismatch after copy of ${p.basename(dest.path)}');
      }
      await part.rename(longPath(dest.path));
    } catch (_) {
      try {
        if (await part.exists()) await part.delete();
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> _copyToFile(
    File src,
    File dest,
    UploadStatus status,
  ) async {
    final totalBytes = await src.length();
    final rafSrc = await File(longPath(src.path)).open(mode: FileMode.read);
    final rafDest = await dest.open(mode: FileMode.write);

    const bufferSize = 4 * 1024 * 1024; // 4 MB chunks
    final buffer = List<int>.filled(bufferSize, 0);
    int bytesCopied = 0;
    DateTime lastProgressTime = DateTime.now();
    bool stallDetected = false;

    late Timer stallCheckTimer;

    try {
      // Start stall detection timer
      stallCheckTimer = Timer.periodic(
        const Duration(milliseconds: _stallCheckIntervalMs),
        (_) {
          final elapsed = DateTime.now().difference(lastProgressTime);
          if (elapsed > _stallTimeout && bytesCopied < totalBytes) {
            stallDetected = true;
            stallCheckTimer.cancel();
          }
        },
      );

      // Perform copy with hard timeout
      await _doCopyWithProgress(rafSrc, rafDest, buffer, totalBytes, status, (
        bytes,
      ) {
        bytesCopied = bytes;
        lastProgressTime = DateTime.now();
      }).timeout(
        _copyOperationTimeout,
        onTimeout: () {
          stallCheckTimer.cancel();
          throw TransferTimeoutException(
            'Copy operation exceeded ${_copyOperationTimeout.inMinutes} minutes',
            filename: status.filename,
          );
        },
      );

      if (stallDetected) {
        stallCheckTimer.cancel();
        throw TransferStallException(
          'Transfer stalled: no progress for ${_stallTimeout.inSeconds} seconds '
          '($bytesCopied / $totalBytes bytes)',
          filename: status.filename,
        );
      }
    } catch (e) {
      stallCheckTimer.cancel();
      final fileLabel = status.filename.isNotEmpty
          ? status.filename
          : p.basename(src.path);

      String logMsg;
      if (e is TransferTimeoutException) {
        logMsg = "[${DateTime.now()}] ⏱️ TIMEOUT: $fileLabel - ${e.message}\n";
      } else if (e is TransferStallException) {
        logMsg = "[${DateTime.now()}] 🛑 STALLED: $fileLabel - ${e.message}\n";
      } else {
        logMsg =
            "[${DateTime.now()}] 🔌 Transfer interrupted for $fileLabel at "
            "$bytesCopied / $totalBytes bytes: $e\n";
      }

      await _appendLog(logMsg);
      await _appendInterruption(logMsg);

      throw e is UploadInterruptionException
          ? e
          : UploadInterruptionException(logMsg);
    } finally {
      stallCheckTimer.cancel();
      try {
        await rafDest.flush();
      } catch (_) {}
      try {
        await rafSrc.close();
      } catch (_) {}
      try {
        await rafDest.close();
      } catch (_) {}
    }
  }

  // Helper to perform actual copy operation
  Future<void> _doCopyWithProgress(
    RandomAccessFile rafSrc,
    RandomAccessFile rafDest,
    List<int> buffer,
    int totalBytes,
    UploadStatus status,
    Function(int) onProgress,
  ) async {
    int bytesCopied = 0;

    while (true) {
      final bytesRead = await rafSrc.readInto(buffer);
      if (bytesRead == 0) break;

      await rafDest.writeFrom(buffer, 0, bytesRead);
      bytesCopied += bytesRead;
      onProgress(bytesCopied);

      if (totalBytes > 0) {
        final pVal = bytesCopied / totalBytes;
        status.progress.value = pVal.clamp(0.0, 1.0);
        _updateOverallProgress();
      }
    }

    if (totalBytes == 0) {
      status.progress.value = 1.0;
      _updateOverallProgress();
    }
  }

  Future<void> _showWindowsNotificationPopup({
    required String title,
    required String message,
    bool warning = false,
  }) async {
    try {
      await WindowsNotificationService.instance.showTransferNotification(
        title: title,
        body: message,
        warning: warning,
      );
    } catch (e) {
      await _appendLog(
        "[${DateTime.now()}] ⚠️ Failed to show Windows notification popup: $e\n",
      );
    }
  }

  // --- Batch artifacts: CSV, transfer record and summary/error logs --------

  Future<void> _initializeBatchArtifacts(
    _BatchArtifacts artifacts, {
    required String boxDetails,
    BoxTransferContext? box,
  }) async {
    for (final file in [
      artifacts.localCsvFile,
      artifacts.localTransferRecordsTxtFile,
      artifacts.localSummaryLogFile,
      artifacts.localErrorLogFile,
      artifacts.localInterruptionLogFile,
      artifacts.localTransferLogFile,
    ]) {
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      if (!await file.exists()) {
        await file.create(recursive: true);
      }
    }

    // Box transfers gain folder_name + the 8 metadata columns + the 6
    // template fixed-field columns; plain Normal Mode's format is unchanged
    // (byte-identical).
    final csvHeader = box != null
        ? 'scanning_opr,device_id,box_details,folder_name,filename,format,created_at,'
              'cover_tag,image_tags,title,volume,start_date,end_date,archival_ref_no,record_type,'
              '${kFixedFieldCsvColumns.join(',')}\n'
        : 'scanning_opr,device_id,box_details,filename,format,created_at\n';
    await _writeLine(artifacts.localCsvFile, csvHeader, overwrite: true);

    await _writeLine(
      artifacts.localTransferRecordsTxtFile,
      'Transfer Records - ${artifacts.operatorId}\n'
      'Format: $csvHeader'
      '==================================================\n',
      overwrite: true,
    );

    final header =
        'Transfer Summary - ${artifacts.startTime.toIso8601String()}\n'
        'Operator ID: ${artifacts.operatorId}\n'
        'Group Details: $boxDetails\n'
        'Total Files Queued: ${artifacts.totalQueued}\n'
        '--------------------------------------------------\n'
        'Per-file transfer updates:\n';
    await _writeLine(artifacts.localSummaryLogFile, header, overwrite: true);

    final transferHeader =
        '[${DateTime.now()}] Transfer batch started for ${artifacts.operatorId}. '
        'Queued=${artifacts.totalQueued}\n';
    await _writeLine(
      artifacts.localTransferLogFile,
      transferHeader,
      overwrite: true,
    );

    await _writeLine(artifacts.localErrorLogFile, '', overwrite: true);
    await _writeLine(artifacts.localInterruptionLogFile, '', overwrite: true);
  }

  Future<void> _writeLine(
    File file,
    String line, {
    bool overwrite = false,
  }) async {
    if (!await file.parent.exists()) {
      await file.parent.create(recursive: true);
    }
    if (!await file.exists()) {
      await file.create(recursive: true);
    }
    await file.writeAsString(
      line,
      mode: overwrite ? FileMode.write : FileMode.append,
      flush: true,
    );
  }

  Future<void> _appendCsvLine(String line) async {
    final artifacts = _currentBatchArtifacts;
    if (artifacts == null) return;
    await _writeLine(artifacts.localCsvFile, '$line\n');
  }

  Future<void> _appendTransferRecordTxt(String line) async {
    final artifacts = _currentBatchArtifacts;
    if (artifacts == null) return;
    await _writeLine(artifacts.localTransferRecordsTxtFile, line);
  }

  Future<void> _writeFinalSummaryToTransferRecordsTxt({
    required _BatchArtifacts artifacts,
    required DateTime endTime,
    required Duration totalDuration,
    required int completed,
    required int failed,
    required List<String> missingFiles,
    required List<String> sizeMismatchFiles,
  }) async {
    final failedFiles = [...missingFiles, ...sizeMismatchFiles];

    final hours = totalDuration.inHours;
    final minutes = totalDuration.inMinutes.remainder(60);
    final seconds = totalDuration.inSeconds.remainder(60);
    final durationStr =
        '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';

    final summary = StringBuffer();
    summary.writeln('\n==================================================');
    summary.writeln('TRANSFER SUMMARY');
    summary.writeln('==================================================');
    summary.writeln('Start datetime: ${artifacts.startTime.toIso8601String()}');
    summary.writeln('End datetime: ${endTime.toIso8601String()}');
    summary.writeln('Total processing duration: $durationStr');
    summary.writeln('Total number of files transferred: $completed');
    summary.writeln(
      'Total number of failed transfers: ${failed + failedFiles.length}',
    );

    if (failedFiles.isNotEmpty) {
      summary.writeln('\nFailed transfers:');
      for (final filename in failedFiles) {
        summary.writeln('- $filename');
      }
    } else {
      summary.writeln('\nFailed transfers: None');
    }

    summary.writeln('==================================================\n');

    await _writeLine(artifacts.localTransferRecordsTxtFile, summary.toString());
  }

  Future<void> _appendSummary(String line) async {
    final artifacts = _currentBatchArtifacts;
    if (artifacts == null) return;
    await _writeLine(artifacts.localSummaryLogFile, line);
  }

  Future<void> _appendError(String line) async {
    final artifacts = _currentBatchArtifacts;
    if (artifacts == null) return;
    await _writeLine(artifacts.localErrorLogFile, line);
  }

  Future<void> _appendInterruption(String line) async {
    final artifacts = _currentBatchArtifacts;
    if (artifacts == null) return;
    await _writeLine(artifacts.localInterruptionLogFile, line);
  }

  // ---------------------- LOGGING --------------------------
  Future<void> _appendLog(String line) async {
    final artifacts = _currentBatchArtifacts;
    if (artifacts != null) {
      await _writeLine(artifacts.localTransferLogFile, line);
      return;
    }

    final logFile = await _getFallbackLogFile();
    await logFile.writeAsString(line, mode: FileMode.append, flush: true);
  }

  Future<File> _getFallbackLogFile() async {
    final baseDir = await getApplicationSupportDirectory();
    final appDir = Directory(p.join(baseDir.path, 'LWCAM'));
    if (!appDir.existsSync()) appDir.createSync(recursive: true);
    final operatorId = auth.deviceId.value.trim().isEmpty
        ? 'UNKNOWN'
        : auth.deviceId.value.trim();
    final logFile = File(p.join(appDir.path, '${operatorId}_transfer_log.txt'));
    if (!logFile.existsSync()) await logFile.create(recursive: true);
    return logFile;
  }

  // ---------------------- IMAGE DATE EXTRACT (NO EXIF, FAST) --------------------------
  Future<DateTime> _getImageDate(File file) async {
    final name = p.basename(file.path);
    final reg = RegExp(r'(\d{8})_(\d{6})'); // e.g. 20251030_114015
    final match = reg.firstMatch(name);

    if (match != null) {
      final datePart = match.group(1)!; // YYYYMMDD
      final timePart = match.group(2)!; // HHMMSS
      final year = int.parse(datePart.substring(0, 4));
      final month = int.parse(datePart.substring(4, 6));
      final day = int.parse(datePart.substring(6, 8));
      final hour = int.parse(timePart.substring(0, 2));
      final minute = int.parse(timePart.substring(2, 4));
      final second = int.parse(timePart.substring(4, 6));
      return DateTime(year, month, day, hour, minute, second);
    }

    // fallback to file modified time
    return file.statSync().modified;
  }

  // ---------------------- DATE FORMAT (SECOND PRECISION, NO MS) --------------------------
  //
  // Example output: 20251028_125306
  //
  String _formatDate(DateTime dt) {
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '${y}${m}${d}_${h}${min}${s}';
  }

  // ---------------------- UI STATUS + ERROR DIALOG --------------------------
  void showStatus(String msg) {
    statusMessage.value = msg;
    _appendLog("[${DateTime.now()}] ℹ️ STATUS: $msg\n");
    Future.delayed(const Duration(seconds: 5), () {
      if (statusMessage.value == msg) statusMessage.value = "";
    });
  }

  /// Show critical error dialog and stop uploads immediately
  Future<void> _showCriticalErrorDialog({
    required String title,
    required String message,
    String actionText = 'OK - CANCEL ALL',
  }) async {
    // Stop current upload immediately
    isUploading.value = false;
    _updateOverallProgress();

    await _logAlert(
      title: title,
      message: message,
      warning: true,
      error: true,
      interruption: true,
    );

    await _currentAlerts.showCriticalError(
      title: title,
      message: message,
      actionText: actionText,
    );
  }

  Future<void> _markUploadFailed(UploadStatus status, String message) async {
    status.color.value = Get.theme.colorScheme.error;
    status.icon.value = Icons.refresh;
    status.errorMsg.value = message;
    status.showError.value = true;

    await _logAlert(
      title: 'Upload Failed',
      message: message,
      warning: true,
      error: true,
    );
    await _auditOrNull?.log(
      AuditActions.transferFileFailed,
      details: {'file': status.filename, 'error': message},
    );

    Get.defaultDialog(
      title: 'Upload Failed',
      middleText: message,
      textConfirm: 'Retry',
      textCancel: 'Cancel',
      confirmTextColor: Get.theme.colorScheme.onPrimary,
      onConfirm: () async {
        Get.back();
        await retryUpload(uploads.indexOf(status));
      },
    );
  }

  // ---------------------- RETRY UPLOAD --------------------------
  Future<void> retryUpload(int index) async {
    if (index < 0 || index >= uploads.length) return;

    if (s.destinationPath.value.isEmpty) {
      showStatus(
        "Destination not configured — set it in LWCam Admin's Station Setup.",
      );
      return;
    }

    final status = uploads[index];
    final srcFile = files[index];
    // A box-mode retry goes back into the batch's own day dir, never today's.
    final batchDir = _currentDestDir;
    final destDir = _boxInfoFor(srcFile) != null && batchDir != null
        ? await batchDir.create(recursive: true)
        : await TransferDestinationService.ensureDirectoryForDate(
            s.destinationPath.value,
            DateTime.now(),
          );

    await _auditOrNull?.log(
      AuditActions.transferRetry,
      details: {
        'file': status.filename.isEmpty
            ? p.basename(srcFile.path)
            : status.filename,
      },
    );

    try {
      status.progress.value = 0.0;
      status.color.value = Get.theme.extension<LifewoodColors>()!.info;
      status.icon.value = Icons.hourglass_bottom;
      status.errorMsg.value = "";
      status.showError.value = false;
      _updateOverallProgress();

      final ext = p.extension(srcFile.path).toLowerCase();

      // Reuse existing filename if we already have one, otherwise generate new.
      String targetName = status.filename;
      if (targetName.isEmpty) {
        final date = await _getImageDate(srcFile);
        final formatted = _formatDate(date);
        final baseName = "${auth.deviceId.value}_IMG_${formatted}";
        final destFileGenerated = await generateUniqueTargetFile(
          destDir,
          baseName,
          ext,
          recordedFilenames: await UploadStatsDB().getUploadedFilenames(
            auth.deviceId.value,
          ),
        );
        targetName = p.basename(destFileGenerated.path);
        status.filename = targetName;
      }

      // Box mode: the retried file goes back into its folder's subdir.
      final destFile = File(_destPathFor(destDir, srcFile, targetName));
      if (!await destFile.parent.exists()) {
        await destFile.parent.create(recursive: true);
      }

      await safeCopy(srcFile, destFile.path);

      final srcLen = await srcFile.length();
      final destLen = await destFile.length();
      if (srcLen != destLen) {
        throw Exception("Retry size mismatch ${status.filename}");
      }

      status.progress.value = 1.0;
      status.color.value = Get.theme.extension<LifewoodColors>()!.success;
      status.icon.value = Icons.check_circle;
      _updateOverallProgress();
    } catch (e, stack) {
      debugPrint("Retry upload failed for ${srcFile.path}: $e");
      debugPrint(stack.toString());
      status.color.value = Get.theme.colorScheme.error;
      status.icon.value = Icons.error;
      status.errorMsg.value = "Retry failed";
      status.showError.value = true;
      _updateOverallProgress();
    }
  }

  // ---------------------- CLEANUP TEMP FILES --------------------------
  Future<void> cleanupTempFiles() async {
    try {
      final logFile = await _getFallbackLogFile();
      if (await logFile.exists()) await logFile.delete();

      // NOTE: this used to also list today's DESTINATION date folder (often
      // on the NAS — a multi-second synchronous SMB scan that held the
      // window open on exit) and DELETE every *_upload_records_*.csv in it.
      // Those CSVs are the per-batch transfer-record artifacts, not temp
      // files — deleting them on every app close destroyed the day's
      // records. The sweep was dormant while window close raced process
      // death; once close became deterministic (setPreventClose) it ran
      // every time, so it has been removed.

      debugPrint("✅ Temporary files cleaned up");
    } catch (e) {
      debugPrint("⚠️ Cleanup failed: $e");
    }
  }

  // ---------------------- OVERALL PROGRESS --------------------------
  void _updateOverallProgress() {
    if (uploads.isEmpty) {
      progress.value = 0.0;
      return;
    }

    double sum = 0;
    for (final u in uploads) {
      sum += u.progress.value;
    }
    progress.value = sum / uploads.length;
  }
}

// ---------------------- PRINT DB LOCATION --------------------------
Future<void> printDbLocation(String deviceId) async {
  final dbHelper = UploadStatsDB();

  final baseFolder = await dbHelper.getBaseFolder();
  final deviceDbPath = await dbHelper.getDeviceDbFilePath(deviceId);

  debugPrint("SQLite DB base folder: $baseFolder");
  debugPrint("Per-device DB path: $deviceDbPath");
}
