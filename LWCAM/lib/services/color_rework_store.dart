import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite_common_ffi/sqflite_ffi.dart' show Transaction;
import '../db/upload_stats_db.dart';
import 'color_capture_session.dart';
import 'fs_probe.dart';
import 'processing_marker_service.dart' show reworkReadinessHeld;
import 'safe_copy.dart';

/// A recapture record in the store as the metadata guard and page entry see
/// it. [target] is known when ownership is established: from a readable,
/// consistent intent, or from `owner.json` whose target hashes to the record's
/// directory name. Without it the record cannot be attributed to any folder.
/// [folderKeys] are the folder keys the record claims (both, when intent and
/// owner disagree); the target's path also places it. A record whose folder
/// key is corrupt with nothing verified to replace it is not [attributed].
class RecaptureRecord {
  final Directory directory;
  final String? target;
  final Set<String> folderKeys;
  final bool attributed;
  final Map? intent;
  final String? problem;
  const RecaptureRecord({
    required this.directory,
    this.target,
    this.folderKeys = const {},
    this.attributed = true,
    this.intent,
    this.problem,
  });

  /// Blocks every folder on this device: no folder can be ruled out.
  bool get unattributed => target == null || !attributed;

  String? get page => target == null ? null : p.basename(target!);

  /// Page, record and target, for messages an operator or admin can act on.
  String describe() => [
    if (page != null) 'page $page',
    'record ${directory.path}',
    if (target != null) 'target $target',
  ].join(', ');
}

/// Result of restoring interrupted capture-slot replacements for a box.
class CaptureSlotRecovery {
  final Map<String, File> recovered = {};
  final Map<String, String> failed = {};
}

/// Durable recapture intent. A pointer is published only after the image and
/// its binding have both been written. Readers verify the image before use.
///
/// Each record lives in `color_rework/<sha256(device|target)>/` with
/// `owner.json` (`device_id`, `target`, `folder_key`) written before the
/// intent. Because the directory name is a hash of the target, the owner's
/// target is verifiable even when `intent.json` cannot be read.
class ColorReworkStore {
  static const _intentName = 'intent.json';
  static const _ownerName = 'owner.json';

  static String _keyFor(String deviceId, String target) => sha256
      .convert(utf8.encode('$deviceId|${p.normalize(target).toLowerCase()}'))
      .toString();

