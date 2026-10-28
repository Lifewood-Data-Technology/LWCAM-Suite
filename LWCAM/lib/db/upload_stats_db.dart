// Local SQLite store for the capture app (LWCAM, first stage of the pipeline:
// capture app -> LWIP -> QC -> Upload). One singleton, UploadStatsDB, owns one
// STABLE database per device/operator (capture boxes, folders, image
// assignments, replacement records, the sync outbox) plus MONTHLY databases
// that hold only the high-volume upload_records and daily_summary tables.
// Things to know before editing: capture changes are written to the outbox in
// the same transaction as the change, and SyncService later drains the outbox
// to PostgreSQL using natural keys (never local ids); schema upgrades are
// additive and run on every open, so keep them safe to repeat.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'dart:io';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import '../models/capture_box_models.dart';
import '../services/image_name_mapping.dart';
import '../services/sync_models.dart';
import '../services/transfer_destination_service.dart';

enum DeviceDatabaseHealth {
  missing,
  healthy,
  corrupt,

  /// The file could not be inspected for a TRANSIENT reason — busy, locked,
  /// a timeout, I/O, permissions. Means "try again later", never grounds to
  /// rebuild. Distinct from [corrupt] because inspecting opens the DB, and
  /// that open runs schema DDL which takes a write lock: a concurrent box
  /// transfer or an AV scanner holding the file used to be reported as
  /// corruption and offered a destructive rebuild.
  unavailable,
}

/// True only for SQLite errors that mean the FILE ITSELF is damaged.
bool isSqliteCorruptionError(Object error) {
  final message = error.toString().toLowerCase();
  return message.contains('malformed') ||
      message.contains('not a database') ||
      message.contains('database disk image') ||
      message.contains('file is encrypted');
}

class TransferProtectionHandle {
  final String deviceId;
  final File localLockFile;
  final RandomAccessFile localLockRaf;

  const TransferProtectionHandle({
    required this.deviceId,
    required this.localLockFile,
    required this.localLockRaf,
  });
}

/// Why a folder's colour calibration cannot be written as-is.
///
/// [unknownBinding] is the one the operator may explicitly accept as
/// historical after a recovery; the other two are hard failures.
enum ColorCalibrationIssueKind {
  unknownBinding,
  damagedBinding,
  pendingRecapture,
}

class ColorCalibrationIssue {
  final String imageName;
  final ColorCalibrationIssueKind kind;
  final String reason;

  const ColorCalibrationIssue({
    required this.imageName,
    required this.kind,
    required this.reason,
  });

  String get message => switch (kind) {
    ColorCalibrationIssueKind.unknownBinding =>
      'no stored colour decision after recovery ($reason)',
    ColorCalibrationIssueKind.damagedBinding =>
      'damaged colour binding ($reason)',
    ColorCalibrationIssueKind.pendingRecapture =>
      'interrupted recapture ($reason)',
  };
}

class FolderColorCalibration {
  final Map<String, dynamic> marker;
  final List<ColorCalibrationIssue> issues;

  const FolderColorCalibration({
    required this.marker,
    required this.issues,
  });

  bool get hasIssues => issues.isNotEmpty;

  String get issueSummary =>
      issues.map((issue) => '${issue.imageName}: ${issue.message}').join('; ');
}

class UploadStatsDB {
  static const int _stableSchemaVersion = 3;
  static final UploadStatsDB _instance = UploadStatsDB._internal();
  factory UploadStatsDB() => _instance;
  UploadStatsDB._internal();

  String? _baseFolder;

  /// STABLE per-device DBs, keyed by device id. One handle per device, kept
  /// open for the process's life: a station touches only a few (its operators'
  /// operator ids), all WAL-mode, so holding them is cheap.
  ///
  /// This used to be ONE handle plus a `_currentDeviceId` string, closed and
  /// reopened on every device switch. That pairing could desynchronize: the id
  /// was assigned before the open completed, so two concurrent switches to
  /// different devices could leave the cached id naming one device and the
  /// cached handle pointing at ANOTHER device's file — after which every query
  /// for the "matching" id silently ran against the wrong database. Login can
  /// trigger exactly that (two device DB opens racing each other), so an
  /// account switch could make a still-open box vanish from the box list for
  /// the rest of the session — and, worse, could have written new captures into
  /// the other device's DB. Keyed handles remove the race by construction.
  final Map<String, Database> _deviceDbs = {};

  /// Monthly device DBs (upload_records/daily_summary/their own sync_outbox
  /// — see the "MONTHLY ROTATION" section below), keyed `deviceId|YYYY-MM`.
  final Map<String, Database> _monthlyDbs = {};

  /// In-flight opens for [_deviceDbs] / [_monthlyDbs]. Two concurrent callers
  /// for the same key share ONE open instead of both creating a handle — the
  /// loser's would leak, holding the file open for the rest of the process.
  final Map<String, Future<Database>> _openingDeviceDbs = {};
  final Map<String, Future<Database>> _openingMonthlyDbs = {};

  /// Device ids whose file is mid-[rebuildFromCaptureSnapshot] promotion.
  /// [_cachedOpen] refuses to open these: between evicting the cached handle
  /// and the final rename the live path does not exist, and any reopen would
  /// create an empty database there.
  final Set<String> _recoveringDeviceIds = {};

  // =======================================================
  // PATH HANDLING
  // =======================================================

  Future<String> _ensurePathExists() async {
    if (_baseFolder != null && _baseFolder!.trim().isNotEmpty) {
      final cached = Directory(_baseFolder!);
      if (!cached.existsSync()) {
        await cached.create(recursive: true);
      }
      return cached.path;
    }

    Directory _resolvePrimaryDir() {
      final home =
          Platform.environment['USERPROFILE'] ??
          Platform.environment['HOME'] ??
          'C:\\';
      return Directory(p.join(home, 'LWCAM_DBs'));
    }

    Future<String> _prepare(Directory dir, {required bool fallback}) async {
      if (!dir.existsSync()) {
        await dir.create(recursive: true);
        print(
          fallback
              ? "📦 Created fallback DB folder at: ${dir.path}"
              : "📂 Created DB folder at: ${dir.path}",
        );
      } else {
        print(
          fallback
              ? "📦 Fallback DB folder verified: ${dir.path}"
              : "📁 DB folder verified: ${dir.path}",
        );
      }
      _baseFolder = dir.path;
      return dir.path;
    }

    try {
      return await _prepare(_resolvePrimaryDir(), fallback: false);
    } catch (e) {
      print("❌ Failed to access main DB path (home-based): $e");
      final fallbackBase = await getDatabasesPath();
      return await _prepare(
        Directory(p.join(fallbackBase, 'LWCAM_DBs')),
        fallback: true,
      );
    }
  }

  // =======================================================
  // PATH HELPERS (PUBLIC)
  // =======================================================

  Future<String> getBaseFolder() async => _ensurePathExists();

  /// Checks one stable device file without creating a new file when it is
  /// missing. Existing v1 files are opened normally so the v2 migration runs.
  Future<DeviceDatabaseHealth> inspectDeviceDatabase(String deviceId) async {
    final path = await getDeviceDbFilePath(deviceId);
    if (!File(path).existsSync()) return DeviceDatabaseHealth.missing;
    try {
      final db = await getDatabase(deviceId);
      final rows = await db.rawQuery('''
        SELECT COUNT(*) AS c
        FROM sqlite_master
        WHERE type = 'table'
          AND name IN (
            'capture_boxes', 'capture_folders', 'capture_images', 'sync_outbox'
          )
      ''');
      return (rows.first['c'] as num).toInt() == 4
          ? DeviceDatabaseHealth.healthy
          : DeviceDatabaseHealth.corrupt;
    } catch (e) {
      if (isSqliteCorruptionError(e)) return DeviceDatabaseHealth.corrupt;
      print('⚠️ Could not inspect $deviceId DB — treating as transient: $e');
      return DeviceDatabaseHealth.unavailable;
    }
  }

  /// Copies the tables a PostgreSQL snapshot CANNOT rebuild out of the damaged
  /// file and into the replacement.
  ///
  /// `sync_outbox` is the critical one: an outbox row IS the un-pushed delta to
  /// PG, so it exists nowhere else — the snapshot being restored over it is by
  /// definition missing that work. Losing it silently leaves a transferred box
  /// stuck 'OPEN' in the cloud forever and drops submitted QC rework closures.
  /// `replacement_records` (the device's recapture/supersede audit history) and
  /// the stable file's legacy `upload_records`/`daily_summary` are local-only
  /// too. `processing_ledger` is deliberately NOT carried — nothing writes to
  /// it anymore now that LWIP reports finished folders straight to PostgreSQL
  /// itself; the table stays only so an existing station DB's schema version
  /// still matches.
  ///
  /// Best-effort by design: each table is independent, and an unreadable one is
  /// logged and skipped rather than failing the whole recovery. Salvaging some
  /// of it beats salvaging none. Only the columns the two schemas share are
  /// copied, so an older damaged file still carries over what it can.
  Future<void> _carryOverLocalOnlyTables(
    Database recovering,
    String oldPath,
  ) async {
    if (!File(oldPath).existsSync()) return;

    final escaped = oldPath.replaceAll("'", "''");
    try {
      await recovering.execute("ATTACH DATABASE '$escaped' AS damaged");
    } catch (e) {
      print(
        '⚠️ Recovery: the damaged file could not be read at all — queued '
        'cloud updates and recapture history cannot be carried over: $e',
      );
      await recovering.insert('color_integrity', {'id': 1, 'reason': 'Original local database unreadable'}, conflictAlgorithm: ConflictAlgorithm.replace);
      return;
    }

    // A v2 database predates the calibration tables: their absence there is
    // normal, not a recovery failure. Only a v3 (or unreadable) source can
    // have colour data to lose.
    int? oldVersion;
    try {
      oldVersion = Sqflite.firstIntValue(
        await recovering.rawQuery('PRAGMA damaged.user_version'),
      );
    } catch (_) {
      oldVersion = null;
    }
    final mayHaveColourData = oldVersion == null || oldVersion >= 3;

    Future<Set<String>> columnsOf(String schema, String table) async {
      final rows = await recovering.rawQuery(
        'PRAGMA $schema.table_info($table)',
      );
      return rows.map((r) => r['name'] as String).toSet();
    }

    for (final table in const [
      'sync_outbox',
      'replacement_records',
      'color_pending',
      'color_integrity',
      'color_profiles',
      'color_bindings',
      'upload_records',
      'daily_summary',
    ]) {
      try {
        final shared = (await columnsOf(
          'main',
          table,
        )).intersection(await columnsOf('damaged', table)).toList();
        if (shared.isEmpty) {
          if (table.startsWith('color_') && mayHaveColourData) {
            await recovering.insert(
              'color_integrity',
              {'id': 1, 'reason': 'Could not recover $table'},
              conflictAlgorithm: ConflictAlgorithm.replace,
            );
          }
          continue;
        }
        final columnList = shared.map((c) => '"$c"').join(', ');
        await recovering.execute(
          'INSERT OR IGNORE INTO $table ($columnList) '
          'SELECT $columnList FROM damaged.$table',
        );
        final carried = Sqflite.firstIntValue(
          await recovering.rawQuery('SELECT COUNT(*) FROM $table'),
        );
        print('🧷 Recovery carried over $carried row(s) into $table');
      } catch (e) {
        if (table.startsWith('color_') && mayHaveColourData) {
          await recovering.insert('color_integrity', {'id': 1, 'reason': 'Could not recover $table'}, conflictAlgorithm: ConflictAlgorithm.replace);
        }
        print('⚠️ Recovery: could not carry over $table — skipped: $e');
      }
    }

    try {
      await recovering.execute('DETACH DATABASE damaged');
    } catch (_) {}
  }

