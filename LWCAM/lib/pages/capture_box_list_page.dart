// Box list screen of the capture app (LWCAM, first stage of the pipeline:
// capture app -> LWIP -> QC -> Upload). Shows the capture boxes of the signed-in
// operator with their transfer state and any QC rework badge, and routes each
// tap: open a box for capture, open a transferred box read-only, or open a box
// QC sent back into rework mode on the gallery page.
// Things to know before editing: this page registers BoxSessionController as
// permanent, and that registration is the signal the gallery page uses to
// switch into box mode; a damaged device database is recovered here before the
// list loads.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../auth/auth_controller.dart';
import '../controllers/box_session_controller.dart';
import '../controllers/transfer_controller.dart';
import '../db/upload_stats_db.dart';
import '../models/capture_box_models.dart';
import '../services/open_rework_cache.dart';
import '../services/snackbar_service.dart';
import '../services/transfer_queue_service.dart';
import '../services/sync_service.dart';
import '../theme/app_colors.dart';
import '../widgets/sync_warning_banner.dart';
import '../widgets/transfer_queue_banner.dart';
import 'box_transfer_flow.dart';
import 'folder_metadata_form_page.dart';
import 'transferred_box_view_page.dart';

/// Normal-Mode landing when metadata keying is ON: the list of capture groups
/// (mirrors the Rework box-list pattern). "New Group" → group-details prompt →
/// metadata form for folder 1 → capture page. Registers BoxSessionController
/// permanent — that registration is the box-mode signal the gallery checks.
class CaptureBoxListPage extends StatefulWidget {
  const CaptureBoxListPage({super.key});

  @override
  State<CaptureBoxListPage> createState() => _CaptureBoxListPageState();
}

class _CaptureBoxListPageState extends State<CaptureBoxListPage> {
  late final AuthController auth = Get.isRegistered<AuthController>()
      ? Get.find<AuthController>()
      : Get.put(AuthController(), permanent: true);

  late final BoxSessionController session =
      Get.isRegistered<BoxSessionController>()
      ? Get.find<BoxSessionController>()
      : Get.put(BoxSessionController(auth), permanent: true);

  late final TransferQueueService queue =
      Get.isRegistered<TransferQueueService>()
      ? Get.find<TransferQueueService>()
      : Get.put(TransferQueueService(session), permanent: true);

  /// App-bar filter: hide boxes that are done AND have no rework. Session-only
  /// on purpose — see the toggle's comment.
  final RxBool _hideCompleted = false.obs;

  @override
  void initState() {
    super.initState();
    unawaited(_loadWithDatabaseRecovery());
  }