  static Future<Directory> _directory(
    String deviceId,
    String target, {
    String? folderKey,
  }) async {
    final root = await UploadStatsDB().getBaseFolder();
    final dir = Directory(p.join(root, 'color_rework', _keyFor(deviceId, target)));
    await dir.create(recursive: true);
    final owner = File(p.join(dir.path, _ownerName));
    String? knownFolder = folderKey;
    if (knownFolder == null && await owner.exists()) {
      try {
        final old = jsonDecode(await owner.readAsString());
        if (old is Map && old['folder_key'] is String) knownFolder = old['folder_key'] as String;
      } on FormatException {
        // Rewritten below from what this call knows.
      }
    }
    await writeStringAtomic(owner.path, jsonEncode({
      'device_id': deviceId,
      'target': target,
      if (knownFolder != null) 'folder_key': knownFolder,
    }));
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

  /// Stages [source] as the newest generation for [target].
  ///
  /// [applying] marks a generation that continues an operation which may
  /// already have changed the destination (relocation). [supersedes] names
  /// the old-path record such a generation replaces once it commits. A retake
  /// of an unfinished relocated operation carries that reference forward.
  static Future<File> stage(
    String deviceId,
    String target,
    File source,
    ColorBinding binding, {
    String? folderKey,
    bool applying = false,
    Map<String, String>? supersedes,
  }) async {
    final dir = await _directory(deviceId, target, folderKey: folderKey);
    final oldIntent = File(p.join(dir.path, _intentName));
    Map<String, String>? carried;
    if (await oldIntent.exists()) {
      Map? old;
      try {
        final decoded = jsonDecode(await oldIntent.readAsString());
        if (decoded is Map) old = decoded;
      } on FormatException {
        old = null;
      }
      if (old == null) {
        // Unreadable: nothing proves the destination untouched. Keep the
        // evidence and carry the obligation into the new generation.
        await oldIntent.copy(p.join(
          dir.path,
          'intent.unreadable-${DateTime.now().microsecondsSinceEpoch}.json',
        ));
        applying = true;
      } else {
        if (old['apply_protocol'] != null && old['apply_protocol'] != 2) {
          throw StateError('Unsupported recapture apply protocol');
        }
        if (old['apply_protocol'] == 2 && old['applying'] is! bool) {
          throw StateError('Invalid recapture applying state');
        }
        final name = old['file'];
        if (name is! String || !AdmissibleName.check(name)) {
          // Readable, but the generation it describes is unknown, so no
          // receipt can prove it finished: handled like an unreadable intent.
          // A valid, still-open link to an old-path generation belongs to the
          // same operation and is carried; a malformed one is not, and that
          // old record keeps blocking under its own name.
          await oldIntent.copy(p.join(
            dir.path,
            'intent.damaged-${DateTime.now().microsecondsSinceEpoch}.json',
          ));
          applying = true;
          try {
            carried = await _openSupersession(deviceId, dir, old);
          } on StateError {
            carried = null;
          }
        } else if (old['applying'] == true &&
            !target.startsWith('capture-slot:') &&
            await _generationCommitted(deviceId, dir.path, old)) {
          // Cleanup may have failed after the previous closure committed. A new
          // photo is not part of that finished operation until beginApply runs,
          // and inherits none of its supersession either.
        } else {
          if (old['apply_protocol'] == 2 && old['applying'] is bool) {
            applying = applying || old['applying'] == true;
          } else if (target.startsWith('capture-slot:')) {
            applying = applying || await stagedMayHaveBeenApplied(deviceId, target);
          } else {
            applying = applying ||
                !await _legacyMetadataSafe(deviceId, target).timeout(kFsProbeTimeout);
          }
          carried = await _openSupersession(deviceId, dir, old);
        }
      }
    }
    supersedes ??= carried;
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
        if (supersedes != null) 'supersedes': supersedes,
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

  /// This device's records, with ownership established where possible. A
  /// record of another device is skipped only when that is provable.
  static Future<List<RecaptureRecord>> _records(String deviceId) async {
    final root = Directory(p.join(
        await UploadStatsDB().getBaseFolder(), 'color_rework'));
    final records = <RecaptureRecord>[];
    if (!await root.exists()) return records;
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(p.basename(entry.path))) {
        continue;
      }
      final intent = File(p.join(entry.path, _intentName));
      if (!await intent.exists()) continue;
      final record = await _inspect(deviceId, entry, intent);
      if (record != null) records.add(record);
    }
    return records;
  }

