// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Retries [op] on a THROWN error only — a normal return value (including
/// `false`) is a result, not a failure, and is returned as-is. Sleeps
/// [delays] BETWEEN attempts, so `delays.length + 1` attempts total; the
/// default is 3 attempts (100ms then 300ms between). Rethrows the last error
/// after the final attempt.
///
/// Used for the capture-time DB write, whose realistic failure is a transient
/// WAL lock that a short backoff clears — see BoxSessionController.assignNewImage
/// and box_integrity.healOrphanImages.
Future<T> retrying<T>(
  Future<T> Function() op, {
  List<Duration> delays = const [
    Duration(milliseconds: 100),
    Duration(milliseconds: 300),
  ],
}) async {
  for (var attempt = 0;; attempt++) {
    try {
      return await op();
    } catch (_) {
      if (attempt >= delays.length) rethrow;
      await Future<void>.delayed(delays[attempt]);
    }
  }
}

/// One stashed orphan: an image whose capture-time assignment could not be
/// written to the DB (transient error, crash, or no active folder). The
/// bytes live at [file]; [sidecar] holds the recovery intent (see the class
/// docs on OrphanImageStore). When the sidecar is missing/corrupt the intent
/// is unknown ([intentKnown] false) and only an admin can resolve it.
class OrphanEntry {
  final File file;
  final File? sidecar;
  final String deviceId;

  /// The REAL device filename this image should be filed under — never the
  /// possibly-uniquified on-disk stored name.
  final String deviceFilename;

  final int? boxId;
  final int? folderId;
  final String? reason;
  final DateTime? stashedAt;
  final String? note;

  const OrphanEntry({
    required this.file,
    required this.sidecar,
    required this.deviceId,
    required this.deviceFilename,
    this.boxId,
    this.folderId,
    this.reason,
    this.stashedAt,
    this.note,
  });

  /// Auto-healable: we know exactly which box+folder this belonged to.
  bool get intentKnown => boxId != null && folderId != null;
}

/// Filesystem ledger of images that failed to record their DB assignment at
/// capture time. DELIBERATELY NOT a DB table: a stash happens precisely when
/// the DB write failed, so recording it in that same DB would be
/// self-defeating. Each orphan is a copied image plus a `<stored>.intent.json`
/// sidecar carrying its recovery intent.
///
/// Layout: `<AppSupport>/orphan_images/<deviceId>/<storedName>` (+ sidecar).
///
/// Dependency-light (no GetX): [resolveBaseDir] is injected so tests drive it
/// against a temp dir — the AuditLogService pattern.
class OrphanImageStore {
  final Future<Directory> Function() _resolveBaseDir;

  OrphanImageStore({required Future<Directory> Function() resolveBaseDir})
      : _resolveBaseDir = resolveBaseDir;

  factory OrphanImageStore.production() {
    return OrphanImageStore(
      resolveBaseDir: () async {
        final baseDir = await getApplicationSupportDirectory();
        final dir = Directory(p.join(baseDir.path, 'orphan_images'));
        if (!dir.existsSync()) dir.createSync(recursive: true);
        return dir;
      },
    );
  }

  static const String _sidecarSuffix = '.intent.json';