  Future<void> _loadWithDatabaseRecovery() async {
    final db = UploadStatsDB();
    final health = await db.inspectDeviceDatabase(session.deviceId);

    // A missing file is the normal first-launch state — let SQLite create it.
    // Offering to "recover capture history" to a brand-new station is just
    // confusing, and there is nothing to lose by loading normally: if the
    // operator genuinely has cloud history, the Recover action in the app bar
    // is still there.
    if (health == DeviceDatabaseHealth.healthy ||
        health == DeviceDatabaseHealth.missing) {
      await session.loadBoxes();
      // loadBoxes swallows its own errors, so a DB that passes inspection but
      // fails the real queries would otherwise render as an empty list.
      final failure = session.loadError.value;
      if (failure != null && mounted) {
        await _showDatabaseRecoveryMessage(
          'Could not load your capture groups. Your data has not been changed '
          '— close and reopen Group Mode to try again.\n\n$failure',
        );
      }
      return;
    }

    if (health == DeviceDatabaseHealth.unavailable) {
      // Busy/locked/IO — transient. Never grounds to rebuild.
      await session.loadBoxes();
      if (mounted) {
        await _showDatabaseRecoveryMessage(
          'The capture database is busy and could not be opened right now — '
          'this usually means a transfer is still running. Your data is '
          'intact. Try again in a moment.',
        );
      }
      return;
    }

    final sync = Get.isRegistered<SyncService>()
        ? Get.find<SyncService>()
        : null;
    if (sync == null) {
      if (mounted) {
        await _showDatabaseRecoveryMessage(
          'The local capture database is damaged. PostgreSQL sync is not enabled, so it cannot be rebuilt yet.',
        );
      }
      return;
    }

    if (!mounted) return;
    final recover = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Recover capture history?'),
        content: const Text(
          'The local database is damaged.\n\n'
          'Rebuilding restores your groups, folders and images from '
          'PostgreSQL, and carries over anything held only on this PC that '
          'can still be read (queued cloud updates, recapture history, past '
          'transfer records).\n\n'
          'Anything unreadable in the damaged file cannot be recovered. The '
          'damaged file is kept beside the database as a .corrupt- backup.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Recover'),
          ),
        ],
      ),
    );
    if (recover != true) return;

    // Sync ticks on this isolate and reopens EVERY device's DB file every
    // 30s. The DB layer refuses reopens mid-promotion anyway, but quiescing
    // it keeps that a backstop rather than the only line of defence.
    sync.paused = true;
    try {
      await db.rebuildFromCaptureSnapshot(
        deviceId: session.deviceId,
        pull: sync.pullCaptureSnapshot,
        // Only the `corrupt` branch reaches here now, and replacing a damaged
        // file with an empty pull would trade one loss for a worse one.
        requireNonEmpty: true,
      );
      await session.loadBoxes();
    } catch (e) {
      if (mounted) {
        await _showDatabaseRecoveryMessage(
          'Recovery failed. No local data was replaced.\n\n$e',
        );
      }
    } finally {
      sync.paused = false;
    }
  }

  Future<void> _showDatabaseRecoveryMessage(String message) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Capture database unavailable'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  // ── New Group flow: details prompt → folder-1 metadata form → capture ───────

  Future<void> _newBox() async {
    // Pick up a template edited on another PC since login — runs while the
    // operator types the box details, awaited before the metadata form.
    final templateRefresh = session.refreshActiveProjectTemplate();
    final detailsCtl = TextEditingController();
    final details = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('New Group'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: detailsCtl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Group Details',
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    error!,
                    style: TextStyle(color: Get.theme.colorScheme.error),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  final name = detailsCtl.text.trim();
                  if (name.isEmpty) {
                    setState(() => error = 'Group Details cannot be empty.');
                    return;
                  }
                  // Reject duplicates HERE, before the operator keys a whole
                  // metadata form only to have createBox throw at the end.
                  if (session.boxNameExists(name)) {
                    setState(
                      () => error =
                          'A group named "$name" already exists in this project.',
                    );
                    return;
                  }
                  Navigator.of(ctx).pop(name);
                },
                child: const Text('Next'),
              ),
            ],
          ),
        );
      },
    );
    if (details == null || details.isEmpty) return;

    await templateRefresh;
    // Folder 1 metadata (a draft is acceptable — completeness gates transfer).
    // The box doesn't exist yet, so this reads the project's LIVE template —
    // session.createBox (below) snapshots that same template into the box
    // moments later, so the two stay consistent.
    final draft = await Get.dialog<CaptureFolder>(
      FolderMetadataDialog(
        initial: const CaptureFolder(boxId: 0),
        heading: 'Folder 1 metadata',
        boxDetails: details,
        template: session.liveProjectTemplate,
      ),
      barrierDismissible: false,
    );
    if (draft == null) return; // cancelled — no box created

    try {
      final box = await session.createBox(details);
      await session.openBox(box);
      // The draft was keyed before the box existed, so it carries boxId 0.
      // Re-home it with copyWith rather than rebuilding field by field: the
      // hand-listed version omitted recordType, so a Record Type keyed on
      // folder 1 was thrown away and the folder opened as a draft "missing:
      // Record Type" until the operator edited and saved it again.
      await session.createFolder(draft.copyWith(boxId: box.id));
      await Get.toNamed('/gallery');
      // Back from the gallery — clear active state and refresh counts.
      session.closeActiveBox();
    } catch (e) {
      showAppSnackBar(
        'Error',
        '$e',
        backgroundColor: Get.theme.colorScheme.error,
        colorText: Get.theme.colorScheme.onError,
        width: kCompactSnackBarWidth,
      );
    }
  }

  /// Opens a box in the capture page. [startInQc] jumps straight to the QC
  /// review view (used by the per-row Transfer button); otherwise it opens in
  /// Capture view.
  Future<void> _openBox(CaptureBoxEntry entry, {bool startInQc = false}) async {
    // A box QC sent images back for opens the CAPTURE page in rework mode:
    // recapturing needs the phone mirror, the shutter and the image grid, none
    // of which the read-only view has. The box stays TRANSFERRED throughout —
    // rework never reopens it as a capture session.
    if (entry.needsRework) {
      session.startInReworkWith = OpenReworkCache.instance.itemsForBox(
        entry.box.projectKey,
        entry.box.boxDetails,
      );
      session.startInQcView = false;
      await session.openBox(entry.box);
      await Get.toNamed('/gallery');
      session.closeActiveBox();
      // A submit closes requests, so re-read the worklist — otherwise the tile
      // keeps its orange badge until the next manual Refresh.
      await session.loadBoxes();
      return;
    }
    if (entry.box.isTransferred) {
      await Get.to(() => TransferredBoxViewPage(entry.box));
      return;
    }
    if (queue.isBoxQueuedOrRunning(entry.box.id)) {
      showAppSnackBar(
        'This group is transferring',
        'It will reopen once the background transfer finishes.',
        backgroundColor: Get.theme.extension<LifewoodColors>()!.warning,
        colorText: Get.theme.extension<LifewoodColors>()!.onWarning,
        width: kCompactSnackBarWidth,
      );
      return;
    }
    session.startInQcView = startInQc;
    // Never inherit a stale rework list into a normal capture session — that
    // mode suppresses the live shutter.
    session.startInReworkWith = const [];
    await session.openBox(entry.box);
    await Get.toNamed('/gallery');
    session.closeActiveBox();
  }

  /// Corrects a box's details (e.g. a typo keyed at creation). Only offered on
  /// open boxes; the box name is applied to every folder's destination path at
  /// transfer, so this single edit fixes them all.
  Future<void> _renameBox(CaptureBoxEntry entry) async {
    final ctl = TextEditingController(text: entry.box.boxDetails);
    final newDetails = await showDialog<String>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('Edit group details'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: ctl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Group Details',
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    error!,
                    style: TextStyle(color: Get.theme.colorScheme.error),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  if (ctl.text.trim().isEmpty) {
                    setState(() => error = 'Group Details cannot be empty.');
                    return;
                  }
                  Navigator.of(ctx).pop(ctl.text.trim());
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
    if (newDetails == null || newDetails == entry.box.boxDetails) return;
    try {
      await session.renameBox(entry.box, newDetails);
      showAppSnackBar(
        'Saved',
        'Group details updated.',
        backgroundColor: Get.theme.extension<LifewoodColors>()!.success,
        colorText: Get.theme.extension<LifewoodColors>()!.onSuccess,
      );
    } catch (e) {
      showAppSnackBar(
        'Error',
        '$e',
        backgroundColor: Get.theme.colorScheme.error,
        colorText: Get.theme.colorScheme.onError,
      );
    }
  }

  /// Removes a box that has nothing in it — a box keyed by mistake, or one
  /// abandoned before the first capture. Only offered at 0 images; the
  /// controller re-checks, so a race with a capture still refuses.
  Future<void> _deleteBox(CaptureBoxEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete group'),
        content: Text(
          'Delete "${entry.box.boxDetails}"? It has no images. '
          '${entry.folderCount == 0 ? '' : 'Its ${entry.folderCount} folder(s) and their metadata are removed too. '}'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await session.deleteBox(entry.box);
      showAppSnackBar(
        'Deleted',
        'Box "${entry.box.boxDetails}" removed.',
        backgroundColor: Get.theme.extension<LifewoodColors>()!.success,
        colorText: Get.theme.extension<LifewoodColors>()!.onSuccess,
      );
    } catch (e) {
      showAppSnackBar(
        'Error',
        '$e',
        backgroundColor: Get.theme.colorScheme.error,
        colorText: Get.theme.colorScheme.onError,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Obx(() {
          final project = auth.activeProject.value;
          // Show the active project as "<Name> · <ID>"; fall back to the page
          // name only if somehow no project is set (shouldn't happen in box mode).
          final text = project == null
              ? 'Capture Groups'
              : '${project.name} · ${project.projectId}';
          return Text(text, overflow: TextOverflow.ellipsis);
        }),
        actions: [
          // Completed groups accumulate forever; hiding them keeps the groups an
          // operator can still act on (rework + in-progress) in view. Rework
          // groups are never hidden — they ARE completed groups. Session-only, like
          // the gallery's includeUploaded filter: LWCAM has no Settings UI.
          Obx(() {
            final hiding = _hideCompleted.value;
            return IconButton(
              icon: Icon(
                hiding
                    ? Icons.visibility_off_outlined
                    : Icons.visibility_outlined,
              ),
              tooltip: hiding ? 'Show completed groups' : 'Hide completed groups',
              onPressed: () => _hideCompleted.value = !hiding,
            );
          }),
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: session.loadBoxes,
          ),
          PopupMenuButton<String>(
            tooltip: 'More options',
            onSelected: (value) {
              if (value == 'logout') {
                _confirmLogout();
              }
            },
            // No Settings entry: station configuration is SuperAdmin-only,
            // managed from LWCam Admin.
            itemBuilder: (context) {
              return [
                const PopupMenuItem(
                  value: 'logout',
                  child: ListTile(
                    leading: Icon(Icons.logout),
                    title: Text('Logout'),
                  ),
                ),
              ];
            },
          ),
        ],
      ),
      body: Column(
        children: [
          const SyncWarningBanner(),
          const TransferQueueBanner(),
          // "New Group" lives in the body Stack (not the Scaffold FAB slot) so
          // the compact snackbar — which Flutter otherwise lifts to clear a
          // Scaffold FAB — stays at the bottom on the same row as the button.
          Expanded(
            child: Stack(
              children: [
                Obx(() {
                  if (session.isLoading.value) {
                    return const Center(child: CircularProgressIndicator());
                  }
                  if (session.boxes.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.inventory_2_outlined,
                            size: 56,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                          const SizedBox(height: 12),
                          const Text(
                            'No groups yet. Tap "New Group" to start capturing.',
                          ),
                        ],
                      ),
                    );
                  }
                  // Already sorted rework → in-progress → completed by
                  // sortBoxEntries (see BoxSessionController.loadBoxes).
                  final visible = _hideCompleted.value
                      ? session.boxes
                            .where((e) => !e.box.isTransferred || e.needsRework)
                            .toList()
                      : session.boxes.toList();
                  if (visible.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.visibility_off_outlined,
                            size: 56,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                          const SizedBox(height: 12),
                          const Text('Every group here is completed and hidden.'),
                        ],
                      ),
                    );
                  }
                  return RefreshIndicator(
                    onRefresh: session.loadBoxes,
                    child: ListView.builder(
                      padding: const EdgeInsets.only(top: 8, bottom: 96),
                      itemCount: visible.length,
                      itemBuilder: (context, i) => _boxTile(visible[i]),
                    ),
                  );
                }),
                Positioned(
                  right: 16,
                  bottom: 16,
                  child: FloatingActionButton.extended(
                    heroTag: 'boxesFab',
                    onPressed: _newBox,
                    icon: const Icon(Icons.add_box_outlined),
                    label: const Text('New Group'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Human label for a persisted [CaptureBox.lastTransferState]. 'running'
  /// only survives in the DB when the app died mid-transfer (a live run's
  /// state is superseded by the in-memory job) — render it as interrupted.
  static String _persistedStateLabel(String state) => switch (state) {
    'running' => 'Interrupted — transfer was cut off',
    'partial' => 'Partially transferred',
    _ => 'Transfer failed',
  };

  Widget _boxTile(CaptureBoxEntry entry) {
    final box = entry.box;
    final transferred = box.isTransferred;
    // A rework box IS transferred — QC sent images back, the box was never
    // reopened (see TransferredBoxViewPage's rework mode). It outranks the green
    // tick everywhere below so the operator sees work to do, not "done".
    final needsRework = entry.needsRework;
    final ready =
        !transferred && entry.folderCount > 0 && entry.allFoldersComplete;
    return Obx(() {
      final job = queue.queue.firstWhereOrNull((j) => j.box.id == box.id);
      final isQueued = job?.state.value == BoxTransferJobState.queued;
      final isRunning =
          job != null &&
          job.state.value != BoxTransferJobState.queued &&
          job.isActive;
      final isWaiting =
          job?.state.value == BoxTransferJobState.waitingForDestination;
      // Persisted outcome of the last transfer attempt (survives restart) —
      // only meaningful when no live job supersedes it and the box never
      // fully transferred.
      final needsAttention =
          job == null && !transferred && box.lastTransferState != null;
      // One shared engine, one job at a time (see TransferQueueService._run),
      // so the engine's overall fraction IS this box's fraction.
      final progress = isRunning && Get.isRegistered<TransferController>()
          ? Get.find<TransferController>().progress.value
          : null;
      final cs = Theme.of(context).colorScheme;
      final lw = LifewoodColors.of(context);
      // Ready-to-transfer (truck) is Earth Yellow with a black icon — user
      // feedback: the green-on-green avatar didn't stand out in the list.
      final (avatarBg, avatarFg) = needsRework
          ? (lw.warning, lw.onWarning)
          : transferred
          ? (lw.success, lw.onSuccess)
          : (isRunning || isQueued
                ? (lw.info, lw.onInfo)
                : (needsAttention
                      ? (cs.error, cs.onError)
                      : (ready
                            ? (AppColors.earthYellow, Colors.black)
                            : (cs.outline, cs.surface))));
      final countsText =
          '${entry.folderCount} folders · ${entry.imageCount} images';
      return Card(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: ListTile(
          leading: CircleAvatar(
            backgroundColor: avatarBg,
            child: (isRunning || isQueued)
                ? SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: avatarFg,
                    ),
                  )
                : Icon(
                    needsRework
                        ? Icons.replay
                        : transferred
                        ? Icons.check
                        : (needsAttention
                              ? Icons.error_outline
                              : (ready
                                    ? Icons.local_shipping_outlined
                                    : Icons.inventory_2_outlined)),
                    color: avatarFg,
                  ),
          ),
          title: Text(
            box.boxDetails.isEmpty ? '(no group details)' : box.boxDetails,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          subtitle: isRunning
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      isWaiting
                          ? 'Waiting for destination… · $countsText'
                          : 'Transferring'
                                '${progress != null ? ' ${(progress * 100).toStringAsFixed(0)}%' : '…'}'
                                ' · $countsText',
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: isWaiting ? null : progress,
                      minHeight: 4,
                    ),
                  ],
                )
              : Text(
                  isQueued
                      ? 'Queued for transfer · $countsText'
                      : needsRework
                      ? 'Needs Rework — ${entry.reworkCount} '
                            'image${entry.reworkCount == 1 ? '' : 's'} '
                            'sent back by QC · $countsText'
                      : transferred
                      ? 'Transferred · $countsText'
                      : needsAttention
                      ? '${_persistedStateLabel(box.lastTransferState!)}'
                            '${(box.lastTransferError ?? '').isNotEmpty ? ' · ${box.lastTransferError}' : ''}'
                            ' · $countsText'
                      : '$countsText'
                            '${entry.folderCount > 0 && !entry.allFoldersComplete ? ' · metadata incomplete' : ''}',
                  style: needsRework
                      ? TextStyle(
                          color: lw.warning,
                          fontWeight: FontWeight.w600,
                        )
                      : needsAttention
                      ? TextStyle(color: cs.error)
                      : null,
                ),
          trailing: isQueued
              ? TextButton(
                  onPressed: () => queue.cancelQueued(box.id),
                  child: const Text('Cancel'),
                )
              : isRunning
              ? null
              : needsRework
              ? FilledButton.icon(
                  onPressed: () => _openBox(entry),
                  style: FilledButton.styleFrom(
                    backgroundColor: lw.warning,
                    foregroundColor: lw.onWarning,
                  ),
                  icon: const Icon(Icons.replay, size: 16),
                  label: const Text('Rework'),
                )
              : transferred
              ? TextButton.icon(
                  onPressed: () => _openBox(entry),
                  icon: const Icon(Icons.visibility_outlined, size: 16),
                  label: const Text('View', style: TextStyle(fontSize: 12)),
                )
              : needsAttention
              ? FilledButton.icon(
                  onPressed: () => _retryTransfer(entry),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry'),
                )
              // No per-row Review shortcut — operators open the box
              // and use its "Review & Transfer" button instead.
              : PopupMenuButton<String>(
                  tooltip: 'Group options',
                  onSelected: (v) {
                    if (v == 'edit') _renameBox(entry);
                    if (v == 'delete') _deleteBox(entry);
                  },
                  itemBuilder: (ctx) => [
                    const PopupMenuItem(
                      value: 'edit',
                      child: Text('Edit group details…'),
                    ),
                    // Shown greyed rather than hidden once images exist, so
                    // the rule ("empty boxes only") is visible where it bites.
                    PopupMenuItem(
                      value: 'delete',
                      enabled: entry.imageCount == 0,
                      child: Text(
                        entry.imageCount == 0
                            ? 'Delete group…'
                            : 'Delete group (has images)',
                        style: entry.imageCount == 0
                            ? TextStyle(color: Theme.of(ctx).colorScheme.error)
                            : null,
                      ),
                    ),
                  ],
                ),
          onTap: (isQueued || isRunning) ? null : () => _openBox(entry),
        ),
      );
    });
  }

  /// Retry from the box list: reuses the full transfer flow (gate → plan →
  /// confirm → stage → enqueue). Already-copied images are skipped by the
  /// plan's DB check, so a partial/interrupted box only re-copies what's
  /// missing. Requires the phone if any image isn't in the durable local
  /// store — the flow surfaces that itself.
  Future<void> _retryTransfer(CaptureBoxEntry entry) async {
    await runBoxTransferFlow(
      context: context,
      session: session,
      box: entry.box,
      folderCount: entry.folderCount,
    );
  }

  Future<void> _confirmLogout() async {
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Logout'),
        content: const Text('Are you sure you want to log out?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );
    if (shouldLogout == true) {
      await auth.logout();
    }
  }
}
