import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Transaction;
import '../db/upload_stats_db.dart';
import 'color_capture_session.dart';
import 'fs_probe.dart';
import 'processing_marker_service.dart' show reworkReadinessHeld;
import 'safe_copy.dart';

/// Durable recapture intent. A pointer is published only after the image and
/// its binding have both been written. Readers verify the image before use.
class ColorReworkStore {
  static const _intentName = 'intent.json';

  static String _keyFor(String deviceId, String target) => sha256
      .convert(utf8.encode('$deviceId|${p.normalize(target).toLowerCase()}'))
      .toString();

  static Future<Directory> _directory(String deviceId, String target) async {
    final root = await UploadStatsDB().getBaseFolder();
    final dir = Directory(p.join(root, 'color_rework', _keyFor(deviceId, target)));
    await dir.create(recursive: true);
    await writeStringAtomic(p.join(dir.path, 'owner.json'), jsonEncode({'device_id': deviceId}));
    return dir;
  }

  /// The intent path without creating the store directory. Used by the
  /// metadata-submit recovery check, which must not litter empty dirs.
  static Future<File> _intentFile(String deviceId, String target) async {
    final root = await UploadStatsDB().getBaseFolder();
    return File(
      p.join(root, 'color_rework', _keyFor(deviceId, target), _intentName),
    );
  }

  static Future<File> stage(
    String deviceId,
    String target,
    File source,
    ColorBinding binding, {
    String? folderKey,
  }) async {
    final dir = await _directory(deviceId, target);
    final oldIntent = File(p.join(dir.path, _intentName));
    var applying = false;
    if (await oldIntent.exists()) {
      final old = jsonDecode(await oldIntent.readAsString()) as Map;
      if (old['apply_protocol'] != null && old['apply_protocol'] != 2) {
        throw StateError('Unsupported recapture apply protocol');
      }
      if (old['apply_protocol'] == 2 && old['applying'] is! bool) {
        throw StateError('Invalid recapture applying state');
      }
      if (old['applying'] == true &&
          !target.startsWith('capture-slot:') &&
          await _generationCommitted(deviceId, dir.path, old)) {
        // Cleanup may have failed after the previous closure committed. A new
        // photo is not part of that finished operation until beginApply runs.
        applying = false;
      } else if (old['apply_protocol'] == 2 && old['applying'] is bool) {
        applying = old['applying'] == true;
      } else if (target.startsWith('capture-slot:')) {
        applying = await stagedMayHaveBeenApplied(deviceId, target);
      } else {
        applying = !await _legacyMetadataSafe(deviceId, target)
            .timeout(kFsProbeTimeout);
      }
    }
    final file = File(
      p.join(
        dir.path,
        '${DateTime.now().microsecondsSinceEpoch}${p.extension(source.path)}',
      ),
    );
    await safeCopy(source, file.path);
    final hash = (await sha256.bind(file.openRead()).first).toString();
    final bindingJson = jsonEncode(binding.toJson());
    await writeStringAtomic('${file.path}.color.json', bindingJson);
    await writeStringAtomic(
      p.join(dir.path, _intentName),
      jsonEncode({
        // v2 writers persist applying BEFORE the first remote marker write.
        // Explicit false therefore proves no remote operation has started.
        'apply_protocol': 2,
        if (folderKey != null) 'folder_key': folderKey,
        'source_name': p.basename(source.path),
        'applying': applying,
        'file': p.basename(file.path),
        'sha256': hash,
        'target': target,
        'binding_sha256': sha256.convert(utf8.encode(bindingJson)).toString(),
      }),
    );
    return file;
  }

  /// Persist before touching the destination. Undo must retain an applying
  /// generation until its binding and closure have committed.
  static Future<void> beginApply(String deviceId, String target) async {
    final intent = await _intentFile(deviceId, target);
    final data = Map<String, dynamic>.from(jsonDecode(await intent.readAsString()) as Map);
    data['applying'] = true;
    await writeStringAtomic(intent.path, jsonEncode(data));
  }

  /// The closure and this receipt commit together. If deleting the intent then
  /// fails, later metadata must recognise this exact committed generation;
  /// receipts for older generations never exempt a newer replacement.
  static Future<void> recordCommitted(Transaction transaction, File staged) async {
    if (!isStoreFile(staged)) throw StateError('Invalid recapture store file');
    await transaction.rawInsert(
      'INSERT OR REPLACE INTO sync_meta (key, value) VALUES (?, ?)',
      [_committedKey(staged), p.basename(staged.path)],
    );
  }