  Future<Directory> _deviceDir(String deviceId) async {
    final base = await _resolveBaseDir();
    final dir = Directory(p.join(base.path, deviceId));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// COPIES [source] into the device's stash (never moves — the source is the
  /// live gallery cache file the open session's tile is still displaying) and
  /// writes the intent sidecar. Returns null on any I/O failure (the caller
  /// has nowhere left to escalate — it just logs). The on-disk stored name is
  /// uniquified on collision (`IMG_x.jpg` -> `IMG_x~2.jpg`); the sidecar
  /// always records the true [deviceFilename]. The sidecar is written AFTER
  /// the image copy, so a crash between the two leaves an intent-unknown
  /// entry — the safe, admin-resolvable state.
  Future<OrphanEntry?> stash({
    required File source,
    required String deviceId,
    required String deviceFilename,
    int? boxId,
    int? folderId,
    required String reason,
    DateTime? stashedAt,
  }) async {
    try {
      final dir = await _deviceDir(deviceId);
      final storedName = _uniqueStoredName(dir, deviceFilename);
      final dest = File(p.join(dir.path, storedName));
      await source.copy(dest.path);

      final at = stashedAt ?? DateTime.now();
      final sidecar = File('${dest.path}$_sidecarSuffix');
      await sidecar.writeAsString(
        jsonEncode({
          'deviceFilename': deviceFilename,
          'boxId': boxId,
          'folderId': folderId,
          'reason': reason,
          'stashedAt': at.toIso8601String(),
          'note': null,
        }),
        flush: true,
      );

      return OrphanEntry(
        file: dest,
        sidecar: sidecar,
        deviceId: deviceId,
        deviceFilename: deviceFilename,
        boxId: boxId,
        folderId: folderId,
        reason: reason,
        stashedAt: at,
      );
    } catch (e) {
      print('⚠️ OrphanImageStore.stash failed for $deviceFilename: $e');
      return null;
    }
  }

  /// Free stored name that collides with neither an existing file nor its
  /// sidecar. Inserts `~N` before the extension.
  String _uniqueStoredName(Directory dir, String deviceFilename) {
    bool taken(String name) =>
        File(p.join(dir.path, name)).existsSync() ||
        File(p.join(dir.path, '$name$_sidecarSuffix')).existsSync();

    if (!taken(deviceFilename)) return deviceFilename;
    final ext = p.extension(deviceFilename);
    final stem = deviceFilename.substring(0, deviceFilename.length - ext.length);
    for (var i = 2;; i++) {
      final candidate = '$stem~$i$ext';
      if (!taken(candidate)) return candidate;
    }
  }

  /// Every orphan for [deviceId]. An image file with no readable sidecar
  /// lists as intent-unknown (its stored basename is used as a best-effort
  /// deviceFilename). Sidecar files themselves are skipped.
  Future<List<OrphanEntry>> list(String deviceId) async {
    final dir = await _deviceDir(deviceId);
    final out = <OrphanEntry>[];
    for (final entity in dir.listSync().whereType<File>()) {
      if (entity.path.endsWith(_sidecarSuffix)) continue;
      out.add(await _readEntry(entity, deviceId));
    }
    out.sort((a, b) => (a.stashedAt ?? DateTime(0)).compareTo(b.stashedAt ?? DateTime(0)));
    return out;
  }

  /// Every orphan across every device subdir — for the admin screen.
  Future<List<OrphanEntry>> listAll() async {
    final base = await _resolveBaseDir();
    final out = <OrphanEntry>[];
    if (!base.existsSync()) return out;
    for (final deviceDir in base.listSync().whereType<Directory>()) {
      out.addAll(await list(p.basename(deviceDir.path)));
    }
    return out;
  }

  Future<OrphanEntry> _readEntry(File imageFile, String deviceId) async {
    final sidecar = File('${imageFile.path}$_sidecarSuffix');
    final fallbackName = p.basename(imageFile.path);
    if (!sidecar.existsSync()) {
      return OrphanEntry(
        file: imageFile,
        sidecar: null,
        deviceId: deviceId,
        deviceFilename: fallbackName,
      );
    }
    try {
      final json = jsonDecode(await sidecar.readAsString()) as Map<String, dynamic>;
      return OrphanEntry(
        file: imageFile,
        sidecar: sidecar,
        deviceId: deviceId,
        deviceFilename: (json['deviceFilename'] as String?) ?? fallbackName,
        boxId: (json['boxId'] as num?)?.toInt(),
        folderId: (json['folderId'] as num?)?.toInt(),
        reason: json['reason'] as String?,
        stashedAt: DateTime.tryParse(json['stashedAt']?.toString() ?? ''),
        note: json['note'] as String?,
      );
    } catch (_) {
      // Corrupt sidecar → treat as intent-unknown (admin resolves).
      return OrphanEntry(
        file: imageFile,
        sidecar: sidecar,
        deviceId: deviceId,
        deviceFilename: fallbackName,
      );
    }
  }

  /// Drops the box/folder intent (keeps the bytes) and stamps a [note] — used
  /// by heal when the intended folder/box is gone or the name now belongs
  /// elsewhere, so the entry falls to the admin screen.
  Future<void> demoteToUnknown(OrphanEntry e, {required String note}) async {
    final sidecar = e.sidecar ?? File('${e.file.path}$_sidecarSuffix');
    await sidecar.writeAsString(
      jsonEncode({
        'deviceFilename': e.deviceFilename,
        'boxId': null,
        'folderId': null,
        'reason': e.reason,
        'stashedAt': (e.stashedAt ?? DateTime.now()).toIso8601String(),
        'note': note,
      }),
      flush: true,
    );
  }

  /// Permanently removes the orphan (image + sidecar). Never throws.
  Future<void> discard(OrphanEntry e) async {
    for (final f in [e.file, e.sidecar]) {
      try {
        if (f != null && f.existsSync()) await f.delete();
      } catch (err) {
        print('⚠️ OrphanImageStore.discard could not delete ${f?.path}: $err');
      }
    }
  }

  /// Files the orphan into [targetDir] under its true [OrphanEntry.deviceFilename]
  /// (the durable box store), then removes the stash pair. Returns the landed
  /// file.
  Future<File> resolveInto(OrphanEntry e, Directory targetDir) async {
    if (!targetDir.existsSync()) await targetDir.create(recursive: true);
    final landed = File(p.join(targetDir.path, e.deviceFilename));
    await e.file.copy(landed.path);
    await discard(e);
    return landed;
  }
}
