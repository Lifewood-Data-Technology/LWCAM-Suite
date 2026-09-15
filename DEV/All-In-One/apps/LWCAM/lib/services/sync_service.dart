import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:get/get.dart';
import 'package:sqflite/sqflite.dart';

import '../db/upload_stats_db.dart';
import '../models/app_user.dart';
import 'cloud_box_names.dart';
import 'sync_models.dart';
import 'sync_sink.dart';

/// Drains `sync_outbox` on a periodic timer and pushes batches through a
/// [SyncSink]. Runs on the main isolate (see plan P1-3: sqflite's singleton
/// connection can't be shared across isolates, and outbox volume is small
/// enough that async socket I/O here never blocks capture/transfer, which
/// use their own db calls interleaved on the same event loop).
///
/// A tick drains EVERY device's outbox on this PC, not just [deviceId]'s —
/// [UploadStatsDB.getOutboxDatabases] enumerates them, the bound device first.
/// Draining only the bound one stranded other operators' rows on a shared PC
/// (see that method for the live incident). Rows are sorted by
/// `kSyncEntityOrder` WITHIN each source, which is where the
/// parents-before-children ordering matters; across sources there is nothing to
/// order, since two devices' rows describe disjoint boxes.
///
/// [SyncBootstrap] only constructs this at all once a PG host is configured;
/// the users/projects/settings pull then always runs. Construct with
/// `drainEnabled: false` (or simply never call [start]) to skip the outbox
/// drain only — e.g. capture sync toggled off but PG still configured.
class SyncService extends GetxController {
  final UploadStatsDB _db;
  final SyncSink _sink;
  final String deviceId;
  final int batchSize;
  final Duration tickInterval;

  /// Governs the outbox drain + pending-count only. The users/projects/
  /// settings pull (and the box-name tail pull) run every tick regardless —
  /// [SyncState.disabled] now means "no PG host configured", nothing else
  /// (Fix 7: this refresh cannot be turned off independently of PG being
  /// configured at all).
  final bool drainEnabled;

  /// Applies a freshly PULLED users/projects/app-settings store at the start
  /// of every tick (before the outbox drain, so its FK parents always exist
  /// by the time rows resolve against them) — wired by SyncBootstrap to
  /// [UsersStoreService.applySnapshot]. Null skips the pull entirely (tests
  /// that only exercise the outbox drain).
  final Future<void> Function(UsersStore store)? applyPulledStore;

  /// The active capture project's stable client key (`Project.key`), for the
  /// box-name uniqueness pull at the tail of each tick; null skips the pull.
  final String? Function()? activeProjectKey;

  final Rx<SyncState> state = SyncState.disabled.obs;
  final RxInt pendingCount = 0.obs;
  final Rx<String?> lastError = Rx<String?>(null);

  bool _draining = false;
  Timer? _timer;

  /// Suspends the tick without tearing the timer down or touching [state].
  /// Set while a device DB is being rebuilt: a tick's FIRST action enumerates
  /// and OPENS every device DB on the PC, which would race the promotion.
  /// [stop] is wrong for this — it sets [SyncState.disabled], which means "no
  /// PG host configured".
  bool paused = false;

  SyncService({
    required UploadStatsDB db,
    required SyncSink sink,
    required this.deviceId,
    this.drainEnabled = true,
    this.batchSize = 200,
    this.tickInterval = const Duration(seconds: 30),
    this.applyPulledStore,
    this.activeProjectKey,
  }) : _db = db,
       _sink = sink;

  /// Starts the periodic tick timer. Idempotent — calling it again just
  /// resets the interval. [SyncBootstrap] only constructs/starts a
  /// SyncService at all once a PG host is configured, so ticking here is
  /// unconditional — [drainEnabled] (not this method) decides whether the
  /// outbox actually drains each tick.
  void start() {
    _timer?.cancel();
    state.value = SyncState.idle;
    _timer = Timer.periodic(tickInterval, (_) => syncNow());
    // Kick off an immediate first tick rather than waiting a full interval.
    syncNow();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    state.value = SyncState.disabled;
  }

  @override
  void onClose() {
    stop();
    _sink.close();
    super.onClose();
  }

  /// Drains up to [batchSize] eligible rows per SOURCE DB in one tick — the
  /// bound device's stable DB, then every other device's on this PC (see
  /// [UploadStatsDB.getOutboxDatabases]). Reentrancy-guarded — a slow tick
  /// never overlaps the next timer fire.
  Future<void> syncNow() async {
    if (paused || _draining) return;
    _draining = true;
    try {
      await _syncNowBody();
    } catch (e) {
      // The timer fires this method unawaited — anything that escapes here
      // reaches runZonedGuarded and shows a crash MessageBox mid-transfer.
      // Every known failure mode above already has fine-grained handling;
      // this is only a backstop against one that doesn't.
      print('⚠️ Sync tick failed: $e');
      lastError.value = e.toString();
      state.value = SyncState.error;
    } finally {
      _draining = false;
    }
  }