  static String _committedKey(File staged) =>
      'rework_committed:${p.basename(staged.parent.path)}';

  static Future<bool> _generationCommitted(
      String deviceId, String directory, Map data) async {
    final name = data['file'];
    if (name is! String || !AdmissibleName.check(name)) {
      throw StateError('Invalid recapture generation');
    }
    final db = await UploadStatsDB().getDatabase(deviceId);
    final rows = await db.query('sync_meta', columns: ['value'],
        where: 'key = ?',
        whereArgs: [_committedKey(File(p.join(directory, name)))]);
    return rows.isNotEmpty && rows.single['value'] == name;
  }

  /// Check local recovery state without opening the photo share. A successful
  /// mixed submit may finish its own verified generations in the same DB
  /// transaction. Other applying generations (including siblings no longer in
  /// the current worklist) must stay open. Old records lacking the v2 ordering
  /// guarantee are the only case requiring a bounded remote recovery check.
  static Future<void> assertMetadataSafe(
    String deviceId, {
    required String folderKey,
    required String folderPath,
    Iterable<File> completing = const [],
  }) async {
    final root = Directory(p.join(
        await UploadStatsDB().getBaseFolder(), 'color_rework'));
    if (!await root.exists()) return;
    final finished = completing
        .map((file) => p.normalize(file.absolute.path).toLowerCase())
        .toSet();
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(p.basename(entry.path))) {
        continue;
      }
      final intent = File(p.join(entry.path, _intentName));
      if (!await intent.exists()) continue;
      final owner = File(p.join(entry.path, 'owner.json'));
      bool owned = false;
      try {
        if (await owner.exists()) {
          final data = jsonDecode(await owner.readAsString());
          if (data is! Map || data['device_id'] is! String) {
            throw const FormatException('Invalid recapture owner');
          }
          if (data['device_id'] != deviceId) continue;
          owned = true;
        }
        final data = jsonDecode(await intent.readAsString());
        if (data is! Map || data['target'] is! String) {
          throw const FormatException('Invalid recapture intent');
        }
        final target = data['target'] as String;
        if (p.basename(entry.path) != _keyFor(deviceId, target)) {
          if (owned) throw const FormatException('Recapture target mismatch');
          continue;
        }
        if (target.startsWith('capture-slot:')) continue;
        final sameFolder = data['folder_key'] == folderKey ||
            _folderTail(p.dirname(target)) == _folderTail(folderPath);
        if (!sameFolder) continue;
        final name = data['file'];
        if (name is! String || !AdmissibleName.check(name)) {
          throw const FormatException('Invalid recapture generation');
        }
        if (data['apply_protocol'] != null && data['apply_protocol'] != 2) {
          throw const FormatException('Unsupported recapture apply protocol');
        }
        if (data['apply_protocol'] == 2 && data['applying'] is! bool) {
          throw const FormatException('Invalid recapture applying state');
        }
        final generation = p.normalize(p.join(entry.path, name)).toLowerCase();
        if (finished.contains(generation)) continue;
        if (await _generationCommitted(deviceId, entry.path, data)) continue;
        if (data['applying'] == true) {
          throw StateError('An interrupted recapture in this folder must be '
              'completed before submitting metadata.');
        }
        if (data['apply_protocol'] == 2 && data['applying'] == false) continue;
        // A pre-v2 submit could hold the remote gate before recording applying.
        // No local evidence proves it untouched; never interpret offline as no
        // replacement. Once recovered, ordinary metadata is local-only again.
        final safe = await _legacyMetadataSafe(deviceId, target)
            .timeout(kFsProbeTimeout);
        if (!safe) throw StateError('Legacy recapture still needs recovery.');
      } catch (e) {
        throw StateError('Cannot safely submit metadata for this folder: $e');
      }
    }
  }

  static Future<bool> _legacyMetadataSafe(String deviceId, String target) async {
    if (await probeExists(File(longPath(target))) != FsProbe.found) {
      throw StateError('A legacy recapture needs its source share to recover; '
          'restore the share and retry.');
    }
    return !await reworkReadinessHeld(p.dirname(target)) &&
        !await stagedMayHaveBeenApplied(deviceId, target);
  }

  // The input and output roots can be on different PCs. Their date/folder tail
  // identifies older intents without touching either root; new intents also
  // carry the stable project/box/folder key so changed share paths stay guarded.
  static String _folderTail(String path) {
    final parts = p.normalize(path).replaceAll('\\', '/').toLowerCase().split('/');
    for (var i = parts.length - 2; i >= 0; i--) {
      if (RegExp(r'^\d{8}$').hasMatch(parts[i])) return parts.sublist(i).join('/');
    }
    return parts.join('/');
  }

  static Future<File?> pending(String deviceId, String target) async {
    final dir = await _directory(deviceId, target);
    final intent = File(p.join(dir.path, _intentName));
    if (!await intent.exists()) return null;
    final data = jsonDecode(await intent.readAsString()) as Map;
    final name = data['file'] as String;
    if (!AdmissibleName.check(name)) {
      throw StateError('Invalid recapture intent filename');
    }
    final file = File(p.join(dir.path, name));
    if (!await file.exists() ||
        (await sha256.bind(file.openRead()).first).toString() !=
            data['sha256']) {
      throw StateError('Recapture staging is damaged; retake this page');
    }
    final sidecar = File('${file.path}.color.json');
    if (!await sidecar.exists() ||
        (await sha256.bind(sidecar.openRead()).first).toString() !=
            data['binding_sha256']) {
      throw StateError('Recapture binding is damaged; retake this page');
    }
    return file;
  }

  static Future<File?> recoverApplying(String deviceId, String target) async {
    final intent = await _intentFile(deviceId, target);
    if (!await intent.exists()) return null;
    final data = jsonDecode(await intent.readAsString()) as Map;
    if (data['applying'] != true) return null;
    // Page entry must not re-stage an already closed replacement merely
    // because its intent survived cleanup. Check before reading old pixels.
    if (!target.startsWith('capture-slot:') &&
        await _generationCommitted(deviceId, intent.parent.path, data)) {
      return null;
    }
    return pending(deviceId, target);
  }

  /// Recover an interrupted capture-slot replacement as a durable overlay.
  /// No phone rename is repeated: a crash may have occurred after that rename.
  static Future<File?> recoverCaptureSlot(String deviceId, String name,
      {required String dateKey, required String username}) async {
    final target = 'capture-slot:$name';
    final file = await recoverApplying(deviceId, target);
    if (file == null) return null;
    final intent = jsonDecode(await (await _intentFile(deviceId, target)).readAsString()) as Map;
    final sourceName = intent['source_name'];
    if (sourceName is! String || !AdmissibleName.check(sourceName) || sourceName == name) {
      throw StateError('Capture recovery needs a valid replacement filename');
    }
    final binding = jsonDecode(await File('${file.path}.color.json').readAsString()) as Map;
    final db = UploadStatsDB();
    final rows = await db.getReplacementRecords(deviceId);
    if (!rows.any((row) => row['original_filename'] == name &&
        row['replacement_local_path'] == file.path)) {
      await db.insertReplacementRecord(deviceId: deviceId, sequenceIndex: -1,
        dateKey: dateKey, originalFilename: name, replacementFilename: sourceName,
        replacementLocalPath: file.path, scanningOpr: username);
    }
    await db.saveColorBinding(deviceId, name, Map<String, dynamic>.from(binding));
    await complete(deviceId, target, staged: file);
    return file;
  }

  /// Retain pending/applying generations and referenced overlays indefinitely.
  /// Only unreferenced generations older than 30 days are disposable.
  static Future<void> prune(String deviceId, {DateTime? now}) async {
    final root = Directory(p.join(await UploadStatsDB().getBaseFolder(), 'color_rework'));
    if (!await root.exists()) return;
    final cutoff = (now ?? DateTime.now()).subtract(const Duration(days: 30));
    final records = await UploadStatsDB().getReplacementRecords(deviceId);
    final protected = records.where((r) => r['transferred_at'] == null)
        .map((r) => r['replacement_local_path']).whereType<String>().toSet();
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory || !RegExp(r'^[0-9a-f]{64}$').hasMatch(p.basename(entry.path))) continue;
      final owner = File(p.join(entry.path, 'owner.json'));
      if (!await owner.exists() || (jsonDecode(await owner.readAsString()) as Map)['device_id'] != deviceId) continue;
      // Unknown or active intent: keep the entire directory for recovery.
      if (await File(p.join(entry.path, _intentName)).exists()) continue;
      await for (final candidate in entry.list(followLinks: false)) {
        if (candidate is! File || !RegExp(r'^\d+\.[^.]+(?:\.color\.json)?$').hasMatch(p.basename(candidate.path))) continue;
        final photo = candidate.path.endsWith('.color.json')
            ? candidate.path.substring(0, candidate.path.length - '.color.json'.length) : candidate.path;
        if (protected.contains(photo)) continue;
        if ((await candidate.stat()).modified.isBefore(cutoff)) await candidate.delete();
      }
      final remaining = await entry.list(followLinks: false).toList();
      if (remaining.length == 1 && remaining.single.path == owner.path) {
        await owner.delete();
        await entry.delete();
      }
    }
  }

  /// True when [file] is a generation inside the per-device/target recapture
  /// store (a 64-hex directory directly under `color_rework`). Used before
  /// deleting an intent so an arbitrary operator file is never touched.
  static bool isStoreFile(File file) {
    final dir = p.normalize(p.dirname(file.absolute.path));
    final hash = p.basename(dir);
    return RegExp(r'^[0-9a-f]{64}$').hasMatch(hash) &&
        p.basename(p.dirname(dir)).toLowerCase() == 'color_rework';
  }

  /// Discards the durable intent for [staged] without deleting any photo.
  /// Idempotent: a missing or already-completed intent is a no-op. If the
  /// intent points at a newer generation, it is left in place.
  static Future<void> discardStaged(File staged) async {
    if (!isStoreFile(staged)) {
      throw StateError(
        'Refusing to discard a file outside the recapture store: ${staged.path}',
      );
    }
    final dir = p.dirname(p.normalize(staged.absolute.path));
    final intent = File(p.join(dir, _intentName));
    if (!await intent.exists()) return;
    final expected = p.basename(staged.path);
    try {
      final data = jsonDecode(await intent.readAsString());
      final current = data is Map ? data['file'] : null;
      if (current is String && current != expected) return;
      final target = data is Map ? data['target'] : null;
      final notStarted = data is Map && data['apply_protocol'] == 2 && data['applying'] == false;
      final installed = !notStarted && target is String && !target.startsWith('capture-slot:') && await File(target).exists() &&
          (await sha256.bind(File(target).openRead()).first).toString() == data['sha256'];
      if (data is Map && (data['applying'] == true || installed)) {
        throw StateError('Recapture was already started; retry Submit before Undo');
      }
    } on FormatException {
      throw StateError('Recapture intent is unreadable; restore it before Undo');
    }
    await intent.delete();
  }

  /// True when a durable recapture for [targetPath] exists AND the target now
  /// holds exactly those bytes. That means an interrupted submit already
  /// installed the photo but did not close the request: a later metadata-only
  /// submit must not silently reclassify it. A stale intent whose target still
  /// holds the original bytes is abandoned staging, not an applied recapture.
  static Future<bool> stagedMayHaveBeenApplied(
    String deviceId,
    String targetPath,
  ) async {
    final intent = await _intentFile(deviceId, targetPath);
    if (!await intent.exists()) return false;
    final data = jsonDecode(await intent.readAsString()) as Map;
    if (data['applying'] == true) return true;
    final digest = data['sha256'];
    if (digest is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest)) {
      throw StateError('Recapture intent has no trusted digest');
    }
    if (targetPath.startsWith('capture-slot:')) return false;
    final target = File(targetPath);
    if (!await target.exists()) return false;
    // Legacy Undo could delete staging but leave this intent. Comparing the
    // recorded digest does not require those abandoned staging files.
    return (await sha256.bind(target.openRead()).first).toString() == digest;
  }

  /// Clears the published intent. When [staged] is supplied, a different
  /// generation's intent is left alone (a newer stage won the race).
  static Future<void> complete(
    String deviceId,
    String target, {
    File? staged,
  }) async {
    final dir = await _directory(deviceId, target);
    final intent = File(p.join(dir.path, _intentName));
    if (!await intent.exists()) return;
    if (staged != null) {
      final data = jsonDecode(await intent.readAsString());
      final current = data is Map ? data['file'] : null;
      if (current is! String || !AdmissibleName.check(current)) {
        throw StateError('Cannot verify recapture generation for cleanup');
      }
      // Completion may retire its own applying intent, but never a newer one.
      if (current != p.basename(staged.path)) return;
    }
    await intent.delete();
    // Keep captured generations for recovery; never delete an operator's photo
    // as a side effect of clearing the published intent.
  }
}

class AdmissibleName {
  static bool check(String name) =>
      name.isNotEmpty &&
      name == p.basename(name) &&
      !name.contains(RegExp(r'[\\/:\x00-\x1f]')) &&
      name != '.' &&
      name != '..';
}