  static Future<RecaptureRecord?> _inspect(
      String deviceId, Directory entry, File intentFile) async {
    final dirName = p.basename(entry.path);
    Map? data;
    String? intentProblem;
    try {
      final decoded = jsonDecode(await intentFile.readAsString());
      if (decoded is Map && decoded['target'] is String) {
        data = decoded;
      } else {
        intentProblem = 'intent has no target';
      }
    } on FormatException catch (e) {
      intentProblem = 'unreadable intent (${e.message})';
    }
    String? ownerTarget;
    String? ownerFolder;
    final ownerProblems = <String>[];
    var ownedHere = false;
    // An owner naming another device without proof: never a foreign record.
    var contradicted = false;
    final owner = File(p.join(entry.path, _ownerName));
    if (await owner.exists()) {
      try {
        final owned = jsonDecode(await owner.readAsString());
        if (owned is! Map || owned['device_id'] is! String) {
          throw const FormatException('owner record has no device');
        }
        final device = owned['device_id'] as String;
        final target = owned['target'];
        if (device == deviceId) {
          ownedHere = true;
        } else {
          // The directory name hashes the owning device with its target, so a
          // record of another device proves itself. Skip only that.
          final targets = [
            if (target is String) target,
            if (data != null) data['target'] as String,
          ];
          if (targets.any((t) => _keyFor(device, t) == dirName)) return null;
          contradicted = true;
          ownerProblems.add('owner record names device $device, which does '
              'not match its directory');
        }
        if (target is String) {
          if (_keyFor(deviceId, target) == dirName) {
            ownerTarget = target;
            ownedHere = true;
          } else if (!contradicted) {
            ownerProblems.add('owner record does not match its directory');
          }
        } else if (target != null) {
          ownerProblems.add('owner target is not text');
        }
        final folder = owned['folder_key'];
        if (folder is String) {
          // Trusted only beside a target that proves the record. Extra keys
          // only ever block more folders.
          if (ownerTarget != null) ownerFolder = folder;
        } else if (folder != null) {
          ownerProblems.add('owner folder_key is not text');
        }
      } on FormatException catch (e) {
        ownerProblems.add('unreadable owner record (${e.message})');
      }
    }
    if (data != null) {
      final target = data['target'] as String;
      if (_keyFor(deviceId, target) != dirName) {
        // Another device's record, unless something here claims it.
        if (!ownedHere && !contradicted) return null;
        return RecaptureRecord(directory: entry,
            problem: ['intent does not match its directory', ...ownerProblems]
                .join('; '));
      }
      // The target is proven by the directory name. Every other field is
      // checked here, so one damaged record becomes a problem of its own
      // folder instead of an error that stops the device-wide scan.
      final problems = [...ownerProblems];
      final keys = <String>{};
      var attributed = true;
      final folder = data['folder_key'];
      if (folder is String) {
        keys.add(folder);
        if (ownerFolder != null && ownerFolder != folder) {
          keys.add(ownerFolder);
          problems.add('intent and owner record name different folders');
        }
      } else if (folder == null) {
        // Older intents carry no key: the owner's, else the path places it.
        if (ownerFolder != null) keys.add(ownerFolder);
      } else {
        problems.add('intent folder_key is not text');
        if (ownerFolder != null) {
          keys.add(ownerFolder);
        } else {
          // The key is what follows a folder to a changed path; with it
          // corrupt and nothing verified in its place, no folder is ruled out.
          attributed = false;
        }
      }
      final file = data['file'];
      if (file is! String || !AdmissibleName.check(file)) {
        problems.add('intent has no valid generation file');
      }
      return RecaptureRecord(
        directory: entry,
        target: target,
        folderKeys: keys,
        attributed: attributed,
        intent: data,
        problem: problems.isEmpty ? null : problems.join('; '),
      );
    }
    // Unreadable intent: only a verified owner record says whose it is.
    return RecaptureRecord(
      directory: entry,
      target: ownerTarget,
      folderKeys: {if (ownerFolder != null) ownerFolder},
      problem: [intentProblem, ...ownerProblems].whereType<String>().join('; '),
    );
  }

  /// True when [stage] accepts a retake over [record]: an unreadable intent,
  /// or a supported intent whose only damage stage() carries forward. Kept in
  /// step with [stage], so guidance never advises an action that fails.
  static bool _retakeReplaces(RecaptureRecord record) {
    final data = record.intent;
    if (record.target == null) return false;
    if (data == null) return true;
    final protocol = data['apply_protocol'];
    if (protocol != null && protocol != 2) return false;
    if (protocol == 2 && data['applying'] is! bool) return false;
    final name = data['file'];
    if (name is! String || !AdmissibleName.check(name)) return true;
    try {
      _supersedesRef(data, record.directory);
    } on StateError {
      return false;
    }
    return true;
  }

  static bool _inFolder(RecaptureRecord record, String folderKey, String folderPath) =>
      record.folderKeys.contains(folderKey) ||
      _folderTail(p.dirname(record.target!)) == _folderTail(folderPath);

  /// Interrupted or unreadable records that concern this folder (by folder key
  /// or folder path, whatever path the record was made under), plus records
  /// that cannot be attributed to any folder. Committed generations whose
  /// cleanup failed are not listed.
  static Future<List<RecaptureRecord>> outstanding(
    String deviceId, {
    required String folderKey,
    required String folderPath,
  }) async {
    final result = <RecaptureRecord>[];
    for (final record in await _records(deviceId)) {
      if (record.unattributed) {
        result.add(record);
        continue;
      }
      if (record.target!.startsWith('capture-slot:')) continue;
      if (!_inFolder(record, folderKey, folderPath)) continue;
      final data = record.intent;
      if (data == null || record.problem != null) {
        result.add(record);
        continue;
      }
      if (await _generationCommitted(deviceId, record.directory.path, data)) continue;
      // Anything but a v2 "not started" blocks the guard, so it is listed.
      if (data['applying'] != false || data['apply_protocol'] != 2) result.add(record);
    }
    return result;
  }