  Future<void> _syncNowBody() async {
    final sources = drainEnabled
        ? await _db.getOutboxDatabases(deviceId)
        : const <Database>[];
    if (drainEnabled) await _updatePendingCount(sources);

    var hadOffline = false;
    var hadError = false;

    // Users/projects/settings pull FIRST, so the outbox drain's FK
    // parents (users, projects) always exist by the time rows resolve
    // against them.
    if (applyPulledStore != null) {
      try {
        state.value = SyncState.syncing;
        final store = await _sink.pullStore();
        await applyPulledStore!(store);
      } on SyncConnectException catch (e) {
        lastError.value = e.message;
        state.value = SyncState.offline;
        return; // destination unreachable — nothing else can land this tick
      } catch (e) {
        // Keep the existing local snapshot — a failed pull must never
        // erase a good one. Idempotent; just let the next tick retry.
        print('⚠️ Users/projects pull failed: $e');
        lastError.value = e.toString();
        hadError = true;
      }
    }

    if (drainEnabled) {
      for (final source in sources) {
        final rows = await _selectEligible(source);
        if (rows.isEmpty) continue;

        state.value = SyncState.syncing;
        final ordered = [...rows]
          ..sort((a, b) => compareEntityOrder(a.entity, b.entity));

        try {
          await _sink.apply(ordered);
          await _ack(source, ordered);
          // Don't clear an error surfaced earlier this tick (e.g. the
          // users/projects pull) just because this source's drain succeeded
          // — the tick as a whole still had a failure worth showing.
          if (!hadError) lastError.value = null;
        } on SyncConnectException catch (e) {
          // Transient and a property of the destination, not this source —
          // no point trying the remaining sources this tick.
          lastError.value = e.message;
          hadOffline = true;
          break;
        } catch (e) {
          // A per-source/per-batch failure — other sources may still
          // succeed this tick, so keep going. But the batch is applied inside
          // ONE transaction (PgSyncSink.apply), so this failure rolled back
          // every row, healthy ones included. Retry them individually to find
          // the poison row, rather than punishing the whole batch for it.
          List<OutboxRecord>? failed;
          try {
            failed = await _applyIndividually(source, ordered);
          } on SyncConnectException catch (connectivity) {
            lastError.value = connectivity.message;
            hadOffline = true;
            failed = null;
          }
          final isolated = failed;
          if (isolated == null) break;
          if (isolated.isNotEmpty) {
            await _backoff(source, isolated, e.toString());
            lastError.value = e.toString();
            hadError = true;
          } else if (!hadError) {
            // Every row succeeded alone: the batch failed on cross-row state
            // (ordering, a shared cache), not on bad data. Nothing left pending.
            lastError.value = null;
          }
        }
      }
    }

    // Tail: refresh the cloud box-name cache for the active project (the
    // uniqueness pull). Best-effort — any failure just leaves the cache as
    // it was; the check silently degrades to local-only.
    if (!hadOffline) {
      final projectKey = activeProjectKey?.call()?.trim();
      if (projectKey != null && projectKey.isNotEmpty) {
        try {
          CloudBoxNames.instance.update(
            projectKey,
            await _sink.fetchBoxNames(projectKey),
          );
        } catch (e) {
          print('⚠️ Cloud box-name pull skipped: $e');
        }
      }
    }

    if (drainEnabled) await _updatePendingCount(sources);
    if (hadOffline) {
      state.value = SyncState.offline;
    } else if (hadError) {
      state.value = SyncState.error;
    } else {
      state.value = SyncState.idle;
    }
  }

  /// On-demand box-name check for [BoxSessionController.createBox] — shrinks
  /// the race window the ~30s [CloudBoxNames] cache leaves open. Best-effort:
  /// any failure or timeout returns null so the caller falls back to the
  /// cache (fail-open, never blocks box creation on network trouble).
  Future<Set<String>?> fetchFreshBoxNames(
    String projectKey, {
    Duration timeout = const Duration(seconds: 3),
  }) async {
    try {
      return await _sink.fetchBoxNames(projectKey).timeout(timeout);
    } catch (e) {
      print('⚠️ Live box-name check skipped: $e');
      return null;
    }
  }