  /// Builds and validates a replacement beside the live DB, then promotes it
  /// atomically. The original is not touched until every PostgreSQL page has
  /// landed and the replacement passes SQLite/relationship checks.
  Future<CaptureSnapshotCounts> rebuildFromCaptureSnapshot({
    required String deviceId,
    required CaptureSnapshotPull pull,
    required bool requireNonEmpty,
  }) async {
    final path = await getDeviceDbFilePath(deviceId);
    final recoveringPath = '$path.recovering';
    for (final suffix in ['', '-wal', '-shm', '-journal']) {
      final stale = File('$recoveringPath$suffix');
      if (stale.existsSync()) await stale.delete();
    }

    Database? recovering;
    try {
      recovering = await _openStableDatabase(recoveringPath, deviceId);
      final counts = await pull(
        onBoxes: (rows) => recovering!.transaction((txn) async {
          for (final box in rows) {
            final createdAt = box.createdAt ?? DateTime.now().toIso8601String();
            await txn.insert('capture_boxes', {
              'id': box.id,
              'box_name': box.boxName,
              'device_id': deviceId,
              'status': box.status.toUpperCase() == 'OPEN'
                  ? 'OPEN'
                  : 'TRANSFERRED',
              'user_id': box.userId,
              'project_id': box.projectId,
              'project_key': box.projectKey,
              'template_json': box.templateJson,
              'created_at': createdAt,
              'updated_at': createdAt,
              'transfer_end_at': box.transferEndAt,
              'transferred_to': box.transferredTo,
            });
          }
        }),
        onFolders: (rows) => recovering!.transaction((txn) async {
          for (final folder in rows) {
            final createdAt =
                folder.sourceCreatedAt ?? DateTime.now().toIso8601String();
            await txn.insert('capture_folders', {
              'id': folder.id,
              'box_id': folder.boxId,
              'folder_seq': folder.folderSeq,
              'folder_name': folder.folderName,
              ...folder.metadata,
              'source_created_at': createdAt,
              'source_updated_at': folder.sourceUpdatedAt ?? createdAt,
              'is_deskewed': folder.isDeskewed ? 1 : 0,
              'is_cropped': folder.isCropped ? 1 : 0,
              'is_created_thumbnail': folder.isCreatedThumbnail ? 1 : 0,
              'folder_path': folder.folderPath,
              'thumbnail_path': folder.thumbnailPath,
              'qc_status': folder.qcStatus ?? 'PENDING',
              'is_complete': 1,
            });
          }
        }),
        onImages: (rows) => recovering!.transaction((txn) async {
          if (rows.isEmpty) return;
          final folderIds = rows.map((row) => row.folderId).toSet().toList();
          final placeholders = List.filled(folderIds.length, '?').join(',');
          final folderRows = await txn.rawQuery(
            'SELECT id, box_id FROM capture_folders '
            'WHERE id IN ($placeholders)',
            folderIds,
          );
          final boxByFolder = {
            for (final row in folderRows)
              (row['id'] as num).toInt(): (row['box_id'] as num).toInt(),
          };
          for (final image in rows) {
            if (image.deviceId != deviceId) {
              throw StateError(
                'Snapshot image ${image.id} belongs to ${image.deviceId}, '
                'not $deviceId',
              );
            }
            final localName = sourceImageNameFromCloudImage(
              deviceId,
              image.imageName,
            );
            if (localName == null) {
              throw StateError(
                'Cannot safely recover non-standard image name '
                '"${image.imageName}"',
              );
            }
            final boxId = boxByFolder[image.folderId];
            if (boxId == null) {
              throw StateError(
                'Snapshot image ${image.id} has no folder ${image.folderId}',
              );
            }
            await txn.insert('capture_images', {
              'id': image.id,
              'image_name': localName,
              'transferred_name': localName == image.imageName
                  ? null
                  : image.imageName,
              'device_id': deviceId,
              'folder_id': image.folderId,
              'box_id': boxId,
              'file_format': image.fileFormat.toLowerCase(),
              'image_created_at':
                  image.imageCreatedAt ?? DateTime.now().toIso8601String(),
              'image_updated_at': image.imageUpdatedAt,
            });
          }
        }),
      );

      if (requireNonEmpty && counts.isEmpty) {
        throw StateError(
          'PostgreSQL returned no capture history; refusing to replace the '
          'existing database.',
        );
      }
      final localCounts = await _captureCounts(recovering);
      if (localCounts.boxes != counts.boxes ||
          localCounts.folders != counts.folders ||
          localCounts.images != counts.images) {
        throw StateError(
          'Recovery row-count mismatch: PostgreSQL '
          '${counts.boxes}/${counts.folders}/${counts.images}, SQLite '
          '${localCounts.boxes}/${localCounts.folders}/${localCounts.images}.',
        );
      }
      final broken = await recovering.rawQuery('''
        SELECT
          (SELECT COUNT(*) FROM capture_folders f
             LEFT JOIN capture_boxes b ON b.id = f.box_id
             WHERE b.id IS NULL) AS folders_without_box,
          (SELECT COUNT(*) FROM capture_images i
             LEFT JOIN capture_folders f ON f.id = i.folder_id
             WHERE f.id IS NULL OR i.box_id != f.box_id) AS invalid_images
      ''');
      if ((broken.first['folders_without_box'] as num).toInt() != 0 ||
          (broken.first['invalid_images'] as num).toInt() != 0) {
        throw StateError('Recovered capture relationships are inconsistent.');
      }
      final integrity = await recovering.rawQuery('PRAGMA integrity_check');
      if (integrity.isEmpty || integrity.first.values.first != 'ok') {
        throw StateError('Recovered SQLite database failed integrity_check.');
      }

      final oldDbMissing = !File(path).existsSync();
      await _carryOverLocalOnlyTables(recovering, path);
      if (oldDbMissing && counts.images > 0) {
        await recovering.insert(
          'color_integrity',
          {
            'id': 1,
            'reason':
                'Original local database file was missing during recovery; '
                'colour bindings are unknown',
          },
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      await recovering.rawQuery('PRAGMA wal_checkpoint(TRUNCATE)');
      await recovering.close();
      recovering = null;

      // Everything from here to the final rename is the danger window: the
      // live path is about to stop existing, and this runs on the same isolate
      // as the sync (30s) timer, which reopens every device DB. Hold the door
      // shut for the whole promotion.
      _recoveringDeviceIds.add(deviceId);
      try {
        final opening = _openingDeviceDbs.remove(deviceId);
        if (opening != null) {
          try {
            await (await opening).close();
          } catch (_) {}
        }
        final open = _deviceDbs.remove(deviceId);
        if (open != null) {
          try {
            await open.close();
          } catch (_) {}
        }

        final stamp = DateTime.now().microsecondsSinceEpoch.toString();
        final moved = <(File, File)>[];
        try {
          for (final suffix in ['', '-wal', '-shm', '-journal']) {
            final original = File('$path$suffix');
            if (!original.existsSync()) continue;
            final backup = File('$path.corrupt-$stamp$suffix');
            await original.rename(backup.path);
            moved.add((original, backup));
          }
          await File(recoveringPath).rename(path);
        } catch (_) {
          for (final pair in moved.reversed) {
            if (!pair.$2.existsSync()) continue;
            // Anything sitting at the original path now is an interloper — a
            // fresh empty DB minted by a reopen that slipped through. Clear it
            // and restore for real; skipping (the old behaviour) left the live
            // path holding an EMPTY database while the caller reported
            // "No local data was replaced."
            if (pair.$1.existsSync()) {
              try {
                await pair.$1.delete();
              } catch (_) {
                continue; // can't clear it — don't lose the backup too
              }
            }
            await pair.$2.rename(pair.$1.path);
          }
          rethrow;
        }
      } finally {
        _recoveringDeviceIds.remove(deviceId);
      }
      return counts;
    } catch (_) {
      if (recovering != null) {
        try {
          await recovering.close();
        } catch (_) {}
      }
      rethrow;
    }
  }

  Future<CaptureSnapshotCounts> _captureCounts(Database db) async {
    Future<int> count(String table) async {
      final rows = await db.rawQuery('SELECT COUNT(*) AS c FROM $table');
      return (rows.first['c'] as num).toInt();
    }

    return CaptureSnapshotCounts(
      boxes: await count('capture_boxes'),
      folders: await count('capture_folders'),
      images: await count('capture_images'),
    );
  }

  /// Test-only seam: redirects the DB base folder away from the real
  /// `%USERPROFILE%\LWCAM_DBs` and drops any cached database
  /// handles, so tests never touch the real user's data. Not called from
  /// any production code path.
  void debugOverrideBaseFolderForTests(String path) {
    _baseFolder = path;
    _deviceDbs.clear();
    _monthlyDbs.clear();
  }

  /// Test-only seam: closes any open device/monthly DB handles so a
  /// test's temp directory can be deleted afterward without a file-in-use
  /// error.
  Future<void> debugCloseAllForTests() async {
    for (final db in [..._deviceDbs.values, ..._monthlyDbs.values]) {
      try {
        await db.close();
      } catch (_) {}
    }
    _deviceDbs.clear();
    _monthlyDbs.clear();
  }

  /// The STABLE per-device DB — long-lived operational state only as of the
  /// monthly-rotation change: capture_boxes/folders/images, replacement_records,
  /// sync_outbox, plus whatever upload_records/daily_summary rows predate
  /// rotation (kept as a frozen legacy read archive — see getMonthlyDbFilePath
  /// for where NEW rows of those two tables go).
  Future<String> getDeviceDbFilePath(String deviceId) async {
    final base = await _ensurePathExists();
    return p.join(base, 'lwcam_stats_$deviceId.db');
  }

  /// `YYYY-MM` for [d] — the monthly device DB file this date's
  /// upload_records/daily_summary rows belong in.
  String monthKeyFor(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  /// The per-device, per-month DB holding upload_records + daily_summary
  /// (+ its own sync_outbox — see MONTHLY ROTATION below) for [monthKey].
  /// Shares the `lwcam_stats_` prefix with the stable DB so the existing
  /// directory scan (`_listMonthlyDbFilesForDevice`) picks it up with zero
  /// changes.
  Future<String> getMonthlyDbFilePath(String deviceId, String monthKey) async {
    final base = await _ensurePathExists();
    return p.join(base, 'lwcam_stats_${deviceId}_$monthKey.db');
  }

  Future<void> _ensureDbParentExists(String path) async {
    final file = File(path);
    final parent = file.parent;

    if (!parent.existsSync()) {
      await parent.create(recursive: true);
    }
  }

  Future<bool> _isDatabaseUsable(Database db) async {
    try {
      await db.rawQuery('SELECT 1');
      return true;
    } catch (_) {
      return false;
    }
  }

  // =======================================================
  // INITIALIZATION
  // =======================================================

  Future<Database> _initDB(String deviceId) async {
    final dbPath = await _ensurePathExists();
    final dbName = 'lwcam_stats_$deviceId.db';
    final path = p.join(dbPath, dbName);
    return _openStableDatabase(path, deviceId);
  }

  Future<Database> _openStableDatabase(String path, String deviceId) async {
    await _ensureDbParentExists(path);

    final dbFile = File(path);
    if (dbFile.existsSync() && dbFile.lengthSync() == 0) {
      try {
        dbFile.deleteSync();
      } catch (_) {}
    }

    print("📂 Using per-device database: $path");

    try {
      final db = await openDatabase(
        path,
        version: _stableSchemaVersion,
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE IF NOT EXISTS upload_records (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              scanning_opr TEXT,
              device_id TEXT,
              box_details TEXT,
              filename TEXT,
              format TEXT,
              created_at TEXT,
              cover_tag TEXT,
              image_tags TEXT,
              title TEXT,
              volume TEXT,
              start_date TEXT,
              end_date TEXT,
              archival_ref_no TEXT,
              record_type TEXT,
              place TEXT,
              language TEXT,
              record_custodian TEXT,
              digitizing_entity TEXT,
              capture_operator_id TEXT,
              capture_operator_name TEXT
            )
          ''');

          await db.execute('''
            CREATE TABLE IF NOT EXISTS daily_summary (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              scanning_opr TEXT,
              device_id TEXT,
              date TEXT,
              total_count INTEGER
            )
          ''');

          await db.execute('''
            CREATE TABLE IF NOT EXISTS replacement_records (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              device_id TEXT NOT NULL,
              scanning_opr TEXT,
              box_details TEXT,
              sequence_index INTEGER NOT NULL,
              date_key TEXT,
              original_filename TEXT NOT NULL,
              replacement_filename TEXT NOT NULL,
              replacement_local_path TEXT,
              replacement_type TEXT NOT NULL,
              confirmed_at TEXT NOT NULL,
              transferred_at TEXT,
              superseded_at TEXT,
              created_at TEXT NOT NULL
            )
          ''');

          await _createCaptureBoxTablesIfNotExists(db);

          await db.execute('''
            CREATE TABLE IF NOT EXISTS sync_outbox (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              entity TEXT NOT NULL,
              entity_key TEXT NOT NULL,
              op TEXT NOT NULL,
              payload TEXT,
              created_at TEXT NOT NULL,
              updated_at TEXT NOT NULL,
              attempts INTEGER NOT NULL DEFAULT 0,
              last_error TEXT,
              next_attempt_at TEXT,
              held INTEGER NOT NULL DEFAULT 0
            )
          ''');
          await db.execute(
            'CREATE UNIQUE INDEX IF NOT EXISTS idx_outbox_entity_key ON sync_outbox(entity, entity_key)',
          );

          // Historical: this app used to dedupe its own report of each LWIP
          // completion here — one row per (LWIP input folder, fingerprint).
          // LWIP now reports finished folders straight to PostgreSQL itself,
          // so nothing writes this table anymore. Kept only so a fresh DB's
          // schema still matches an existing station's.
          await db.execute('''
            CREATE TABLE IF NOT EXISTS processing_ledger (
              input_path TEXT NOT NULL,
              fingerprint TEXT NOT NULL,
              reported_at TEXT NOT NULL,
              PRIMARY KEY (input_path, fingerprint)
            )
          ''');

          await _createColorCalibrationTables(db);
          await _ensureDeviceIndexes(db);
        },
        onUpgrade: (db, oldVersion, newVersion) async {
          if (oldVersion < 2) {
            await _migrateStableSchemaV2(db, deviceId);
          }
          if (oldVersion < 3) await _createColorCalibrationTables(db);
        },
        onOpen: (db) async {
          await _configureDatabaseForConcurrentAccess(db);
          await _ensureStableSchemaV2(db);
        },
      );

      print("✅ Database opened successfully at: $path");
      return db;
    } catch (e) {
      print("❌ Failed to open database at $path: $e");
      rethrow;
    }
  }

  // --- Schema helpers and legacy migrations --------------------------------

  Future<bool> _tableExists(DatabaseExecutor db, String table) async {
    final rows = await db.rawQuery(
      "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
      [table],
    );
    return rows.isNotEmpty;
  }

  Future<Set<String>> _columns(DatabaseExecutor db, String table) async {
    if (!await _tableExists(db, table)) return <String>{};
    final rows = await db.rawQuery('PRAGMA table_info($table)');
    return {for (final row in rows) row['name'] as String};
  }

  Future<void> _addColumnIfMissing(
    DatabaseExecutor db,
    String table,
    String column,
    String definition,
  ) async {
    final columns = await _columns(db, table);
    if (!columns.contains(column)) {
      await db.execute('ALTER TABLE $table ADD COLUMN $column $definition');
    }
  }

  /// Brings databases created by the pre-Box→Folders schema and databases
  /// created by the current v1 build to one shape. The old schema used
  /// capture_boxes.box_details + capture_folder_images; current code uses
  /// capture_boxes.box_name + capture_images.
  Future<void> _migrateStableSchemaV2(Database db, String deviceId) async {
    await _ensureStableOutboxSchema(db);
    await db.transaction((txn) async {
      final boxColumns = await _columns(txn, 'capture_boxes');
      final legacyBoxes =
          boxColumns.contains('box_details') &&
          !boxColumns.contains('box_name');
      final legacyCaptureOutbox = legacyBoxes
          ? await txn.query(
              'sync_outbox',
              where:
                  "entity IN ('capture_boxes', 'capture_folders', 'capture_images')",
              orderBy: 'id ASC',
            )
          : const <Map<String, Object?>>[];
      if (legacyBoxes) {
        await txn.execute(
          'ALTER TABLE capture_boxes RENAME TO capture_boxes_legacy_v1',
        );
        if (await _tableExists(txn, 'capture_folders')) {
          await txn.execute(
            'ALTER TABLE capture_folders RENAME TO capture_folders_legacy_v1',
          );
        }
        if (await _tableExists(txn, 'capture_folder_images')) {
          await txn.execute(
            'ALTER TABLE capture_folder_images RENAME TO capture_folder_images_legacy_v1',
          );
        }
      }

      await _createCaptureBoxTablesIfNotExists(txn);
      await _addColumnIfMissing(
        txn,
        'capture_images',
        'transferred_name',
        'TEXT',
      );

      if (legacyBoxes) {
        final lastActive = boxColumns.contains('last_active_folder_id')
            ? 'last_active_folder_id'
            : 'NULL';
        final template = boxColumns.contains('template_json')
            ? 'template_json'
            : 'NULL';
        await txn.rawInsert('''
          INSERT INTO capture_boxes
            (id, box_name, device_id, status, user_id, created_at, updated_at,
             transfer_end_at, project_key, last_active_folder_id, template_json,
             last_transfer_state, last_transfer_error)
          SELECT id, box_details, device_id,
                 CASE WHEN lower(status) = 'transferred' THEN 'TRANSFERRED' ELSE 'OPEN' END,
                 scanning_opr, created_at, created_at,
                 transferred_at, project_key, $lastActive, $template,
                 last_transfer_state, last_transfer_error
          FROM capture_boxes_legacy_v1
        ''');
        await txn.rawInsert('''
          INSERT INTO capture_folders
            (id, box_id, folder_seq, cover_tag, image_tags, title, volume,
             start_date, end_date, archival_ref_no, record_type, is_complete,
             folder_name, source_created_at, source_updated_at)
          SELECT id, box_id, folder_seq, cover_tag, image_tags, title, volume,
                 start_date, end_date, archival_ref_no, record_type, is_complete,
                 folder_name, created_at, COALESCE(updated_at, created_at)
          FROM capture_folders_legacy_v1
        ''');
        await txn.rawInsert(
          '''
          INSERT INTO capture_images
            (id, image_name, device_id, folder_id, file_format,
             image_created_at, box_id)
          SELECT id, device_filename, ?, folder_id, 'jpg', assigned_at, box_id
          FROM capture_folder_images_legacy_v1
        ''',
          [deviceId],
        );

        await txn.delete(
          'sync_outbox',
          where:
              "entity IN ('capture_boxes', 'capture_folders', 'capture_images')",
        );
        await _migrateLegacyCaptureOutbox(txn, legacyCaptureOutbox);

        await txn.execute('DROP TABLE capture_folder_images_legacy_v1');
        await txn.execute('DROP TABLE capture_folders_legacy_v1');
        await txn.execute('DROP TABLE capture_boxes_legacy_v1');
      }

      await _ensureDeviceIndexes(txn);
    });
  }

  Future<void> _migrateLegacyCaptureOutbox(
    DatabaseExecutor txn,
    List<Map<String, Object?>> rows,
  ) async {
    if (rows.isEmpty) return;
    await txn.execute('''
      CREATE TABLE IF NOT EXISTS legacy_outbox_quarantine (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity TEXT NOT NULL,
        entity_key TEXT NOT NULL,
        op TEXT NOT NULL,
        payload TEXT,
        quarantined_at TEXT NOT NULL,
        reason TEXT NOT NULL
      )
    ''');

    Future<void> quarantine(Map<String, Object?> row, String reason) =>
        txn.insert('legacy_outbox_quarantine', {
          'entity': row['entity'],
          'entity_key': row['entity_key'],
          'op': row['op'],
          'payload': row['payload'],
          'quarantined_at': DateTime.now().toIso8601String(),
          'reason': reason,
        });

    for (final legacy in rows) {
      if (legacy['op'] != 'upsert') {
        await quarantine(
          legacy,
          'legacy delete has no natural-key payload; manual review required',
        );
        continue;
      }
      try {
        final decoded = jsonDecode(legacy['payload'] as String) as Map;
        final id = (decoded['id'] as num).toInt();
        final entity = legacy['entity'] as String;
        Map<String, dynamic>? payload;
        String? entityKey;

        if (entity == 'capture_boxes') {
          payload = await _snapshotRow(txn, 'capture_boxes', id);
          entityKey = '$id';
        } else if (entity == 'capture_folders') {
          payload = await _snapshotRow(txn, 'capture_folders', id);
          if (payload != null) {
            payload.addAll(await _parentBoxKeys(txn, payload['box_id']));
            entityKey = '$id';
          }
        } else if (entity == 'capture_images') {
          payload = await _snapshotRow(txn, 'capture_images', id);
          if (payload != null) {
            final folderId = (payload['folder_id'] as num).toInt();
            final folderRows = await txn.query(
              'capture_folders',
              columns: ['box_id', 'folder_seq'],
              where: 'id = ?',
              whereArgs: [folderId],
              limit: 1,
            );
            if (folderRows.isNotEmpty) {
              payload['folder_seq'] = folderRows.first['folder_seq'];
              payload.addAll(
                await _parentBoxKeys(txn, folderRows.first['box_id']),
              );
            }
            payload.remove('transferred_name');
            payload.remove('box_id');
            entityKey = '$folderId|${payload['image_name']}';
          }
        }

        if (payload == null || entityKey == null) {
          await quarantine(legacy, 'legacy upsert no longer has a local row');
          continue;
        }
        await txn.insert('sync_outbox', {
          'entity': entity,
          'entity_key': entityKey,
          'op': 'upsert',
          'payload': jsonEncode(payload),
          'created_at': legacy['created_at'],
          'updated_at': legacy['updated_at'],
          'attempts': legacy['attempts'] ?? 0,
          'last_error': legacy['last_error'],
          'next_attempt_at': legacy['next_attempt_at'],
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      } catch (_) {
        await quarantine(legacy, 'legacy upsert payload is not convertible');
      }
    }
  }

  Future<void> _ensureStableSchemaV2(Database db) async {
    await _createCaptureBoxTablesIfNotExists(db);
    const processingColumns = {
      'is_deskewed': 'INTEGER NOT NULL DEFAULT 0',
      'is_cropped': 'INTEGER NOT NULL DEFAULT 0',
      'is_created_thumbnail': 'INTEGER NOT NULL DEFAULT 0',
      'folder_path': 'TEXT',
      'thumbnail_path': 'TEXT',
      'qc_status': "TEXT NOT NULL DEFAULT 'PENDING'",
      'is_complete': 'INTEGER NOT NULL DEFAULT 0',
    };
    for (final column in processingColumns.entries) {
      await _addColumnIfMissing(
        db,
        'capture_folders',
        column.key,
        column.value,
      );
    }
    await _addColumnIfMissing(db, 'capture_images', 'transferred_name', 'TEXT');
    await _ensureStableOutboxSchema(db);
    await db.execute('''
      CREATE TABLE IF NOT EXISTS processing_ledger (
        input_path TEXT NOT NULL,
        fingerprint TEXT NOT NULL,
        reported_at TEXT NOT NULL,
        PRIMARY KEY (input_path, fingerprint)
      )
    ''');
    await _ensureDeviceIndexes(db);
  }

  Future<void> _ensureStableOutboxSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS sync_outbox (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        entity TEXT NOT NULL,
        entity_key TEXT NOT NULL,
        op TEXT NOT NULL,
        payload TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        attempts INTEGER NOT NULL DEFAULT 0,
        last_error TEXT,
        next_attempt_at TEXT,
        held INTEGER NOT NULL DEFAULT 0
      )
    ''');
    // held = 1: past the retry cap. Kept, never deleted; the drain skips it
    // until the operator presses "Try again" (SyncService.retryHeld).
    await _addColumnIfMissing(
      db,
      'sync_outbox',
      'held',
      'INTEGER NOT NULL DEFAULT 0',
    );
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_outbox_entity_key ON sync_outbox(entity, entity_key)',
    );
    // One row per one-off job this file has finished (the cloud catch-up,
    // [queueCaptureRowsMissingFromCloud]). Deliberately not carried over by a
    // rebuild: a rebuilt file just runs its jobs again, harmlessly.
    await db.execute(
      'CREATE TABLE IF NOT EXISTS sync_meta (key TEXT PRIMARY KEY, value TEXT)',
    );
  }

  /// Returns a cached handle when one is open and healthy, else opens it.
  /// Concurrent calls for the same [key] share one open (see
  /// [_openingDeviceDbs]); calls for DIFFERENT keys never disturb each other's
  /// entry, which is the whole point — see [_deviceDbs].
  Future<Database> _cachedOpen(
    Map<String, Database> cache,
    Map<String, Future<Database>> inFlight,
    String key,
    Future<Database> Function() open,
  ) async {
    if (_recoveringDeviceIds.contains(key)) {
      // Mid-promotion the live file has been renamed away. Opening the path
      // now would have SQLite mint a NEW empty database there, which then
      // blocks the real rename and defeats the rollback. Callers are timers
      // (the sync tick) that already tolerate a throw.
      throw StateError(
        'Database for "$key" is being recovered — try again shortly.',
      );
    }
    final cached = cache[key];
    if (cached != null) {
      if (await _isDatabaseUsable(cached)) return cached;
      // Another caller may have replaced the dead entry while the health check
      // was awaiting; only evict the instance actually found unusable.
      if (cache[key] == cached) {
        cache.remove(key);
        try {
          await cached.close();
        } catch (_) {}
      }
    }
    final pending = inFlight[key];
    if (pending != null) return pending;
    final future = open().then((db) {
      cache[key] = db;
      return db;
    });
    inFlight[key] = future;
    try {
      return await future;
    } finally {
      inFlight.remove(key);
    }
  }

  Future<Database> getDatabase(String deviceId) => _cachedOpen(
    _deviceDbs,
    _openingDeviceDbs,
    deviceId,
    () => _initDB(deviceId),
  );

  // =======================================================
  // MONTHLY ROTATION (upload_records / daily_summary only)
  // =======================================================
  //
  // Only the two high-volume, ever-growing tables rotate into a new file
  // each month — everything else (boxes/folders/images, replacement_records,
  // sync_outbox for those entities) stays in the ONE stable per-device DB
  // forever, since that's long-lived operational state that
  // can't be cut off at a month boundary (an open box, a pending sync row).
  // A record's month is its `created_at` MONTH, never wall-clock write time
  // — this guarantees a calendar day's rows always live in exactly one file,
  // which is what keeps _updateDailySummary's per-day recount exact.

  /// Opens (creating if needed) the monthly DB for [deviceId] — [forDate]'s
  /// month, or the current month if omitted. Cached per (deviceId, month);
  /// a session spanning a month rollover simply misses the cache on its next
  /// write and opens/creates the new file — no explicit rollover handling
  /// needed.
  Future<Database> getMonthlyDatabase(String deviceId, {DateTime? forDate}) {
    return _getMonthlyDatabaseForMonthKey(
      deviceId,
      monthKeyFor(forDate ?? DateTime.now()),
    );
  }

  Future<Database> _getMonthlyDatabaseForMonthKey(
    String deviceId,
    String monthKey,
  ) => _cachedOpen(
    _monthlyDbs,
    _openingMonthlyDbs,
    '$deviceId|$monthKey',
    () => _initMonthlyDB(deviceId, monthKey),
  );

  Future<Database> _initMonthlyDB(String deviceId, String monthKey) async {
    final path = await getMonthlyDbFilePath(deviceId, monthKey);
    await _ensureDbParentExists(path);

    final dbFile = File(path);
    if (dbFile.existsSync() && dbFile.lengthSync() == 0) {
      try {
        dbFile.deleteSync();
      } catch (_) {}
    }

    print("📂 Using monthly device database: $path");

    try {
      final db = await openDatabase(
        path,
        // Own schema line, independent of the stable DB's version — the
        // filename (not this number) is what disambiguates the two DB
        // families, so a fresh monthly file always starts at v1.
        version: 1,
        onCreate: (db, version) async {
          await _ensureMonthlyDbSchema(db);
        },
        onOpen: (db) async {
          await _configureDatabaseForConcurrentAccess(db);
          await _ensureMonthlyDbSchema(db);
        },
      );
      print("✅ Monthly database opened successfully at: $path");
      return db;
    } catch (e) {
      print("❌ Failed to open monthly database at $path: $e");
      rethrow;
    }
  }

  /// Lean schema: just the two high-volume local-only tables and the indexes
  /// every hot query here needs. No sync_outbox — upload_records stopped
  /// syncing when the cloud schema replaced it with capture_images, so the
  /// stable DB holds the only outbox.
  Future<void> _ensureMonthlyDbSchema(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS upload_records (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        scanning_opr TEXT,
        device_id TEXT,
        box_details TEXT,
        filename TEXT,
        format TEXT,
        created_at TEXT,
        cover_tag TEXT,
        image_tags TEXT,
        title TEXT,
        volume TEXT,
        start_date TEXT,
        end_date TEXT,
        archival_ref_no TEXT,
        record_type TEXT,
        place TEXT,
        language TEXT,
        record_custodian TEXT,
        digitizing_entity TEXT,
        capture_operator_id TEXT,
        capture_operator_name TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS daily_summary (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        scanning_opr TEXT,
        device_id TEXT,
        date TEXT,
        total_count INTEGER
      )
    ''');

    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_ur_device_filename ON upload_records(device_id, filename)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_ur_opr_created ON upload_records(device_id, scanning_opr, created_at)',
    );
    // UNIQUE here (unlike the stable DB's copy of this index): a monthly
    // file never has pre-existing legacy duplicates to worry about.
    await db.execute(
      'CREATE UNIQUE INDEX IF NOT EXISTS idx_ds_device_opr_date ON daily_summary(device_id, scanning_opr, date)',
    );
  }

  /// The monthKey encoded in a monthly DB filename for [deviceId], or null if
  /// [path] doesn't match that pattern (e.g. it's the stable DB, an unrelated
  /// file, or — critically — a WAL-mode `.db-wal`/`.db-shm` sidecar:
  /// `p.basenameWithoutExtension` only strips the text after the LAST dot,
  /// so "..._2026-01.db-wal" would otherwise still resolve to the same
  /// basename as "..._2026-01.db" and get double/triple-counted as the same
  /// month via a different File entry. Requiring the filename to literally
  /// end in ".db" rules those out.
  String? _monthKeyFromMonthlyFilename(String path, String deviceId) {
    final fullName = p.basename(path);
    if (!fullName.toLowerCase().endsWith('.db')) return null;
    final nameNoExt = fullName.substring(0, fullName.length - '.db'.length);
    final prefix = 'lwcam_stats_${deviceId}_';
    if (!nameNoExt.startsWith(prefix)) return null;
    final rest = nameNoExt.substring(prefix.length);
    return RegExp(r'^\d{4}-\d{2}$').hasMatch(rest) ? rest : null;
  }

  /// Every monthly DB file already on disk for [deviceId] (never creates
  /// one) — used by the spanning readers below and by SyncService to find
  /// outbox sources without ever manufacturing a new empty month.
  List<File> _listMonthlyDbFilesForDevice(
    String directoryPath,
    String deviceId,
  ) {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return const <File>[];
    final files = dir
        .listSync(recursive: false, followLinks: false)
        .whereType<File>()
        .where((f) => _monthKeyFromMonthlyFilename(f.path, deviceId) != null)
        .toList();
    files.sort(
      (a, b) => p
          .basename(a.path)
          .toLowerCase()
          .compareTo(p.basename(b.path).toLowerCase()),
    );
    return files;
  }

  /// Every DB connection that may hold upload_records/daily_summary rows for
  /// [deviceId]: the stable DB (legacy, frozen rows) plus every monthly file
  /// that already exists on disk — spanning reads (skip-logic, stats) must
  /// see all of them; hot per-insert writes do not (see
  /// insertUploadRecord's targeted dedup lookback instead).
  Future<List<Database>> _allDeviceUploadDatabases(String deviceId) async {
    final stable = await getDatabase(deviceId);
    final base = await _ensurePathExists();
    final monthlyFiles = _listMonthlyDbFilesForDevice(base, deviceId);
    final result = <Database>[stable];
    for (final file in monthlyFiles) {
      final monthKey = _monthKeyFromMonthlyFilename(file.path, deviceId);
      if (monthKey == null) continue;
      try {
        result.add(await _getMonthlyDatabaseForMonthKey(deviceId, monthKey));
      } catch (e) {
        print('⚠️ Failed to open monthly DB ${file.path}: $e');
      }
    }
    return result;
  }

  /// Every device id with a STABLE DB file on disk. Monthly rotation files
  /// (`lwcam_stats_<dev>_YYYY-MM.db`) are excluded — they carry no outbox.
  List<String> _listDeviceIdsOnDisk(String directoryPath) {
    final dir = Directory(directoryPath);
    if (!dir.existsSync()) return const <String>[];
    final ids = <String>[];
    for (final file
        in dir
            .listSync(recursive: false, followLinks: false)
            .whereType<File>()) {
      final name = p.basename(file.path);
      if (!name.startsWith('lwcam_stats_') || !name.endsWith('.db')) continue;
      final id = name.substring(
        'lwcam_stats_'.length,
        name.length - '.db'.length,
      );
      // A trailing _YYYY-MM marks a monthly rotation file, not a device.
      if (id.isEmpty || RegExp(r'_\d{4}-\d{2}$').hasMatch(id)) continue;
      ids.add(id);
    }
    ids.sort();
    return ids;
  }

  /// Public for `SyncService`: every DB that may hold pending `sync_outbox`
  /// rows — [deviceId]'s stable DB FIRST (its rows are the ones actively being
  /// written), then every OTHER device's stable DB on this PC. Since
  /// upload_records left the sync pipeline, only stable DBs carry an outbox
  /// (boxes/folders/images all live there).
  ///
  /// Draining only the bound device stranded every other operator's rows on a
  /// shared PC: a device pushed only while its own account was logged in, so
  /// capturing and transferring on SAX01 and then switching to SAX04 left
  /// SAX01's transfer-completion rows unsent indefinitely — the cloud kept a
  /// fully transferred box at status 'OPEN' with empty folder_names and
  /// pre-rename image names until SAX01 happened to log back in (observed live
  /// 2026-07-31).
  ///
  /// Safe because outbox payloads carry NATURAL keys (project_key, box_name,
  /// folder_seq, image_name, device_id) and never the bound device id, so any
  /// device's rows resolve to the right cloud rows from any tick. This also
  /// picks up a `PROCESSING` device DB left on disk from before LWIP moved to
  /// its own PC and started reporting to PostgreSQL directly — any row queued
  /// under that pseudo id before the switch still gets drained.
  Future<List<Database>> getOutboxDatabases(String deviceId) async {
    final sources = <Database>[await getDatabase(deviceId)];
    final base = await _ensurePathExists();
    for (final other in _listDeviceIdsOnDisk(base)) {
      if (other == deviceId) continue;
      try {
        sources.add(await getDatabase(other));
      } catch (e) {
        print('⚠️ Failed to open outbox DB for device $other: $e');
      }
    }
    return sources;
  }

  Future<void> _configureDatabaseForConcurrentAccess(Database db) async {
    try {
      await db.execute('PRAGMA journal_mode=WAL');
    } catch (e) {
      print('⚠️ Failed to enable WAL mode: $e');
    }

    try {
      await db.execute('PRAGMA synchronous=NORMAL');
    } catch (_) {}

    try {
      await db.execute('PRAGMA busy_timeout = 60000');
    } catch (_) {}
  }

  Future<void> checkpointDatabases(String deviceId) async {
    final deviceDbPath = await getDeviceDbFilePath(deviceId);
    if (File(deviceDbPath).existsSync()) {
      try {
        final deviceDb = await getDatabase(deviceId);
        await deviceDb.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      } catch (e) {
        print('⚠️ Device DB checkpoint failed for $deviceId: $e');
      }
    }

    // Checkpoint every currently-cached monthly DB for this device, then
    // evict (close) any that aren't the current month — keeps the cache from
    // holding handles open forever across a long-running session that spans
    // several months.
    final currentMonthKey = monthKeyFor(DateTime.now());
    final devicePrefix = '$deviceId|';
    final staleKeys = <String>[];
    for (final entry in _monthlyDbs.entries) {
      if (!entry.key.startsWith(devicePrefix)) continue;
      try {
        await entry.value.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      } catch (e) {
        print('⚠️ Monthly DB checkpoint failed for ${entry.key}: $e');
      }
      if (entry.key.substring(devicePrefix.length) != currentMonthKey) {
        staleKeys.add(entry.key);
      }
    }
    for (final key in staleKeys) {
      final db = _monthlyDbs.remove(key);
      try {
        await db?.close();
      } catch (_) {}
    }
  }

  // --- Transfer protection: lock file + WAL while a box transfer runs ------

  Future<TransferProtectionHandle> acquireTransferProtection({
    required String deviceId,
    required String scanningOpr,
  }) async {
    final localBaseFolder = await getBaseFolder();
    final localLockFile = File(
      p.join(localBaseFolder, 'lwcam_transfer_in_progress.lock'),
    );

    RandomAccessFile? localLockRaf;

    final metadata = _buildTransferLockMetadata(
      deviceId: deviceId,
      scanningOpr: scanningOpr,
    );

    try {
      localLockRaf = await _openLockedFile(localLockFile, metadata);

      final deviceDbPath = await getDeviceDbFilePath(deviceId);
      if (File(deviceDbPath).existsSync()) {
        try {
          await _configureDatabaseForConcurrentAccess(
            await getDatabase(deviceId),
          );
        } catch (e) {
          print(
            '⚠️ Skipping device DB protection configuration for $deviceId: $e',
          );
        }
      }

      // Always (not gated on existsSync) — a transfer starting in a brand
      // new month must open/create that month's file and WAL-configure it
      // from the very first write.
      try {
        await _configureDatabaseForConcurrentAccess(
          await getMonthlyDatabase(deviceId),
        );
      } catch (e) {
        print(
          '⚠️ Skipping monthly device DB protection configuration for $deviceId: $e',
        );
      }

      return TransferProtectionHandle(
        deviceId: deviceId,
        localLockFile: localLockFile,
        localLockRaf: localLockRaf,
      );
    } catch (e) {
      if (localLockRaf != null) {
        await _safeUnlockAndClose(localLockRaf, localLockFile);
      }
      rethrow;
    }
  }

  Future<void> releaseTransferProtection(
    TransferProtectionHandle handle,
  ) async {
    try {
      await checkpointDatabases(handle.deviceId);
    } catch (e) {
      print('⚠️ Failed to checkpoint DBs while releasing protection: $e');
    }

    await _safeUnlockAndClose(handle.localLockRaf, handle.localLockFile);
  }

  String _buildTransferLockMetadata({
    required String deviceId,
    required String scanningOpr,
  }) {
    final startedAt = DateTime.now().toIso8601String();
    return [
      'TRANSFER_IN_PROGRESS=1',
      'device_id=$deviceId',
      'scanning_opr=$scanningOpr',
      'started_at=$startedAt',
      'warning=Do not open or copy database files while transfer is active.',
    ].join('\n');
  }

  Future<RandomAccessFile> _openLockedFile(File file, String metadata) async {
    if (!file.existsSync()) {
      await file.create(recursive: true);
    }

    final raf = await file.open(mode: FileMode.write);
    await raf.lock(FileLock.exclusive);
    await raf.truncate(0);
    await raf.writeString(metadata);
    await raf.flush();
    return raf;
  }

  Future<void> _safeUnlockAndClose(RandomAccessFile? raf, File? file) async {
    if (raf != null) {
      try {
        await raf.unlock();
      } catch (_) {}
      try {
        await raf.close();
      } catch (_) {}
    }

    if (file != null && file.existsSync()) {
      try {
        await file.delete();
      } catch (_) {}
    }
  }

  // =======================================================
  // INSERT / UPDATE UPLOAD RECORD
  // =======================================================

  Future<bool> _uploadRecordExistsInDb(
    Database db,
    String deviceId,
    String filename,
  ) async {
    try {
      final rows = await db.query(
        'upload_records',
        where: 'device_id = ? AND filename = ?',
        whereArgs: [deviceId, filename],
        limit: 1,
      );
      return rows.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Dedup lookback for a single insert: the target month's file (the
  /// common case), the current month's file if different (a backdated
  /// createdAt), and the stable DB's frozen legacy rows. Deliberately does
  /// NOT scan every historical monthly file — that's `getUploadedBaseNames`'s
  /// job (the real "skip already-uploaded" gate, run once per batch); a miss
  /// here costs at most one duplicate file copy, never a duplicate row.
  Future<bool> _uploadRecordExistsAnywhere(
    String deviceId,
    String filename,
    DateTime createdAt,
  ) async {
    final targetDb = await getMonthlyDatabase(deviceId, forDate: createdAt);
    if (await _uploadRecordExistsInDb(targetDb, deviceId, filename)) {
      return true;
    }

    final targetMonthKey = monthKeyFor(createdAt);
    final currentMonthKey = monthKeyFor(DateTime.now());
    if (currentMonthKey != targetMonthKey) {
      final currentDb = await getMonthlyDatabase(deviceId);
      if (await _uploadRecordExistsInDb(currentDb, deviceId, filename)) {
        return true;
      }
    }

    final stableDb = await getDatabase(deviceId);
    return _uploadRecordExistsInDb(stableDb, deviceId, filename);
  }

  /// Call this ONLY after a successful upload that should be counted.
  /// If the same device+filename already exists, this will NOT insert
  /// another record (overwrite case) and will not bump totals.
  Future<void> insertUploadRecord({
    required String deviceId,
    required String scanningOpr,
    required String boxDetails,
    required String filename,
    required String format,
    required DateTime createdAt,
    // Metadata snapshot columns (null when keying is disabled) — the values
    // that went onto this row's CSV line, kept for the record.
    String? coverTag,
    String? imageTags,
    String? title,
    String? volume,
    String? startDate,
    String? endDate,
    String? archivalRefNo,
    String? recordType,
    // Template fixed-field values (v7) — null when keying is disabled or the
    // corresponding field is disabled in the project's template.
    String? place,
    String? language,
    String? recordCustodian,
    String? digitizingEntity,
    String? captureOperatorId,
    String? captureOperatorName,
  }) async {
    // Rows are routed by their CAPTURE month (createdAt), not wall-clock
    // write time — a July-31 capture transferred on Aug 1 still lands in
    // July's file, so a calendar day's rows are never split across two DBs
    // (see MONTHLY ROTATION above; that invariant is what keeps
    // _updateDailySummary's per-day recount exact).
    final db = await getMonthlyDatabase(deviceId, forDate: createdAt);

    if (await _uploadRecordExistsAnywhere(deviceId, filename, createdAt)) {
      // This is likely an overwrite (e.g., user chose "All Images"
      // including previously uploaded ones). Don't count again.
      print(
        'ℹ️ Skipping DB insert for $filename '
        '(already recorded for device $deviceId).',
      );
      return;
    }

    final row = {
      'scanning_opr': scanningOpr,
      'device_id': deviceId,
      'box_details': boxDetails,
      'filename': filename,
      'format': format,
      'created_at': createdAt.toIso8601String(),
      'cover_tag': coverTag,
      'image_tags': imageTags,
      'title': title,
      'volume': volume,
      'start_date': startDate,
      'end_date': endDate,
      'archival_ref_no': archivalRefNo,
      'record_type': recordType,
      'place': place,
      'language': language,
      'record_custodian': recordCustodian,
      'digitizing_entity': digitizingEntity,
      'capture_operator_id': captureOperatorId,
      'capture_operator_name': captureOperatorName,
    };

    // Local record-keeping only — the cloud schema has no upload_records
    // table (capture_images, enqueued at assignment time, replaced it).
    await db.transaction((txn) async {
      await txn.insert('upload_records', row);
      // Recalculate today's count based on actual successful records.
      await _updateDailySummary(txn, deviceId, scanningOpr, createdAt);
    });

    print('🆕 Added upload record: $filename (Device: $deviceId)');
  }

  // =======================================================
  // DAILY SUMMARY UPDATE (PER DEVICE DB)
  // =======================================================

  /// Ensure daily_summary.total_count matches the number of successful
  /// uploads for this device + operator on that calendar day.
  Future<void> _updateDailySummary(
    DatabaseExecutor db,
    String deviceId,
    String scanningOpr,
    DateTime date,
  ) async {
    final todayStr =
        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
    final nextDay = DateTime(date.year, date.month, date.day + 1);
    final nextDayStr =
        '${nextDay.year}-${nextDay.month.toString().padLeft(2, '0')}-${nextDay.day.toString().padLeft(2, '0')}';

    // Count successful uploads from upload_records for this day/operator/device.
    // A half-open range (not LIKE 'date%') so idx_ur_opr_created can actually
    // be used — SQLite's LIKE optimization doesn't apply here since the
    // pattern isn't a plain prefix constant known at prepare time in every
    // driver path, and a range predicate is the reliably-indexable form.
    final countResult = await db.rawQuery(
      '''
      SELECT COUNT(*) AS total
      FROM upload_records
      WHERE device_id = ?
        AND scanning_opr = ?
        AND created_at >= ?
        AND created_at < ?
      ''',
      [deviceId, scanningOpr, todayStr, nextDayStr],
    );

    final totalForDay = (countResult.first['total'] as int?) ?? 0;

    final existing = await db.query(
      'daily_summary',
      where: 'device_id = ? AND scanning_opr = ? AND date = ?',
      whereArgs: [deviceId, scanningOpr, todayStr],
      limit: 1,
    );

    if (existing.isEmpty) {
      await db.insert('daily_summary', {
        'scanning_opr': scanningOpr,
        'device_id': deviceId,
        'date': todayStr,
        'total_count': totalForDay,
      });
    } else {
      final id = existing.first['id'];
      await db.update(
        'daily_summary',
        {'total_count': totalForDay},
        where: 'id = ?',
        whereArgs: [id],
      );
    }

    print(
      '📅 Daily summary updated for $todayStr — '
      'Device: $deviceId, Opr: $scanningOpr, Count: $totalForDay',
    );
  }

  // =======================================================
  // SUMMARY RETRIEVAL (PER DEVICE)
  // =======================================================

  /// Sums across the stable DB (legacy rows) and every monthly file — a
  /// device's daily_summary history now lives split across several files.
  Future<Map<String, int>> getTransferStats(String deviceId) async {
    final now = DateTime.now();
    final todayStr =
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';

    var totalAllTime = 0;
    var totalToday = 0;
    for (final db in await _allDeviceUploadDatabases(deviceId)) {
      try {
        final totalResult = await db.rawQuery(
          'SELECT SUM(total_count) as total FROM daily_summary',
        );
        totalAllTime += (totalResult.first['total'] as int?) ?? 0;

        final todayResult = await db.rawQuery(
          'SELECT SUM(total_count) as total FROM daily_summary WHERE date = ?',
          [todayStr],
        );
        totalToday += (todayResult.first['total'] as int?) ?? 0;
      } catch (_) {
        // Table missing in this source — nothing to add.
      }
    }

    return {'today': totalToday, 'allTime': totalAllTime};
  }

  // =======================================================
  // REPLACEMENT RECORDS
  // =======================================================

  /// replacement_records is local-operational state only (recapture overlay
  /// restoration + transfer-time verification read it back — see
  /// gallery_page.dart/box_session_controller.dart) — it is deliberately
  /// NEVER synced to the cloud PG (local-operational data only).
  Future<void> insertReplacementRecord({
    required String deviceId,
    required int sequenceIndex,
    required String dateKey,
    required String originalFilename,
    required String replacementFilename,
    required String replacementLocalPath,
    String scanningOpr = '',
    String boxDetails = '',
    String replacementType = 'recapture',
    DateTime? confirmedAt,
  }) async {
    final db = await getDatabase(deviceId);
    final now = (confirmedAt ?? DateTime.now()).toIso8601String();
    await db.insert('replacement_records', {
      'device_id': deviceId,
      'scanning_opr': scanningOpr,
      'box_details': boxDetails,
      'sequence_index': sequenceIndex,
      'date_key': dateKey,
      'original_filename': originalFilename,
      'replacement_filename': replacementFilename,
      'replacement_local_path': replacementLocalPath,
      'replacement_type': replacementType,
      'confirmed_at': now,
      'transferred_at': null,
      'created_at': now,
    });
  }

  /// Marks every still-active replacement record of [originalFilename] as
  /// superseded instead of deleting it, preserving the slot's replacement
  /// history for auditing (local only — see class-level note above).
  Future<int> markReplacementRecordsSuperseded({
    required String deviceId,
    required String originalFilename,
    DateTime? supersededAt,
  }) async {
    final db = await getDatabase(deviceId);
    return db.update(
      'replacement_records',
      {'superseded_at': (supersededAt ?? DateTime.now()).toIso8601String()},
      where:
          'device_id = ? AND original_filename = ? AND superseded_at IS NULL',
      whereArgs: [deviceId, originalFilename],
    );
  }

  /// Marks one specific (original, replacement) record as superseded.
  Future<int> markReplacementRecordSuperseded({
    required String deviceId,
    required String originalFilename,
    required String replacementFilename,
    DateTime? supersededAt,
  }) async {
    final db = await getDatabase(deviceId);
    return db.update(
      'replacement_records',
      {'superseded_at': (supersededAt ?? DateTime.now()).toIso8601String()},
      where:
          'device_id = ? AND original_filename = ? AND '
          'replacement_filename = ? AND superseded_at IS NULL',
      whereArgs: [deviceId, originalFilename, replacementFilename],
    );
  }

  /// Returns replacement records for [deviceId]. With [activeOnly] (the
  /// default) superseded records are excluded — pass false to read the full
  /// replacement history of every slot.
  Future<List<Map<String, dynamic>>> getReplacementRecords(
    String deviceId, {
    bool activeOnly = true,
  }) async {
    final db = await getDatabase(deviceId);
    return db.query(
      'replacement_records',
      where: activeOnly
          ? 'device_id = ? AND superseded_at IS NULL'
          : 'device_id = ?',
      whereArgs: [deviceId],
      orderBy: 'sequence_index ASC, id ASC',
    );
  }

  // =======================================================
  // CAPTURE BOXES / FOLDERS — Box→Folders workflow
  // =======================================================
  //
  // Per-device operational state, mirrored to Postgres only via the
  // capture_boxes/capture_folders sync outbox entries below.

  /// Local mirrors of the cloud entities in LWCam_database_unified_*.sql —
  /// same column names, full-CAPS statuses — plus local-only columns grouped
  /// at the bottom of each table (excluded from sync payload consumption by
  /// the sink). The QC-owned pipeline columns (group_id, client_qc_status,
  /// client_rework) remain absent: LWCAM never writes them and PG fills their
  /// defaults on INSERT. The image-PROCESSING columns (is_deskewed/is_cropped/
  /// is_created_thumbnail/folder_path/thumbnail_path/qc_status) are mirrored
  /// on capture_folders for schema compatibility with older station DBs, but
  /// this app no longer writes them — LWIP runs standalone now and reports a
  /// finished folder straight to PostgreSQL itself, never through this local
  /// DB or folderUpsertSql.
  Future<void> _createCaptureBoxTablesIfNotExists(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS capture_boxes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        box_name TEXT NOT NULL,
        device_id TEXT NOT NULL,
        status TEXT NOT NULL DEFAULT 'OPEN',
        user_id TEXT,
        project_id TEXT,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        transfer_start_at TEXT,
        transfer_end_at TEXT,
        transferred_to TEXT,
        -- local-only ↓
        renamed_from TEXT,
        last_active_folder_id INTEGER,
        project_key TEXT,
        template_json TEXT,
        last_transfer_state TEXT,
        last_transfer_error TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS capture_folders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        box_id INTEGER NOT NULL,
        folder_seq INTEGER NOT NULL,
        folder_name TEXT,
        cover_tag TEXT,
        image_tags TEXT,
        title TEXT,
        volume TEXT,
        start_date TEXT,
        end_date TEXT,
        archival_ref_no TEXT,
        record_type TEXT,
        place TEXT,
        language TEXT,
        record_custodian TEXT,
        capture_operator_id TEXT,
        capture_operator_name TEXT,
        digitizing_entity TEXT,
        source_created_at TEXT NOT NULL,
        source_updated_at TEXT NOT NULL,
        -- image-processing result (mirrors the cloud pipeline columns; no
        -- longer written by this app — LWIP reports these to PostgreSQL
        -- itself now, never through a folder upsert) ↓
        is_deskewed INTEGER NOT NULL DEFAULT 0,
        is_cropped INTEGER NOT NULL DEFAULT 0,
        is_created_thumbnail INTEGER NOT NULL DEFAULT 0,
        folder_path TEXT,
        thumbnail_path TEXT,
        qc_status TEXT NOT NULL DEFAULT 'PENDING',
        -- local-only ↓
        is_complete INTEGER NOT NULL DEFAULT 0,
        UNIQUE(box_id, folder_seq)
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS capture_images (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        image_name TEXT NOT NULL UNIQUE,
        device_id TEXT NOT NULL,
        folder_id INTEGER NOT NULL,
        file_format TEXT NOT NULL,
        image_created_at TEXT NOT NULL,
        image_updated_at TEXT,
        transferred_name TEXT,
        -- local-only ↓
        box_id INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_ci_folder ON capture_images(folder_id)',
    );
  }

  // =======================================================
  // SYNC (device DB) — durable outbox, natural keys on the wire
  // =======================================================
  //
  // Outbox entity_key is the LOCAL row id (boxes/folders: '<id>'; images:
  // '<folderId>|<imageName>') — it only needs to coalesce repeated edits of
  // the same local row. Cloud identity is resolved by the sink from natural
  // keys carried in the payload: users.user_id (username),
  // projects.project_key (the stable client identity — NEVER project_id,
  // which is a human-editable label LWCam Admin can rename freely),
  // devices.device_id, capture_boxes (project, box_name),
  // capture_folders (box, folder_seq), capture_images (folder, image_name)
  // — matching the UNIQUE constraints in LWCam_database_unified_*.sql.

  // =======================================================
  // INDEXES (device DB)
  // =======================================================

  /// Indexes on the columns every hot query filters/joins by (dedup on
  /// insert, per-day summary recount, per-box image counts, replacement
  /// lookups).
  /// Each index is created independently and a failure is logged, not thrown.
  /// These run inside `onOpen`/`onUpgrade`, so a throw here fails the OPEN —
  /// and a DB that won't open is reported as corrupt and offered a destructive
  /// rebuild. An older file missing a column an index names is a reason to
  /// skip that one index, never a reason to condemn the file. Indexes are a
  /// performance optimisation; every query works without them.
  Future<void> _ensureDeviceIndexes(DatabaseExecutor db) async {
    for (final statement in const [
      'CREATE INDEX IF NOT EXISTS idx_ur_device_filename ON upload_records(device_id, filename)',
      'CREATE INDEX IF NOT EXISTS idx_ur_opr_created ON upload_records(device_id, scanning_opr, created_at)',
      'CREATE INDEX IF NOT EXISTS idx_ds_device_opr_date ON daily_summary(device_id, scanning_opr, date)',
      'CREATE INDEX IF NOT EXISTS idx_rr_device_original ON replacement_records(device_id, original_filename)',
      'CREATE INDEX IF NOT EXISTS idx_ci_box ON capture_images(box_id)',
    ]) {
      try {
        await db.execute(statement);
      } catch (e) {
        print('⚠️ Skipped an index this database cannot support: $e');
      }
    }
  }

  /// Enqueues a payload-snapshot outbox row for `SyncService` to drain later.
  /// Always records, whatever NodeConfig.syncEnabled says — that switch only
  /// governs the DRAIN (SyncService.drainEnabled). A capture made with sync
  /// off is then sent once it is turned on, instead of never (until
  /// 2026-10-01 these hooks were no-ops while off, and QC never saw those
  /// folders). The outbox coalesces per row, so it stays as small as the
  /// capture data itself. `INSERT OR REPLACE` against the `UNIQUE(entity,
  /// entity_key)` index coalesces repeated edits of the same row into a
  /// single pending outbox entry carrying the latest snapshot (see
  /// the SYNC section comment above). Always called from the same transaction as the
  /// domain write it accompanies, so the two can never disagree after a
  /// crash.
  Future<void> _enqueueOutbox(
    DatabaseExecutor txn, {
    required String entity,
    required String entityKey,
    required String op,
    Map<String, dynamic>? payload,
  }) async {
    final now = DateTime.now().toIso8601String();
    await txn.insert('sync_outbox', {
      'entity': entity,
      'entity_key': entityKey,
      'op': op,
      'payload': payload == null ? null : jsonEncode(payload),
      'created_at': now,
      'updated_at': now,
      'attempts': 0,
      'last_error': null,
      'next_attempt_at': null,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  /// Re-reads a single row by local id, for building an outbox payload after
  /// a write. Returns null if the row is gone (caller's write raced a
  /// delete elsewhere in the same transaction — nothing to enqueue).
  Future<Map<String, dynamic>?> _snapshotRow(
    DatabaseExecutor txn,
    String table,
    int id,
  ) async {
    final rows = await txn.query(
      table,
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : Map<String, dynamic>.from(rows.first);
  }

  static const _cloudCatchUpKey = 'cloud_catch_up_done';

  /// One-time catch-up for [db] (a device's stable file): queues every local
  /// box, folder and image that PostgreSQL does not hold and the outbox does
  /// not already carry. Before 2026-10-01 the outbox hooks did nothing while
  /// sync was off, so a capture made then was never queued, and nothing else
  /// would ever send it — LWIP then finds no record and QC never shows it.
  ///
  /// MISSING rows only. Re-sending a row PG already has would overwrite QC's
  /// metadata edits with this PC's older copy and revive folders QC deleted.
  /// [cloudKeys] returns the [captureCloudKey]s PG holds for one device id
  /// (soft-deleted rows included). If it throws, the job stays undone and the
  /// next sync tick tries again. Returns the number of rows queued.
  Future<int> queueCaptureRowsMissingFromCloud(
    Database db,
    Future<Set<String>> Function(String deviceId) cloudKeys,
  ) async {
    final done = await db.query(
      'sync_meta',
      where: 'key = ?',
      whereArgs: [_cloudCatchUpKey],
      limit: 1,
    );
    if (done.isNotEmpty) return 0;

    final cloud = <String>{};
    for (final row in await db.rawQuery(
      'SELECT DISTINCT device_id FROM capture_boxes',
    )) {
      cloud.addAll(await cloudKeys(row['device_id'] as String));
    }

    return db.transaction((txn) async {
      final alreadyQueued = {
        for (final r in await txn.query(
          'sync_outbox',
          columns: ['entity', 'entity_key'],
        ))
          '${r['entity']}|${r['entity_key']}',
      };
      var queued = 0;

      // Local box id → its project_key, and the name PG knows it by
      // (renamed_from while a rename is still unsent) or null if PG has none.
      final projectKeyOf = <int, String?>{};
      final cloudNameOf = <int, String?>{};
      for (final box in await txn.query('capture_boxes', orderBy: 'id')) {
        final id = (box['id'] as num).toInt();
        final projectKey = box['project_key'] as String?;
        projectKeyOf[id] = projectKey;
        cloudNameOf[id] = [box['box_name'], box['renamed_from']]
            .whereType<String>()
            .where((name) => cloud.contains(captureCloudKey(projectKey, name)))
            .firstOrNull;
        if (cloudNameOf[id] == null &&
            !alreadyQueued.contains('capture_boxes|$id')) {
          await _enqueueCaptureBoxUpsert(txn, id);
          queued++;
        }
      }

      // Parents are queued before children (ascending outbox ids), which is
      // the order the drain needs.
      final folderOf = <int, ({int boxId, int seq})>{};
      for (final folder in await txn.query(
        'capture_folders',
        columns: ['id', 'box_id', 'folder_seq'],
        orderBy: 'id',
      )) {
        final id = (folder['id'] as num).toInt();
        final boxId = (folder['box_id'] as num).toInt();
        final seq = (folder['folder_seq'] as num).toInt();
        folderOf[id] = (boxId: boxId, seq: seq);
        final name = cloudNameOf[boxId];
        final inCloud =
            name != null &&
            cloud.contains(captureCloudKey(projectKeyOf[boxId], name, seq));
        if (!inCloud && !alreadyQueued.contains('capture_folders|$id')) {
          await _enqueueCaptureFolderUpsert(txn, id);
          queued++;
        }
      }

      for (final image in await txn.query('capture_images', orderBy: 'id')) {
        final folderId = (image['folder_id'] as num).toInt();
        final folder = folderOf[folderId];
        if (folder == null) continue; // orphan row — nothing to attach it to
        final deviceName = image['image_name'] as String;
        final transferred = (image['transferred_name'] as String?)?.trim();
        final finalName = transferred == null || transferred.isEmpty
            ? deviceName
            : transferred;
        final boxName = cloudNameOf[folder.boxId];
        final projectKey = projectKeyOf[folder.boxId];
        final inCloud =
            boxName != null &&
            {deviceName, finalName}.any(
              (n) => cloud.contains(
                captureCloudKey(projectKey, boxName, folder.seq, n),
              ),
            );
        if (inCloud ||
            alreadyQueued.contains('capture_images|$folderId|$deviceName')) {
          continue;
        }
        // The same payload the capture and transfer hooks would have sent.
        final row = Map<String, dynamic>.from(image)
          ..remove('id')
          ..remove('box_id');
        if (finalName != deviceName) {
          row['image_name'] = finalName;
          row['image_renamed_from'] = deviceName;
        }
        await _enqueueCaptureImageUpsert(
          txn,
          folderId,
          finalName,
          row,
          entityKeyName: deviceName,
        );
        queued++;
      }

      await txn.insert('sync_meta', {
        'key': _cloudCatchUpKey,
        'value': DateTime.now().toIso8601String(),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      return queued;
    });
  }

  // ── Boxes ────────────────────────────────────────────────────────────────

  Future<int> insertCaptureBox({
    required String deviceId,
    required String boxDetails,
    String? scanningOpr,
    String? projectKey,
    String? projectId,
    String? templateJson,
  }) async {
    final db = await getDatabase(deviceId);
    final now = DateTime.now().toIso8601String();
    final row = {
      'box_name': boxDetails.trim(),
      'device_id': deviceId,
      'status': 'OPEN',
      'user_id': scanningOpr,
      'project_id': projectId,
      'created_at': now,
      'updated_at': now,
      'project_key': projectKey,
      'template_json': templateJson,
    };
    return db.transaction((txn) async {
      final id = await txn.insert('capture_boxes', row);
      await _enqueueOutbox(
        txn,
        entity: 'capture_boxes',
        entityKey: '$id',
        op: 'upsert',
        payload: {...row, 'id': id},
      );
      return id;
    });
  }

  /// All boxes for this device: open first, newest first within status.
  /// When [projectKey] is supplied, only boxes stamped with that project are
  /// returned; null keeps the previous unfiltered behavior.
  Future<List<CaptureBox>> getCaptureBoxes(
    String deviceId, {
    String? projectKey,
  }) async {
    final db = await getDatabase(deviceId);
    final rows = await db.query(
      'capture_boxes',
      where: projectKey == null
          ? 'device_id = ?'
          : 'device_id = ? AND project_key = ?',
      whereArgs: projectKey == null ? [deviceId] : [deviceId, projectKey],
      orderBy: "CASE status WHEN 'OPEN' THEN 0 ELSE 1 END ASC, created_at DESC",
    );
    return rows.map(CaptureBox.fromDbMap).toList();
  }

  Future<CaptureBox?> getCaptureBoxById({
    required String deviceId,
    required int boxId,
  }) async {
    final db = await getDatabase(deviceId);
    final rows = await db.query(
      'capture_boxes',
      where: 'id = ?',
      whereArgs: [boxId],
      limit: 1,
    );
    return rows.isEmpty ? null : CaptureBox.fromDbMap(rows.first);
  }

  /// Renames a box's details. Only meaningful for an OPEN box — folder
  /// destination names are computed from box_details at transfer time, so a
  /// correction here fixes every folder's name without touching them.
  Future<void> updateCaptureBoxDetails({
    required String deviceId,
    required int boxId,
    required String boxDetails,
  }) async {
    final db = await getDatabase(deviceId);
    await db.transaction((txn) async {
      // The cloud row is keyed by (project_id, box_name), so a rename must
      // carry the OLD name for the sink's rename fixup. Set only-if-null: it
      // must keep pointing at the name PG last saw, not an intermediate one.
      // ponytail: a second rename in a later sync tick (after the fixup ran
      // and cleared nothing here) can orphan a cloud row — renames are
      // pre-transfer typo fixes; revisit only if that stops being true.
      await txn.rawUpdate(
        'UPDATE capture_boxes SET renamed_from = COALESCE(renamed_from, box_name), '
        'box_name = ?, updated_at = ? WHERE id = ?',
        [boxDetails.trim(), DateTime.now().toIso8601String(), boxId],
      );
      await _enqueueCaptureBoxUpsert(txn, boxId);
    });
  }

  /// Stamps the moment a background transfer for [boxId] begins (cloud
  /// `transfer_start_at`, re-stamped on every attempt) and fixes the box's
  /// destination ONCE: `transferred_to` becomes `<destinationRoot>\<YYYYMMDD>`
  /// on the first attempt and is returned unchanged by every retry, even one
  /// days later or after the station's root changed. The day dir used to be
  /// `DateTime.now()` per run, so a retry across midnight copied the rest of
  /// a folder into a second day dir: the marker writer then stamped both, LWIP
  /// ran them as two jobs with one identity, and QC opened whichever half
  /// reported last. A pre-existing value that is not a day dir (the bare
  /// root, written by older builds on success) is replaced.
  Future<String> markCaptureBoxTransferStarted({
    required String deviceId,
    required int boxId,
    required String destinationRoot,
  }) async {
    final db = await getDatabase(deviceId);
    final now = DateTime.now();
    late String destination;
    await db.transaction((txn) async {
      final rows = await txn.query(
        'capture_boxes',
        columns: ['transferred_to'],
        where: 'id = ?',
        whereArgs: [boxId],
        limit: 1,
      );
      final existing = rows.isEmpty
          ? null
          : rows.first['transferred_to'] as String?;
      destination = TransferDestinationService.isDayDirectory(existing)
          ? existing!.trim()
          : p.join(
              destinationRoot.trim(),
              TransferDestinationService.dayFolderName(now),
            );
      await txn.update(
        'capture_boxes',
        {
          'transfer_start_at': now.toIso8601String(),
          'updated_at': now.toIso8601String(),
          'transferred_to': destination,
        },
        where: 'id = ?',
        whereArgs: [boxId],
      );
      await _enqueueCaptureBoxUpsert(txn, boxId);
    });
    return destination;
  }

  Future<void> markCaptureBoxTransferred({
    required String deviceId,
    required int boxId,
    String? transferredTo,
  }) async {
    final db = await getDatabase(deviceId);
    await db.transaction((txn) async {
      await txn.update(
        'capture_boxes',
        {
          'status': 'TRANSFERRED',
          'transfer_end_at': DateTime.now().toIso8601String(),
          'updated_at': DateTime.now().toIso8601String(),
          if (transferredTo != null) 'transferred_to': transferredTo,
          // A full success clears any lingering failure/interrupted marker.
          'last_transfer_state': null,
          'last_transfer_error': null,
        },
        where: 'id = ?',
        whereArgs: [boxId],
      );
      await _enqueueCaptureBoxUpsert(txn, boxId);
    });
  }

  /// Persists a box's transfer outcome so it survives restart/re-login and
  /// the box list can show it at a glance: 'running' is written when a
  /// background transfer starts (a leftover 'running' at next login means the
  /// transfer was cut off — power loss/crash), 'partial'/'failed' on the
  /// terminal outcomes, null to clear. Local operational state only — like
  /// setBoxActiveFolder, deliberately NOT enqueued to the sync outbox (the
  /// columns never enter outbox-consumed statements — see pg_statements.dart).
  Future<void> setBoxTransferState({
    required String deviceId,
    required int boxId,
    String? state,
    String? error,
  }) async {
    final db = await getDatabase(deviceId);
    await db.update(
      'capture_boxes',
      {'last_transfer_state': state, 'last_transfer_error': error},
      where: 'id = ?',
      whereArgs: [boxId],
    );
  }

  /// Re-reads box [boxId] and enqueues its current state.
  /// Shared by every capture_boxes update hook.
  Future<void> _enqueueCaptureBoxUpsert(DatabaseExecutor txn, int boxId) async {
    final snapshot = await _snapshotRow(txn, 'capture_boxes', boxId);
    if (snapshot == null) return;
    await _enqueueOutbox(
      txn,
      entity: 'capture_boxes',
      entityKey: '$boxId',
      op: 'upsert',
      payload: snapshot,
    );
  }

  /// Persists which folder the operator is capturing into — restored as the
  /// active folder next time the box is opened (see CaptureBox.lastActiveFolderId).
  Future<void> setBoxActiveFolder({
    required String deviceId,
    required int boxId,
    required int folderId,
  }) async {
    final db = await getDatabase(deviceId);
    await db.update(
      'capture_boxes',
      {'last_active_folder_id': folderId},
      where: 'id = ?',
      whereArgs: [boxId],
    );
  }

  // ── Folders ──────────────────────────────────────────────────────────────

  /// Inserts a folder with the next folder_seq for its box (allocated inside
  /// a transaction so two rapid inserts can't collide). Returns the new id.
  /// [isComplete] is caller-supplied — resolved from the box's metadata
  /// template (see MetadataTemplate.isCompleteOf), since completeness is no
  /// longer a context-free property of the folder alone.
  Future<int> insertCaptureFolder({
    required String deviceId,
    required CaptureFolder folder,
    required bool isComplete,
    String? captureOperatorName,
  }) async {
    final db = await getDatabase(deviceId);
    return db.transaction((txn) async {
      final seqRows = await txn.rawQuery(
        'SELECT COALESCE(MAX(folder_seq), 0) + 1 AS next_seq FROM capture_folders WHERE box_id = ?',
        [folder.boxId],
      );
      final nextSeq = (seqRows.first['next_seq'] as num).toInt();
      final now = DateTime.now().toIso8601String();
      final map = folder
          .copyWith(folderSeq: nextSeq)
          .toDbMap(isComplete: isComplete);
      map['source_created_at'] = now;
      map['source_updated_at'] = now;
      map['capture_operator_id'] = deviceId;
      map['capture_operator_name'] = captureOperatorName;
      final id = await txn.insert('capture_folders', map);
      await _enqueueCaptureFolderUpsert(txn, id);
      return id;
    });
  }

  /// Updates a folder's keyed metadata (identity/seq/name untouched).
  /// [isComplete] is caller-supplied (see [insertCaptureFolder]).
  ///
  /// Pass [enqueueSync] false to update the LOCAL row only. That is for a folder
  /// QC has already reviewed: the normal path enqueues folderUpsertSql, which
  /// writes EVERY metadata column from this local row, and QC edits those same
  /// columns — so syncing a folder whose local row predates QC's corrections
  /// would silently revert them. The rework submit path therefore updates
  /// locally here and sends only the columns the operator actually changed, via
  /// [enqueueFolderRework].
  Future<void> updateCaptureFolderMetadata({
    required String deviceId,
    required CaptureFolder folder,
    required bool isComplete,
    bool enqueueSync = true,
  }) async {
    final db = await getDatabase(deviceId);
    await db.transaction((txn) async {
      await txn.update(
        'capture_folders',
        {
          'cover_tag': folder.coverTag,
          'image_tags': folder.imageTags,
          'title': folder.title,
          'volume': folder.volume,
          'start_date': folder.startDate,
          'end_date': folder.endDate,
          'archival_ref_no': folder.archivalRefNo,
          // The eighth keyed field, and it was missing here while insert
          // (which goes through toDbMap) always wrote it: editing a folder
          // silently dropped a keyed Record Type. Harmless when the template
          // maps Record Type from Title — applyValues passes the stored value
          // through untouched for a field that is not on the form, so this
          // writes back what was already there.
          'record_type': folder.recordType,
          'is_complete': isComplete ? 1 : 0,
          'source_updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [folder.id],
      );
      if (enqueueSync) await _enqueueCaptureFolderUpsert(txn, folder.id);
    });
  }

  /// Persists the transfer-time computed destination name — see
  /// [computeFolderNames]. It deliberately does NOT touch `volume`: prep used
  /// to overwrite it with an "(unknown file [n])" placeholder for a folder
  /// with no file number, which meant the stored Volume could differ from what
  /// the operator keyed. Volume is the operator's text and nothing else edits it.
  Future<void> updateCaptureFolderName({
    required String deviceId,
    required int folderId,
    required String folderName,
  }) async {
    final db = await getDatabase(deviceId);
    await db.transaction((txn) async {
      await txn.update(
        'capture_folders',
        {
          'folder_name': folderName,
          'source_updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [folderId],
      );
      await _enqueueCaptureFolderUpsert(txn, folderId);
    });
  }

  /// Persists the template's effective fixed-field values at transfer prep —
  /// the cloud capture_folders row carries them as real columns, so they
  /// must exist locally too (not just on upload_records/CSV lines).
  /// Persists the template-EFFECTIVE values that are not keyed onto the row by
  /// the metadata form: the §8.3 fixed-only columns AND any metadata column
  /// whose template field is fixed/mapped (start_date, end_date, record_type).
  ///
  /// Without this, a mapped field (e.g. Start Date mapped from Title) only
  /// ever existed in the transfer-time CSV: the folder ROW stayed NULL, the
  /// outbox snapshots the row, and the cloud capture_folders — which QC and
  /// the export read — never received the value at all.
  ///
  /// Values are written as-given, nulls included: a disabled field exports
  /// null everywhere (CSV and cloud alike), and an editable field's effective
  /// value IS the row value, so writing it back is a no-op. The editable-only
  /// columns (cover_tag, image_tags, title, volume, archival_ref_no) are
  /// deliberately not touched — the form owns those.
  Future<void> updateCaptureFolderEffectiveValues({
    required String deviceId,
    required int folderId,
    String? startDate,
    String? endDate,
    String? recordType,
    String? place,
    String? language,
    String? recordCustodian,
    String? digitizingEntity,
    String? captureOperatorId,
    String? captureOperatorName,
  }) async {
    final db = await getDatabase(deviceId);
    await db.transaction((txn) async {
      await txn.update(
        'capture_folders',
        {
          'start_date': startDate,
          'end_date': endDate,
          'record_type': recordType,
          'place': place,
          'language': language,
          'record_custodian': recordCustodian,
          'digitizing_entity': digitizingEntity,
          'capture_operator_id': captureOperatorId,
          'capture_operator_name': captureOperatorName,
          'source_updated_at': DateTime.now().toIso8601String(),
        },
        where: 'id = ?',
        whereArgs: [folderId],
      );
      await _enqueueCaptureFolderUpsert(txn, folderId);
    });
  }

  /// The parent box's cloud natural keys, joined into folder/image payloads
  /// so the sink can resolve the PG box row: project_key (FK resolution) +
  /// box_name, plus renamed_from for the rename fixup and device_id for the
  /// devices FK.
  Future<Map<String, dynamic>> _parentBoxKeys(
    DatabaseExecutor txn,
    Object? boxId,
  ) async {
    final rows = await txn.query(
      'capture_boxes',
      columns: [
        'box_name',
        'project_id',
        'project_key',
        'renamed_from',
        'device_id',
      ],
      where: 'id = ?',
      whereArgs: [boxId],
      limit: 1,
    );
    if (rows.isEmpty) return const {};
    final r = rows.first;
    return {
      'box_name': r['box_name'],
      'project_id': r['project_id'],
      'project_key': r['project_key'],
      'renamed_from': r['renamed_from'],
      'device_id': r['device_id'],
    };
  }

  /// Re-reads folder [folderId] and enqueues its current state, when sync is
  /// on. Shared by every capture_folders write hook (insert included) so the
  /// payload's parent natural keys are always freshly joined in — never
  /// sourced from a caller-local variable that a later coalesced edit could
  /// drop.
  Future<void> _enqueueCaptureFolderUpsert(
    DatabaseExecutor txn,
    int folderId,
  ) async {
    final snapshot = await _snapshotRow(txn, 'capture_folders', folderId);
    if (snapshot == null) return;
    snapshot.addAll(await _parentBoxKeys(txn, snapshot['box_id']));
    await _enqueueOutbox(
      txn,
      entity: 'capture_folders',
      entityKey: '$folderId',
      op: 'upsert',
      payload: snapshot,
    );
  }

  // --- Rework requests: closing and folder metadata fixes ------------------

  /// Queues the CLOSED row that retires a QC recapture request.
  ///
  /// Called AFTER the recaptured image has been written to LWIP's input folder —
  /// that ordering is the point: the worklist item disappears only once the
  /// replacement is genuinely in the pipeline, and it cannot reappear before QC
  /// re-reviews the reprocessed folder.
  ///
  /// Goes through the outbox rather than a direct PG write so it inherits the
  /// existing retry/backoff and works offline (a station can recapture with the
  /// network down and the closure lands later). rework_logs is append-only, so
  /// replaying a row is harmless; the coalescing key is (folder, image).
  Future<void> enqueueReworkClosed({
    DatabaseExecutor? transaction,
    required String deviceId,
    required String projectKey,
    required String projectId,
    required String boxName,
    required int folderSeq,
    required String folderName,
    required String imageName,
    required String assignedUsername,
    String? comment,
    String reworkType = 'Recapture',
  }) async {
    Future<void> enqueue(DatabaseExecutor txn) async {
      await _enqueueOutbox(
        txn,
        entity: 'rework_logs',
        entityKey: '$projectKey|$boxName|$folderSeq|$imageName',
        op: 'upsert',
        payload: {
          'project_key': projectKey,
          'project_id': projectId,
          'box_name': boxName,
          'device_id': deviceId,
          'folder_seq': folderSeq,
          'folder_name': folderName,
          'image_name': imageName,
          // The sink resolves assigned_uid from this (see its userId helper).
          'user_id': assignedUsername,
          'rework_comments':
              comment ??
              (reworkType == 'Recapture'
                  ? 'Recaptured in LWCAM'
                  : 'Metadata corrected in LWCAM'),
          'rework_type': reworkType,
          // UTC, explicitly. A naive local string ("…T11:28:37") is cast to
          // timestamptz using the PG SESSION timezone, which is UTC — so a
          // +08 station's closure landed EIGHT HOURS IN THE FUTURE (observed
          // 2026-07-30: submitted 11:28:37 local, stored 11:28:37Z). That is
          // not cosmetic here: selectOpenReworkSql picks the LATEST row per
          // image, so a future-dated CLOSED row would outrank a genuine new
          // OPEN row for the next 8 hours and hide the re-rejection from the
          // operator.
          'closed_at': DateTime.now().toUtc().toIso8601String(),
        },
      );
    }
    if (transaction != null) {
      await enqueue(transaction);
    } else {
      final db = await getDatabase(deviceId);
      await db.transaction(enqueue);
    }
  }

  /// The folder side of a rework submit: the metadata columns the operator
  /// corrected, plus [resetQcStatus] when the folder's fix was metadata-only.
  ///
  /// [changedMetadata] must be "local value vs the cloud value read when the box
  /// was opened" — that is what makes the outbox's coalescing safe here, since a
  /// later payload for the same folder is then always a superset of an undrained
  /// earlier one.
  ///
  /// [resetQcStatus] is false whenever any image in the folder was recaptured:
  /// the file change makes LWIP reprocess, and its report resets qc_status after
  /// the new output is verified. Setting it here too would put the folder back in
  /// the QC queue before it had been reprocessed.
  Future<void> enqueueFolderRework({
    DatabaseExecutor? transaction,
    required String deviceId,
    required String projectKey,
    required String projectId,
    required String boxName,
    required int folderSeq,
    required String folderName,
    required Map<String, Object?> changedMetadata,
    required bool resetQcStatus,
    bool? isCreatedThumbnail, // null = unknown, PG column left untouched
  }) async {
    if (changedMetadata.isEmpty && !resetQcStatus) return;
    Future<void> enqueue(DatabaseExecutor txn) async {
      await _enqueueOutbox(
        txn,
        entity: 'capture_folder_rework',
        entityKey: '$projectKey|$boxName|$folderSeq',
        op: 'upsert',
        payload: {
          'project_key': projectKey,
          'project_id': projectId,
          'box_name': boxName,
          'device_id': deviceId,
          'folder_seq': folderSeq,
          'folder_name': folderName,
          'metadata': changedMetadata,
          'reset_qc_status': resetQcStatus,
          'is_created_thumbnail': isCreatedThumbnail,
        },
      );
    }
    if (transaction != null) {
      await enqueue(transaction);
    } else {
      final db = await getDatabase(deviceId);
      await db.transaction(enqueue);
    }
  }

  /// Entity keys of rework closures still sitting in this device's outbox,
  /// i.e. `<projectKey>|<boxName>|<folderSeq>|<imageName>`.
  ///
  /// The worklist comes from PostgreSQL, but a closure reaches PG only when the
  /// outbox drains (up to ~30s, or much longer offline). Without this the badge
  /// and the rework screen keep showing requests the operator has already
  /// settled, and re-opening rework would offer to recapture them again.
  /// Reading it back from the local outbox — rather than an in-memory flag —
  /// means that suppression survives an app restart and clears itself
  /// automatically the moment the row actually syncs.
  Future<Set<String>> pendingReworkClosureKeys(String deviceId) async {
    if (deviceId.trim().isEmpty) return {};
    try {
      final db = await getDatabase(deviceId);
      final rows = await db.query(
        'sync_outbox',
        columns: ['entity_key'],
        where: "entity = 'rework_logs'",
      );
      return {
        for (final r in rows)
          if ((r['entity_key'] as String?)?.isNotEmpty ?? false)
            r['entity_key'] as String,
      };
    } catch (e) {
      print('⚠️ Could not read pending rework closures: $e');
      return {};
    }
  }

  // --- Deleting folders and boxes ------------------------------------------

  /// Deletes a folder only when no images are assigned to it. Returns false
  /// (and deletes nothing) otherwise.
  Future<bool> deleteCaptureFolder({
    required String deviceId,
    required int folderId,
  }) async {
    final db = await getDatabase(deviceId);
    return db.transaction((txn) async {
      final countRows = await txn.rawQuery(
        'SELECT COUNT(*) AS c FROM capture_images WHERE folder_id = ?',
        [folderId],
      );
      if ((countRows.first['c'] as num).toInt() > 0) return false;
      await _deleteFolderRow(txn, folderId);
      return true;
    });
  }

  /// Deletes one folder row and enqueues its delete. The
  /// caller has already established that no image is assigned to it.
  Future<void> _deleteFolderRow(DatabaseExecutor txn, int folderId) async {
    // Snapshot the cloud natural key BEFORE the row disappears — delete
    // ops must carry it (the sink soft-deletes by (box, folder_seq)).
    Map<String, dynamic>? deletePayload;
    final rows = await txn.query(
      'capture_folders',
      columns: ['box_id', 'folder_seq'],
      where: 'id = ?',
      whereArgs: [folderId],
      limit: 1,
    );
    if (rows.isNotEmpty) {
      deletePayload = {
        'folder_seq': rows.first['folder_seq'],
        ...await _parentBoxKeys(txn, rows.first['box_id']),
      };
    }

    await txn.delete('capture_folders', where: 'id = ?', whereArgs: [folderId]);

    if (deletePayload != null) {
      await _enqueueOutbox(
        txn,
        entity: 'capture_folders',
        entityKey: '$folderId',
        op: 'delete',
        payload: deletePayload,
      );
    }
  }

  /// Deletes a box and its folders only when NO image is assigned anywhere in
  /// it. Returns false (and deletes nothing) otherwise.
  ///
  /// Each folder goes through [_deleteFolderRow], so the outbox carries one
  /// delete per folder followed by the box's own — the folder deletes are
  /// enqueued first, and the box row's REPLACE on (entity, entity_key) turns
  /// any still-pending box upsert into the delete. A box that never reached
  /// PG resolves to nothing in the sink and is skipped there.
  Future<bool> deleteCaptureBox({
    required String deviceId,
    required int boxId,
  }) async {
    final db = await getDatabase(deviceId);
    return db.transaction((txn) async {
      final countRows = await txn.rawQuery(
        'SELECT COUNT(*) AS c FROM capture_images WHERE box_id = ?',
        [boxId],
      );
      if ((countRows.first['c'] as num).toInt() > 0) return false;

      final deletePayload = await _parentBoxKeys(txn, boxId);

      final folders = await txn.query(
        'capture_folders',
        columns: ['id'],
        where: 'box_id = ?',
        whereArgs: [boxId],
      );
      for (final f in folders) {
        await _deleteFolderRow(txn, (f['id'] as num).toInt());
      }

      await txn.delete('capture_boxes', where: 'id = ?', whereArgs: [boxId]);

      if (deletePayload.isNotEmpty) {
        await _enqueueOutbox(
          txn,
          entity: 'capture_boxes',
          entityKey: '$boxId',
          op: 'delete',
          payload: deletePayload,
        );
      }
      return true;
    });
  }

  /// Destination folder names already assigned to folders of OTHER boxes on
  /// this device, lower-cased.
  ///
  /// The transfer destination is `<root>\<YYYYMMDD>\<folderName>` — a
  /// station-wide root and a DAY folder, with nothing in the path identifying
  /// the group. So a folder name only has to repeat once, in any other group
  /// landing on the same day, for two groups' images to be written into one
  /// directory. Naming a folder after its Volume made that reachable: the old
  /// `<group details> - <file no> - 0001` shape carried the group in the name
  /// and could not collide across groups.
  ///
  /// Reserved across every other box rather than same-day ones, because the
  /// transfer date is not known at prep time. The cost is a `- 0002` on a
  /// Volume legitimately reused by a later group; the alternative is a silent
  /// merge.
  Future<Set<String>> reservedFolderNames({
    required String deviceId,
    required int excludeBoxId,
  }) async {
    final db = await getDatabase(deviceId);
    final rows = await db.query(
      'capture_folders',
      columns: ['folder_name'],
      where: 'box_id != ? AND folder_name IS NOT NULL AND folder_name != ""',
      whereArgs: [excludeBoxId],
    );
    return {
      for (final row in rows) (row['folder_name'] as String).toLowerCase(),
    };
  }

  Future<List<CaptureFolder>> getCaptureFolders({
    required String deviceId,
    required int boxId,
  }) async {
    final db = await getDatabase(deviceId);
    final rows = await db.query(
      'capture_folders',
      where: 'box_id = ?',
      whereArgs: [boxId],
      orderBy: 'folder_seq ASC',
    );
    return rows.map(CaptureFolder.fromDbMap).toList();
  }

  /// The box's cloud natural keys (box_name, project_id, project_key,
  /// renamed_from, device_id) — the same shape folder/image sync payloads
  /// carry. Used by the processing-marker writer to stamp folder identity
  /// into the destination. Empty map if the box row is gone.
  Future<Map<String, dynamic>> boxNaturalKeys({
    required String deviceId,
    required int boxId,
  }) async {
    final db = await getDatabase(deviceId);
    return _parentBoxKeys(db, boxId);
  }

  static Future<void> _createColorCalibrationTables(DatabaseExecutor db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS color_pending (image_name TEXT PRIMARY KEY)');
    await db.execute('CREATE TABLE IF NOT EXISTS color_integrity (id INTEGER PRIMARY KEY, reason TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS color_profiles (hash TEXT PRIMARY KEY, payload TEXT NOT NULL)');
    await db.execute('CREATE TABLE IF NOT EXISTS color_bindings (image_name TEXT PRIMARY KEY, binding_json TEXT NOT NULL)');
  }

  /// Reasons a page may legitimately have no profile.
  static const _validUncalibratedReasons = {
    'disabled',
    'skipped',
    'historical',
    'external',
  };

  static Future<void> _saveColorBinding(DatabaseExecutor db, String name, Map<String, dynamic>? supplied) async {
    final binding = Map<String, dynamic>.from(supplied ?? {'profile': null, 'reason': 'historical'});
    final payload = binding.remove('payload');
    if (binding['profile'] != null) {
      if (payload is! String || sha256.convert(utf8.encode(payload)).toString() != binding['profile']) {
        throw StateError('Missing or damaged colour profile snapshot');
      }
      await db.insert('color_profiles', {'hash': binding['profile'], 'payload': payload}, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
    await db.insert('color_bindings', {'image_name': name, 'binding_json': jsonEncode(binding)}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<Map<String, dynamic>> colorBindingFor(String deviceId, String name) async {
    final db = await getDatabase(deviceId);
    if ((await db.query('color_integrity')).isNotEmpty) {
      throw StateError('Calibration history could not be recovered. Restore the local database backup before transferring.');
    }
    if ((await db.query('color_pending', where: 'image_name = ?', whereArgs: [name])).isNotEmpty) {
      throw StateError('Interrupted recapture for $name. Retake this page before transferring.');
    }
    final rows = await db.query('color_bindings', where: 'image_name = ?', whereArgs: [name]);
    if (rows.isEmpty) return {'profile': null, 'reason': 'historical'};
    final binding = Map<String, dynamic>.from(jsonDecode(rows.first['binding_json'] as String) as Map);
    if (binding['profile'] != null) {
      final profiles = await db.query('color_profiles', where: 'hash = ?', whereArgs: [binding['profile']]);
      if (profiles.isEmpty) throw StateError('Missing colour profile for $name');
      binding['payload'] = profiles.first['payload'];
      if (sha256.convert(utf8.encode(binding['payload'] as String)).toString() != binding['profile']) {
        throw StateError('Damaged colour profile for $name');
      }
    }
    return binding;
  }

  Future<void> markColorReplacementPending(String deviceId, String name) async {
    final db = await getDatabase(deviceId);
    await db.insert('color_pending', {'image_name': name}, conflictAlgorithm: ConflictAlgorithm.ignore);
  }

  Future<void> saveColorBinding(String deviceId, String name, Map<String, dynamic> binding) async {
    final db = await getDatabase(deviceId);
    await db.transaction((txn) async {
      await _saveColorBinding(txn, name, binding);
      await txn.delete('color_pending', where: 'image_name = ?', whereArgs: [name]);
    });
  }

  /// Reads one folder's calibration with page-level issues instead of
  /// throwing on the first problem. A recovered [color_integrity] row makes
  /// only the pages WITHOUT a binding unknown; pages with a valid profile
  /// still travel with their original parameters.
  Future<FolderColorCalibration> checkFolderColorCalibration(
    String deviceId,
    int folderId,
  ) async {
    final db = await getDatabase(deviceId);
    return db.transaction((txn) async {
      final imageRows = await txn.query(
        'capture_images',
        where: 'folder_id = ?',
        whereArgs: [folderId],
      );
      final bindingRows = await txn.query('color_bindings');
      final profileRows = await txn.query('color_profiles');
      final pendingRows = await txn.query('color_pending');
      final integrityRows = await txn.query('color_integrity');

      final bindings = <String, Map<String, dynamic>>{
        for (final row in bindingRows)
          if (row['image_name'] is String)
            row['image_name'] as String: Map<String, dynamic>.from(row),
      };
      final profiles = <String, String>{
        for (final row in profileRows)
          if (row['hash'] is String && row['payload'] is String)
            row['hash'] as String: row['payload'] as String,
      };
      final pending = <String>{
        for (final row in pendingRows)
          if (row['image_name'] is String) row['image_name'] as String,
      };
      final integrityReason = integrityRows.isEmpty
          ? null
          : (integrityRows.first['reason'] is String &&
                  (integrityRows.first['reason'] as String).trim().isNotEmpty
              ? integrityRows.first['reason'] as String
              : 'unknown recovery error');

      final images = <String, dynamic>{};
      final usedProfiles = <String, dynamic>{};
      final issues = <ColorCalibrationIssue>[];

      for (final row in imageRows) {
        final name = row['image_name'] as String;
        // An unchanged transfer name is intentionally not persisted by the DB.
        final target = (row['transferred_name'] as String?) ?? name;
        if (pending.contains(name)) {
          issues.add(ColorCalibrationIssue(
            imageName: name,
            kind: ColorCalibrationIssueKind.pendingRecapture,
            reason: 'recapture in progress',
          ));
          continue;
        }
        final bindingRow = bindings[name];
        if (bindingRow == null) {
          if (integrityReason != null) {
            issues.add(ColorCalibrationIssue(
              imageName: name,
              kind: ColorCalibrationIssueKind.unknownBinding,
              reason: integrityReason,
            ));
          } else {
            images[target] = {'profile': null, 'reason': 'historical'};
          }
          continue;
        }
        Map<String, dynamic> binding;
        try {
          final decoded = jsonDecode(bindingRow['binding_json'] as String);
          if (decoded is! Map) {
            throw const FormatException('binding is not an object');
          }
          binding = Map<String, dynamic>.from(decoded);
        } catch (error) {
          issues.add(ColorCalibrationIssue(
            imageName: name,
            kind: ColorCalibrationIssueKind.damagedBinding,
            reason: 'invalid binding ($error)',
          ));
          continue;
        }
        final profile = binding['profile'];
        if (profile == null) {
          final reason = binding['reason'];
          if (reason is! String || !_validUncalibratedReasons.contains(reason)) {
            issues.add(ColorCalibrationIssue(
              imageName: name,
              kind: ColorCalibrationIssueKind.damagedBinding,
              reason: 'unexplained uncalibrated binding',
            ));
            continue;
          }
          images[target] = binding;
          continue;
        }
        if (profile is! String) {
          issues.add(ColorCalibrationIssue(
            imageName: name,
            kind: ColorCalibrationIssueKind.damagedBinding,
            reason: 'invalid profile reference',
          ));
          continue;
        }
        final payload = profiles[profile];
        if (payload == null) {
          issues.add(ColorCalibrationIssue(
            imageName: name,
            kind: ColorCalibrationIssueKind.damagedBinding,
            reason: 'missing profile payload',
          ));
          continue;
        }
        if (sha256.convert(utf8.encode(payload)).toString() != profile) {
          issues.add(ColorCalibrationIssue(
            imageName: name,
            kind: ColorCalibrationIssueKind.damagedBinding,
            reason: 'profile checksum mismatch',
          ));
          continue;
        }
        usedProfiles[profile] = payload;
        binding.remove('payload');
        images[target] = binding;
      }

      return FolderColorCalibration(
        marker: {'version': 1, 'profiles': usedProfiles, 'images': images},
        issues: issues,
      );
    });
  }

  /// Strict compatibility helper. New transfer code should use
  /// [checkFolderColorCalibration] and resolve issues explicitly.
  Future<Map<String, dynamic>> folderColorCalibration(
    String deviceId,
    int folderId,
  ) async {
    final check = await checkFolderColorCalibration(deviceId, folderId);
    if (check.hasIssues) throw StateError(check.issueSummary);
    return check.marker;
  }

  /// Writes an explicit historical decision for every page in [folderId] that
  /// still has no binding. Never overwrites a binding that appeared while the
  /// operator was deciding; an interrupted recapture aborts the whole accept.
  Future<int> bindHistoricalIfUnbound(String deviceId, int folderId) =>
      bindHistoricalIfUnboundFolders(deviceId, [folderId]);

  /// Atomic across folders: one interrupted recapture rolls every write back,
  /// so accepting a box is all-or-nothing.
  Future<int> bindHistoricalIfUnboundFolders(
    String deviceId,
    Iterable<int> folderIds,
  ) async {
    final folders = folderIds.toSet().toList();
    if (folders.isEmpty) return 0;
    final placeholders = List.filled(folders.length, '?').join(',');
    final db = await getDatabase(deviceId);
    return db.transaction((txn) async {
      final images = await txn.query(
        'capture_images',
        where: 'folder_id IN ($placeholders)',
        whereArgs: folders,
      );
      final pendingRows = await txn.query('color_pending');
      final pending = <String>{
        for (final row in pendingRows)
          if (row['image_name'] is String) row['image_name'] as String,
      };
      var accepted = 0;
      for (final row in images) {
        final name = row['image_name'] as String;
        if (pending.contains(name)) {
          throw StateError(
            'Interrupted recapture for $name. Retake this page before transferring.',
          );
        }
        final existing = await txn.query(
          'color_bindings',
          where: 'image_name = ?',
          whereArgs: [name],
          limit: 1,
        );
        if (existing.isNotEmpty) continue;
        await txn.insert(
          'color_bindings',
          {
            'image_name': name,
            'binding_json': jsonEncode({
              'profile': null,
              'reason': 'historical',
              'bound_at': DateTime.now().toIso8601String(),
            }),
          },
          conflictAlgorithm: ConflictAlgorithm.ignore,
        );
        accepted++;
      }
      return accepted;
    });
  }

  /// Deletes the device-wide recovery flag only when every page in every OPEN
  /// box has a valid, explicitly-decided binding. TRANSFERRED boxes are
  /// deliberately ignored: nothing re-marks them.
  ///
  /// A false return does NOT mean the current transfer must fail — the flag
  /// can still be needed by another OPEN box; the current box's marker is
  /// written from its own (now complete) folder bindings.
  Future<bool> clearColorIntegrityIfOpenPagesBound(String deviceId) async {
    final db = await getDatabase(deviceId);
    if ((await db.query('color_integrity')).isEmpty) return true;
    final boxes = await db.query(
      'capture_boxes',
      where: "UPPER(status) = 'OPEN'",
    );
    for (final box in boxes) {
      final folders = await db.query(
        'capture_folders',
        where: 'box_id = ?',
        whereArgs: [box['id']],
      );
      for (final folder in folders) {
        final folderId = (folder['id'] as num).toInt();
        final check = await checkFolderColorCalibration(deviceId, folderId);
        if (check.hasIssues) return false;
      }
    }
    // An image whose folder row is missing is not reached by the loop above;
    // it still must have an explicit binding before the device flag clears.
    final missing = await db.rawQuery('''
      SELECT COUNT(*) AS n
      FROM capture_images i
      JOIN capture_boxes b ON b.id = i.box_id
      LEFT JOIN color_bindings cb ON cb.image_name = i.image_name
      WHERE UPPER(b.status) = 'OPEN' AND cb.image_name IS NULL
    ''');
    if (((missing.first['n'] as num?)?.toInt() ?? 0) != 0) return false;
    await db.delete('color_integrity');
    return true;
  }

  // ── Image assignments (cloud capture_images mirror) ─────────────────────

  /// Cloud CHECK constraint set for capture_images.file_format.
  static const _allowedImageFormats = {'jpg', 'jpeg', 'tif', 'tiff', 'png'};

  /// Extension of [filename], lowercased without the dot, coerced into the
  /// cloud CHECK set ('jpg' fallback — phone captures are always JPEG).
  static String fileFormatOf(String filename) {
    final dot = filename.lastIndexOf('.');
    final ext = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
    if (_allowedImageFormats.contains(ext)) return ext;
    print(
      '⚠️ Unexpected image extension "$ext" on $filename — recording as jpg.',
    );
    return 'jpg';
  }

  /// Assigns [deviceFilename] to a folder. Returns false without throwing when
  /// the filename is already assigned anywhere (image_name UNIQUE). This is
  /// the single write path for box membership — capture, orphan heal, and
  /// admin resolution all route through here, so the sync enqueue below
  /// covers every assignment source.
  Future<bool> assignImageToFolder({
    required String deviceId,
    required int boxId,
    required int folderId,
    required String deviceFilename,
    Map<String, dynamic>? colorBinding,
  }) async {
    final db = await getDatabase(deviceId);
    try {
      await db.transaction((txn) async {
        final row = {
          'image_name': deviceFilename,
          'device_id': deviceId,
          'folder_id': folderId,
          'file_format': fileFormatOf(deviceFilename),
          'image_created_at': DateTime.now().toIso8601String(),
          'box_id': boxId,
        };
        await txn.insert(
          'capture_images',
          row,
          conflictAlgorithm: ConflictAlgorithm.abort,
        );
        await _saveColorBinding(txn, deviceFilename, colorBinding);
        await _enqueueCaptureImageUpsert(txn, folderId, deviceFilename, row);
      });
      return true;
    } on DatabaseException catch (e) {
      if (e.isUniqueConstraintError()) return false;
      rethrow;
    }
  }

  /// Reports the filename the transfer actually wrote for [deviceName] to the
  /// CLOUD and records that final name beside the stable local row.
  ///
  /// A capture records the DEVICE filename immediately (so the productivity
  /// dashboard sees the image right away), but the transfer writes the file as
  /// `<deviceId>_<stem>_<NNN>.ext` — the suffix is allocated against
  /// destination disk state, so it cannot be known at capture. QC and the
  /// export resolve files via cloud folder_path/image_name, so the CLOUD row
  /// must carry the final name.
  ///
  /// The LOCAL row deliberately keeps the device filename in [image_name]: it
  /// is the identity everything on this machine keys on — phone re-staging on
  /// retry, the durable box_images store, orphan healing, and thumbnails.
  /// [transferred_name] is only the cloud filename used by delete/recovery.
  ///
  /// The enqueued payload carries `image_renamed_from` so the sink moves the
  /// already-synced cloud row instead of minting a duplicate under the final
  /// name. Idempotent: re-running a copy re-enqueues the same payload, which
  /// coalesces on (entity, entity_key). Returns true when a report was
  /// enqueued.
  Future<bool> reportCaptureImageTransferName({
    required String deviceId,
    required String deviceName,
    required String finalName,
  }) async {
    if (deviceName == finalName) return false;
    final db = await getDatabase(deviceId);
    return await db.transaction((txn) async {
      // image_name is globally UNIQUE in this local DB, so the device name
      // alone identifies the row — the caller does not need the folder id.
      final rows = await txn.query(
        'capture_images',
        where: 'image_name = ?',
        whereArgs: [deviceName],
        limit: 1,
      );
      if (rows.isEmpty) return false; // Normal Mode keeps no capture_images
      final row = Map<String, dynamic>.from(rows.first);
      final folderId = (row['folder_id'] as num).toInt();

      await txn.update(
        'capture_images',
        {
          'transferred_name': finalName,
          'image_updated_at': DateTime.now().toIso8601String(),
        },
        where: 'image_name = ?',
        whereArgs: [deviceName],
      );
      row['image_name'] = finalName;
      // Deliberately NOT 'renamed_from': that key already means "the parent
      // BOX's previous name", and _parentBoxKeys injects it into every image
      // payload (the sink resolves a mid-rename box through it). Reusing it
      // would be clobbered on the way out AND misread as a box rename.
      row['image_renamed_from'] = deviceName;
      row['image_updated_at'] = DateTime.now().toIso8601String();
      row.remove('id');
      row.remove('box_id'); // local-only, never on the wire
      row.remove('transferred_name'); // local-only, never on the wire
      await _enqueueCaptureImageUpsert(
        txn,
        folderId,
        finalName,
        row,
        entityKeyName: deviceName,
      );
      return true;
    });
  }

  /// Repairs a missing local/cloud rename intent from upload_records, which is
  /// the durable proof that a verified destination file already landed. This
  /// closes the crash window between that commit and the final rename report
  /// without storing another filename column in PostgreSQL.
  Future<bool> reconcileCaptureImageTransferName({
    required String deviceId,
    required String deviceName,
    required Set<String> recordedFilenames,
  }) async {
    final db = await getDatabase(deviceId);
    final rows = await db.query(
      'capture_images',
      columns: ['transferred_name'],
      where: 'image_name = ?',
      whereArgs: [deviceName],
      limit: 1,
    );
    if (rows.isEmpty) return false;
    final existing = (rows.first['transferred_name'] as String?)?.trim();
    if (existing != null && existing.isNotEmpty) return true;

    final base = baseNameForDeviceFilename(deviceId, deviceName);
    if (base.isEmpty) return false;
    final extension = p.extension(deviceName);
    final pattern = RegExp(
      '^${RegExp.escape(base)}(?:_\\d{3})?${RegExp.escape(extension)}\$',
      caseSensitive: false,
    );
    final matches = recordedFilenames.where(pattern.hasMatch).toList();
    if (matches.length > 1) {
      throw StateError(
        'More than one transferred filename matches $deviceName: '
        '${matches.join(', ')}',
      );
    }
    if (matches.isEmpty) return false;
    return reportCaptureImageTransferName(
      deviceId: deviceId,
      deviceName: deviceName,
      finalName: matches.single,
    );
  }

  /// Joins the folder's seq + parent box natural keys into an image payload
  /// and enqueues it. Payload identity on the wire: (project_key, box_name,
  /// folder_seq, image_name).
  Future<void> _enqueueCaptureImageUpsert(
    DatabaseExecutor txn,
    int folderId,
    String imageName,
    Map<String, dynamic> row, {
    String? entityKeyName,
  }) async {
    final payload = Map<String, dynamic>.from(row);
    final folderRows = await txn.query(
      'capture_folders',
      columns: ['box_id', 'folder_seq'],
      where: 'id = ?',
      whereArgs: [folderId],
      limit: 1,
    );
    if (folderRows.isNotEmpty) {
      payload['folder_seq'] = folderRows.first['folder_seq'];
      payload.addAll(await _parentBoxKeys(txn, folderRows.first['box_id']));
    }
    payload.remove('transferred_name'); // local-only
    await _enqueueOutbox(
      txn,
      entity: 'capture_images',
      entityKey: '$folderId|${entityKeyName ?? imageName}',
      op: 'upsert',
      payload: payload,
    );
  }

  /// Removes the mapping for a deleted device photo (any box) — but ONLY
  /// while the image hasn't transferred yet. Once `transferred_name` is set,
  /// LWCAM refuses: only the QC platform may delete a transferred image
  /// (locked decision — a live-sync/device-delete diff reaching a
  /// transferred row of another box orphaned cloud data). Returns `false`
  /// on refusal so the caller can skip the matching local cleanup (durable
  /// copy, audit log) too.
  Future<bool> unassignImage({
    required String deviceId,
    required String deviceFilename,
  }) async {
    final db = await getDatabase(deviceId);
    return db.transaction((txn) async {
      final rows = await txn.query(
        'capture_images',
        columns: ['folder_id', 'transferred_name'],
        where: 'image_name = ?',
        whereArgs: [deviceFilename],
        limit: 1,
      );
      if (rows.isEmpty) return true; // nothing to unassign — not a refusal
      final transferredName = (rows.first['transferred_name'] as String?)
          ?.trim();
      if (transferredName != null && transferredName.isNotEmpty) {
        print(
          '⛔ Refusing to unassign "$deviceFilename" — already transferred '
          'as "$transferredName". Only QC may delete a transferred image.',
        );
        return false;
      }
      final folderId = (rows.first['folder_id'] as num).toInt();

      // transferred_name is guaranteed empty here — the refusal above
      // already returned for any row that has one.
      final deletePayload = <String, dynamic>{'image_name': deviceFilename};
      final folderRows = await txn.query(
        'capture_folders',
        columns: ['box_id', 'folder_seq'],
        where: 'id = ?',
        whereArgs: [folderId],
        limit: 1,
      );
      if (folderRows.isNotEmpty) {
        deletePayload['folder_seq'] = folderRows.first['folder_seq'];
        deletePayload.addAll(
          await _parentBoxKeys(txn, folderRows.first['box_id']),
        );
      }

      await txn.delete(
        'capture_images',
        where: 'image_name = ?',
        whereArgs: [deviceFilename],
      );
      await _enqueueOutbox(
        txn,
        entity: 'capture_images',
        entityKey: '$folderId|$deviceFilename',
        op: 'delete',
        payload: deletePayload,
      );
      return true;
    });
  }

  /// filename → folder_id for every assignment in [boxId].
  Future<Map<String, int>> getAssignmentsForBox({
    required String deviceId,
    required int boxId,
  }) async {
    final db = await getDatabase(deviceId);
    final rows = await db.query(
      'capture_images',
      columns: ['image_name', 'folder_id'],
      where: 'box_id = ?',
      whereArgs: [boxId],
    );
    return {
      for (final r in rows)
        (r['image_name'] as String): (r['folder_id'] as num).toInt(),
    };
  }

  /// folder_id → assigned-image count for [boxId].
  Future<Map<int, int>> countImagesPerFolder({
    required String deviceId,
    required int boxId,
  }) async {
    final db = await getDatabase(deviceId);
    final rows = await db.rawQuery(
      'SELECT folder_id, COUNT(*) AS c FROM capture_images WHERE box_id = ? GROUP BY folder_id',
      [boxId],
    );
    return {
      for (final r in rows)
        (r['folder_id'] as num).toInt(): (r['c'] as num).toInt(),
    };
  }

  // =======================================================
  // ALREADY-UPLOADED BASE NAMES (for skip logic)
  // =======================================================

  /// Returns a set of base names that have been uploaded for this device.
  ///
  /// Our saved filenames look like:
  ///   SAX01_IMG_20251101_121635_001.jpg
  ///   SAX01_IMG_20251101_121635_002.jpg
  ///
  /// The "base name" here is:
  ///   SAX01_IMG_20251101_121635
  ///
  /// This lets us treat all copies with the same timestamp
  /// (e.g. double-click captures) as "already uploaded".
  Future<Set<String>> getUploadedBaseNames(String deviceId) async {
    final result = <String>{};
    final reg = RegExp(r'^(.+)_\d{3}\.[^\.]+$');

    for (final db in await _allDeviceUploadDatabases(deviceId)) {
      final rows = await db.query(
        'upload_records',
        columns: ['filename'],
        where: 'device_id = ?',
        whereArgs: [deviceId],
      );
      for (final row in rows) {
        final filename = row['filename'] as String?;
        if (filename == null) continue;
        final match = reg.firstMatch(filename);
        if (match != null) {
          result.add(match.group(1)!);
        }
      }
    }

    return result;
  }

  /// Every FULL recorded destination filename for [deviceId] (suffix and
  /// extension included), across the stable DB and all monthly files. A
  /// record exists only for a copy that completed and passed its size check —
  /// so a destination file whose name is NOT in this set is an orphan from an
  /// interrupted run (power loss/crash mid-copy) and safe to overwrite; see
  /// the name allocator in transfer_controller.dart.
  Future<Set<String>> getUploadedFilenames(String deviceId) async {
    final result = <String>{};
    for (final db in await _allDeviceUploadDatabases(deviceId)) {
      final rows = await db.query(
        'upload_records',
        columns: ['filename'],
        where: 'device_id = ?',
        whereArgs: [deviceId],
      );
      for (final row in rows) {
        final filename = row['filename'] as String?;
        if (filename != null) result.add(filename);
      }
    }
    return result;
  }
}