  /// Check local recovery state without opening the photo share. A successful
  /// mixed submit may finish its own verified generations in the same DB
  /// transaction. Other applying generations (including siblings no longer in
  /// the current worklist) must stay open. Old records lacking the v2 ordering
  /// guarantee are the only case requiring a bounded remote recovery check.
  ///
  /// A record whose intent cannot be read, or holds a field of the wrong type,
  /// blocks only its own folder when its target and folder are proven (by the
  /// intent or by the owner record); otherwise it blocks every folder on this
  /// device (see docs/COLOR-CALIBRATION.zh-CN.md).
  static Future<void> assertMetadataSafe(
    String deviceId, {
    required String folderKey,
    required String folderPath,
    Iterable<File> completing = const [],
  }) async {
    final finished = completing
        .map((file) => p.normalize(file.absolute.path).toLowerCase())
        .toSet();
    final superseded = <String>{};
    for (final file in completing) {
      final old = await supersededGeneration(file);
      if (old != null) superseded.add(p.normalize(old.absolute.path).toLowerCase());
    }
    for (final record in await _records(deviceId)) {
      if (record.unattributed) {
        throw StateError('Cannot safely submit metadata: a damaged recapture '
            'record cannot be attributed to a folder (${record.describe()}; '
            '${record.problem}). Metadata submissions on this station wait '
            'until an administrator resolves it.');
      }
      final target = record.target!;
      if (target.startsWith('capture-slot:')) continue;
      if (!_inFolder(record, folderKey, folderPath)) continue;
      final data = record.intent;
      if (data == null || record.problem != null) {
        throw StateError('Cannot safely submit metadata for this folder: '
            'the recapture record is damaged (${record.describe()}; '
            '${record.problem}). ${_retakeReplaces(record)
                ? 'Recapture that page to replace it; if the page is not in '
                    'the rework list, an administrator must resolve the record.'
                : 'Recapturing cannot replace it; an administrator must '
                    'resolve the record.'}');
      }
      final name = data['file'];
      if (name is! String || !AdmissibleName.check(name)) {
        throw StateError('Cannot safely submit metadata for this folder: '
            'invalid recapture generation (${record.describe()})');
      }
      if (data['apply_protocol'] != null && data['apply_protocol'] != 2) {
        throw StateError('Cannot safely submit metadata for this folder: '
            'unsupported recapture apply protocol (${record.describe()})');
      }
      if (data['apply_protocol'] == 2 && data['applying'] is! bool) {
        throw StateError('Cannot safely submit metadata for this folder: '
            'invalid recapture applying state (${record.describe()})');
      }
      final generation =
          p.normalize(p.join(record.directory.path, name)).toLowerCase();
      if (finished.contains(generation) || superseded.contains(generation)) continue;
      if (await _generationCommitted(deviceId, record.directory.path, data)) continue;
      if (data['applying'] == true) {
        throw StateError('Cannot safely submit metadata for this folder: an '
            'interrupted recapture must be completed first (${record.describe()}).');
      }
      if (data['apply_protocol'] == 2 && data['applying'] == false) continue;
      // A pre-v2 submit could hold the remote gate before recording applying.
      // No local evidence proves it untouched; never interpret offline as no
      // replacement. Once recovered, ordinary metadata is local-only again.
      try {
        final safe = await _legacyMetadataSafe(deviceId, target)
            .timeout(kFsProbeTimeout);
        if (!safe) throw StateError('Legacy recapture still needs recovery.');
      } catch (e) {
        throw StateError('Cannot safely submit metadata for this folder: $e '
            '(${record.describe()})');
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

  /// True when the folders of [oldTarget] and [newTarget] are one directory
  /// seen through two paths: a probe file created through the old path is
  /// visible through the new one. Unreachable or different means false.
  static Future<bool> sameDestination(String oldTarget, String newTarget) async {
    final oldDir = p.normalize(p.dirname(oldTarget));
    final newDir = p.normalize(p.dirname(newTarget));
    if (oldDir.toLowerCase() == newDir.toLowerCase()) return true;
    final name = '.lwcam-identity-${DateTime.now().microsecondsSinceEpoch}-'
        '${Random.secure().nextInt(1 << 32)}.tmp';
    final probe = File(longPath(p.join(oldDir, name)));
    try {
      await probe.writeAsString('', flush: true).timeout(kFsProbeTimeout);
      return await probeExists(File(longPath(p.join(newDir, name)))) == FsProbe.found;
    } catch (_) {
      return false;
    } finally {
      try {
        await probe.delete().timeout(kFsProbeTimeout);
      } catch (_) {
        // Best effort: a .tmp file is never counted or published by LWIP.
      }
    }
  }

  /// Continues an interrupted recapture of [page] that was recorded under an
  /// older path for the same folder, at [newTarget]. Allowed only when the old
  /// path is proven to be the same directory, so finishing at [newTarget]
  /// replaces the same photo and clears the same readiness gate. The old
  /// generation is copied (and re-verified) into a new generation that is
  /// applying from the start and names the old one; the old record is retired
  /// only by the closure that commits the new one.
  ///
  /// Returns null when there is nothing to continue. Throws, naming the page
  /// and the old record, when the old location cannot be proven the same.
  static Future<File?> relocateApplying(
    String deviceId, {
    required String folderKey,
    required String folderPath,
    required String newTarget,
  }) async {
    final page = p.basename(newTarget).toLowerCase();
    final wanted = _keyFor(deviceId, newTarget);
    final candidates = <RecaptureRecord>[];
    for (final record in await _records(deviceId)) {
      final data = record.intent;
      if (record.target == null || data == null || record.problem != null) continue;
      if (record.target!.startsWith('capture-slot:')) continue;
      if (p.basename(record.directory.path) == wanted) continue;
      if (p.basename(record.target!).toLowerCase() != page) continue;
      if (!_inFolder(record, folderKey, folderPath)) continue;
      if (data['applying'] != true) continue;
      if (await _generationCommitted(deviceId, record.directory.path, data)) continue;
      candidates.add(record);
    }
    if (candidates.isEmpty) return null;
    if (candidates.length > 1) {
      throw StateError('Several interrupted recaptures exist for this page: '
          '${candidates.map((r) => r.describe()).join(' | ')}');
    }
    final old = candidates.single;
    if (await (await _intentFile(deviceId, newTarget)).exists()) {
      throw StateError('A recapture record already exists at the current path '
          'for ${p.basename(newTarget)}; resolve it before continuing '
          '${old.describe()}');
    }
    final oldStaged = await _verifiedGeneration(old.directory, old.intent!);
    if (!await sameDestination(old.target!, newTarget)) {
      throw StateError('An interrupted recapture of ${p.basename(newTarget)} '
          'was started under a path that is unreachable or is not this folder '
          '(${old.describe()}). Its readiness gate may still be held there. '
          'Restore that location (Station Setup input folder) and reopen '
          'rework to finish it.');
    }
    final binding = ColorBinding.fromJson(Map<String, dynamic>.from(
        jsonDecode(await File('${oldStaged.path}.color.json').readAsString()) as Map));
    return stage(deviceId, newTarget, oldStaged, binding,
        folderKey: folderKey,
        applying: true,
        supersedes: {
          'record': p.basename(old.directory.path),
          'file': p.basename(oldStaged.path),
        });
  }

  /// The old-path generation [staged] continues, when it was relocated.
  static Future<File?> supersededGeneration(File staged) async {
    final intent = File(p.join(staged.parent.path, _intentName));
    if (!await intent.exists()) return null;
    final data = jsonDecode(await intent.readAsString());
    if (data is! Map || data['file'] != p.basename(staged.path)) return null;
    final ref = _supersedesRef(data, staged.parent);
    if (ref == null) return null;
    return File(p.join(staged.parent.parent.path, ref.record, ref.file));
  }

  /// The validated `supersedes` reference of the intent [data] in [dir].
  static ({String record, String file})? _supersedesRef(Map data, Directory dir) {
    final link = data['supersedes'];
    if (link == null) return null;
    final record = link is Map ? link['record'] : null;
    final file = link is Map ? link['file'] : null;
    if (record is! String || !RegExp(r'^[0-9a-f]{64}$').hasMatch(record) ||
        record == p.basename(dir.path) ||
        file is! String || !AdmissibleName.check(file)) {
      throw StateError('Invalid superseded recapture reference (record ${dir.path})');
    }
    return (record: record, file: file);
  }

  /// The old-path generation that the unfinished relocated operation in [dir]
  /// (whose current intent is [data]) still has to retire. A retake continues
  /// that operation, so the new generation must name the same old generation,
  /// or no closure could ever retire the old record. The reference is dropped
  /// only when that exact generation is provably finished: the old record has
  /// no intent left, or the generation's closure committed. It names one file,
  /// so it never exempts a newer generation staged at the old path.
  static Future<Map<String, String>?> _openSupersession(
      String deviceId, Directory dir, Map data) async {
    final ref = _supersedesRef(data, dir);
    if (ref == null) return null;
    final oldRecord = p.join(dir.parent.path, ref.record);
    if (!await File(p.join(oldRecord, _intentName)).exists()) return null;
    if (await _generationCommitted(deviceId, oldRecord, {'file': ref.file})) {
      return null;
    }
    return {'record': ref.record, 'file': ref.file};
  }

  /// Retires the record of [staged] if it still points at that generation.
  static Future<void> completeGeneration(File staged) async {
    if (!isStoreFile(staged)) throw StateError('Invalid recapture store file');
    final intent = File(p.join(staged.parent.path, _intentName));
    if (!await intent.exists()) return;
    final data = jsonDecode(await intent.readAsString());
    if (data is Map && data['file'] == p.basename(staged.path)) {
      await intent.delete();
    }
  }

  static Future<File> _verifiedGeneration(Directory dir, Map data) async {
    final name = data['file'];
    if (name is! String || !AdmissibleName.check(name)) {
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

  static Future<File?> pending(String deviceId, String target) async {
    final dir = await _directory(deviceId, target);
    final intent = File(p.join(dir.path, _intentName));
    if (!await intent.exists()) return null;
    final data = jsonDecode(await intent.readAsString()) as Map;
    return _verifiedGeneration(dir, data);
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

  /// Recovers each page on its own. A damaged record is reported by page and
  /// left untouched (intent, staged bytes and the page's pending protection),
  /// so it is never treated as recovered; the other pages still load. Retaking
  /// the page stages a new generation that keeps the unresolved obligation.
  static Future<CaptureSlotRecovery> recoverCaptureSlots(
    String deviceId,
    Iterable<String> names, {
    required String Function(String name) dateKeyFor,
    required String username,
  }) async {
    final result = CaptureSlotRecovery();
    for (final name in names) {
      try {
        final file = await recoverCaptureSlot(deviceId, name,
            dateKey: dateKeyFor(name), username: username);
        if (file != null) result.recovered[name] = file;
      } catch (e) {
        final dir = p.dirname((await _intentFile(deviceId, 'capture-slot:$name')).path);
        result.failed[name] = '$e (record $dir)';
      }
    }
    return result;
  }

  /// Retain pending/applying generations and referenced overlays indefinitely.
  /// Only unreferenced generations older than 30 days are disposable. An
  /// intent is removed only when its generation's closure provably committed
  /// (the cleanup after that commit failed). Staged-but-unsubmitted intents
  /// are kept however old: a session may still hold them.
  static Future<void> prune(String deviceId, {DateTime? now}) async {
    final root = Directory(p.join(await UploadStatsDB().getBaseFolder(), 'color_rework'));
    if (!await root.exists()) return;
    final cutoff = (now ?? DateTime.now()).subtract(const Duration(days: 30));
    final records = await UploadStatsDB().getReplacementRecords(deviceId);
    final protected = records.where((r) => r['transferred_at'] == null)
        .map((r) => r['replacement_local_path']).whereType<String>().toSet();
    await for (final entry in root.list(followLinks: false)) {
      if (entry is! Directory || !RegExp(r'^[0-9a-f]{64}$').hasMatch(p.basename(entry.path))) continue;
      try {
        await _pruneRecord(deviceId, entry, cutoff, protected);
      } catch (e) {
        // One unreadable record must not stop retention for the others.
        print('ℹ️ Recapture retention skipped ${entry.path}: $e');
      }
    }
  }

  static Future<void> _pruneRecord(String deviceId, Directory entry,
      DateTime cutoff, Set<String> protected) async {
    final owner = File(p.join(entry.path, _ownerName));
    if (!await owner.exists() || (jsonDecode(await owner.readAsString()) as Map)['device_id'] != deviceId) return;
    final intent = File(p.join(entry.path, _intentName));
    if (await intent.exists()) {
      final data = jsonDecode(await intent.readAsString());
      if (data is! Map || data['target'] is! String) return;
      final target = data['target'] as String;
      final committed = !target.startsWith('capture-slot:') &&
          data['applying'] == true &&
          await _generationCommitted(deviceId, entry.path, data);
      if (!committed) return; // Unknown, pending or active: keep it all.
      await intent.delete();
    }
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