  Future<CaptureSnapshotCounts> pullCaptureSnapshot({
    required CaptureBoxPageWriter onBoxes,
    required CaptureFolderPageWriter onFolders,
    required CaptureImagePageWriter onImages,
  }) => _sink.pullCaptureSnapshot(
    deviceId,
    onBoxes: onBoxes,
    onFolders: onFolders,
    onImages: onImages,
  );

  Future<List<OutboxRecord>> _selectEligible(Database source) async {
    final nowIso = DateTime.now().toIso8601String();
    final rows = await source.query(
      'sync_outbox',
      where: 'next_attempt_at IS NULL OR next_attempt_at <= ?',
      whereArgs: [nowIso],
      orderBy: 'id ASC',
      limit: batchSize,
    );
    return rows.map((r) {
      final rawPayload = r['payload'] as String?;
      return OutboxRecord(
        id: r['id'] as int,
        entity: r['entity'] as String,
        entityKey: r['entity_key'] as String,
        op: r['op'] as String,
        payload: rawPayload == null
            ? null
            : Map<String, dynamic>.from(jsonDecode(rawPayload) as Map),
        attempts: r['attempts'] as int,
      );
    }).toList();
  }

  /// Re-applies a failed batch ONE RECORD AT A TIME, acking each that succeeds
  /// and returning those that still fail (handover §7.9 — batch poisoning).
  ///
  /// Without this, one bad row — a missing project_key, an unresolvable user, a
  /// malformed payload — rolls back the whole batch transaction, so nothing is
  /// acked and every record's `attempts` is bumped. Up to `batchSize` healthy
  /// rows then sit behind it, retried on a backoff capped at 15 minutes,
  /// indefinitely. It also made the 20-attempt skip-ack paths (processing
  /// reports, rework closures) burn their budget on a sibling's failure.
  ///
  /// Safe to re-apply a record that had already succeeded inside the
  /// rolled-back transaction: every statement is an idempotent upsert or an
  /// append-only rework_logs insert. [ordered] order is preserved so parents
  /// still land before children.
  ///
  /// A SyncConnectException aborts the pass — the destination is gone, so the
  /// remaining rows are pending, not poison.
  Future<List<OutboxRecord>> _applyIndividually(
    Database source,
    List<OutboxRecord> ordered,
  ) async {
    final failed = <OutboxRecord>[];
    for (var i = 0; i < ordered.length; i++) {
      final record = ordered[i];
      try {
        await _sink.apply([record]);
        await _ack(source, [record]);
      } on SyncConnectException {
        // The rows after the last acknowledged row are still untouched. Let
        // the caller mark the whole pass offline instead of backoff-counting
        // them as ordinary bad data.
        rethrow;
      } catch (e) {
        print(
          '⚠️ Outbox row ${record.entity}/${record.entityKey} failed alone: $e',
        );
        failed.add(record);
      }
    }
    return failed;
  }

  Future<void> _ack(Database source, List<OutboxRecord> applied) async {
    await source.transaction((txn) async {
      for (final record in applied) {
        await txn.delete(
          'sync_outbox',
          where: 'id = ?',
          whereArgs: [record.id],
        );
      }
    });
  }

  /// Exponential backoff with jitter, capped at 15 minutes (plan P1-3):
  /// `min(5s * 2^attempts, 15min) + jitter`.
  Future<void> _backoff(
    Database source,
    List<OutboxRecord> failed,
    String error,
  ) async {
    final random = Random();
    await source.transaction((txn) async {
      for (final record in failed) {
        final nextAttempts = record.attempts + 1;
        final baseDelay = Duration(seconds: 5 * pow(2, nextAttempts).toInt());
        final capped = baseDelay > const Duration(minutes: 15)
            ? const Duration(minutes: 15)
            : baseDelay;
        final jitterMs = random.nextInt(1000);
        final nextAttemptAt = DateTime.now().add(
          capped + Duration(milliseconds: jitterMs),
        );
        await txn.update(
          'sync_outbox',
          {
            'attempts': nextAttempts,
            'last_error': error,
            'next_attempt_at': nextAttemptAt.toIso8601String(),
            'updated_at': DateTime.now().toIso8601String(),
          },
          where: 'id = ?',
          whereArgs: [record.id],
        );
      }
    });
  }

  Future<void> _updatePendingCount(List<Database> sources) async {
    var total = 0;
    for (final source in sources) {
      final result = await source.rawQuery(
        'SELECT COUNT(*) AS c FROM sync_outbox',
      );
      total += (result.first['c'] as num).toInt();
    }
    pendingCount.value = total;
  }
}
