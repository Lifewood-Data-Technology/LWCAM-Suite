import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../auth/auth_controller.dart';
import '../controllers/qc_controller.dart';
import '../models/project.dart';
import '../models/qc_task.dart';
import '../services/qc_engine_service.dart';
import 'qc_review_page.dart';
import '../theme/app_colors.dart';

/// QC task queue.
///
/// Sign in, see the queue, take or give back a task, and open one to look at its
/// pages. The editing half — image tools, metadata form, drafts, AI panel — is
/// still the web console and is being ported next.
class QcHomePage extends StatelessWidget {
  const QcHomePage({super.key, this.project});

  /// When set, only this project's tasks are listed.
  ///
  /// Optional because a QC-only account holding exactly ONE project skips the
  /// chooser and is routed here straight from login; every other route in
  /// comes through ProjectAreaPage, which always supplies it.
  final Project? project;

  @override
  Widget build(BuildContext context) {
    final auth = Get.find<AuthController>();
    final controller = Get.put(QcController());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Quality Check'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: controller.refreshAll,
          ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: auth.logout,
          ),
        ],
      ),
      body: Obx(() {
        if (!controller.engineUp.value && !controller.loading.value) {
          return _EngineDown(onRetry: controller.refreshAll);
        }
        return Column(
          children: [
            _ScopeBar(controller: controller),
            if (controller.loading.value) const LinearProgressIndicator(),
            if (controller.error.value.isNotEmpty)
              _ErrorBanner(message: controller.error.value),
            Expanded(
              child: _TaskList(controller: controller, project: project),
            ),
          ],
        );
      }),
    );
  }
}

/// Opens the review screen, then keeps handing the operator their next task.
///
/// The ONLY push site for QcReviewPage, reached from Claim, Claim next, a My-task
/// tap and the prompt below. It has to be awaited: both terminal actions pop with
/// `true` (qc_review_page.dart), and that result is the only signal the queue
/// gets that a folder is finished - the push used to be a fire-and-forget arrow
/// expression, so the result was dropped and GetX kept this controller alive with
/// `onInit` never running again, leaving the finished task on screen until
/// somebody pressed refresh.
///
/// A loop rather than recursion: an operator working through a shift would
/// otherwise nest one frame per folder reviewed.
Future<void> openQcReview(
  QcController controller, {
  required int folderId,
  required String title,
}) async {
  var nextFolderId = folderId;
  var nextTitle = title;

  while (true) {
    final finished = await Get.to<bool>(
      () => QcReviewPage(folderId: nextFolderId, title: nextTitle),
      preventDuplicates: false,
    );

    // Backed out without approving or reworking. Reload anyway - a draft may
    // have been saved - but do not offer the next task: none was finished.
    if (finished != true) {
      await controller.refreshAll();
      return;
    }

    final next = await controller.nextUpAfterCompletion();
    if (!next.hasSomething) {
      // Nothing held and nothing waiting, so there is nothing to ask about.
      await controller.setScope(QcScope.pending);
      return;
    }

    final go = await _confirmNextTask(next);
    if (go != true) {
      await controller.setScope(QcScope.pending);
      return;
    }

    // Held work first; only claim when there is none.
    final task = next.claimed ?? await controller.claimNext();
    if (task == null) {
      // Somebody else took it between the count and the claim.
      await controller.setScope(QcScope.pending);
      return;
    }
    nextFolderId = task.folderId;
    nextTitle = task.displayName;
  }
}

/// Asks whether to move on to the next task. Null/false means back to Available.
///
/// Get.dialog rather than showDialog, and NOT because of the lint: by this point
/// the list has been reloaded without the folder just reviewed, so the card whose
/// BuildContext started this is gone. Taking no context at all is the honest fix,
/// and it matches the Get.to used to push the review screen above. The AlertDialog
/// shape is the one every other QC confirmation uses - TextButton to decline,
/// FilledButton to proceed.
Future<bool?> _confirmNextTask(QcNextUp next) {
  final holding = next.claimed != null;
  return Get.dialog<bool>(
    AlertDialog(
      title: Text(holding ? 'Open your next task?' : 'Claim the next task?'),
      content: Text(
        holding
            ? 'You still have ${next.claimed!.displayName} claimed.'
            : '${next.claimableCount} folder(s) are waiting for review.',
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back(result: false),
          child: const Text('Back to Available'),
        ),
        FilledButton(
          onPressed: () => Get.back(result: true),
          child: Text(holding ? 'Open' : 'Claim next'),
        ),
      ],
    ),
  );
}

// Stateful only for the search field's TextEditingController: it has to
// outlive a rebuild, or every keystroke would reset the caret to the start.
class _ScopeBar extends StatefulWidget {
  const _ScopeBar({required this.controller});

  final QcController controller;

  @override
  State<_ScopeBar> createState() => _ScopeBarState();
}

class _ScopeBarState extends State<_ScopeBar> {
  final _searchCtl = TextEditingController();

  QcController get controller => widget.controller;

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  @override
  // Its own Obx. The page's closure reads `engineUp`/`loading`/`error`, not
  // `scope` or `total`, so this repainted only because every scope change
  // happens to be bracketed by a loading toggle. Depending on that is one
  // refactor away from a segmented control that does not move.
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    // The controller drops the term when the scope leaves Completed; the box
    // has to follow, or coming back shows an empty field over a filtered list.
    if (controller.searchQuery.value.isEmpty && _searchCtl.text.isNotEmpty) {
      _searchCtl.clear();
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          SegmentedButton<QcScope>(
            segments: [
              for (final scope in QcScope.values)
                ButtonSegment(value: scope, label: Text(scope.label)),
            ],
            selected: {controller.scope.value},
            onSelectionChanged: (selection) =>
                controller.setScope(selection.first),
          ),
          const Spacer(),
          // Completed only: the other two scopes are short working queues an
          // operator reads top to bottom, and a box that filtered nothing there
          // would just be another control to wonder about.
          if (controller.scope.value == QcScope.completed) ...[
            SizedBox(
              width: 260,
              child: TextField(
                controller: _searchCtl,
                onChanged: controller.search,
                textInputAction: TextInputAction.search,
                decoration: InputDecoration(
                  isDense: true,
                  prefixIcon: const Icon(Icons.search, size: 20),
                  hintText: 'Search Group ID or name',
                  border: const OutlineInputBorder(),
                  suffixIcon: controller.searchQuery.value.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          tooltip: 'Clear search',
                          onPressed: () {
                            _searchCtl.clear();
                            controller.search('');
                          },
                        ),
                ),
              ),
            ),
            const SizedBox(width: 12),
          ],
          Text(
            '${controller.total.value} folder(s)',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: controller.loading.value
                ? null
                : () async {
                    final claimed = await controller.claimNext();
                    if (claimed == null) return;
                    // Straight into the work. Landing on a list and hunting for
                    // the folder just claimed was the whole complaint.
                    await openQcReview(
                      controller,
                      folderId: claimed.folderId,
                      title: claimed.displayName,
                    );
                  },
            icon: const Icon(Icons.play_arrow),
            label: const Text('Claim next'),
          ),
        ],
      ),
    );
  }
}

class _TaskList extends StatelessWidget {
  const _TaskList({required this.controller, this.project});

  final Project? project;

  final QcController controller;

  @override
  // Own Obx: reads `tasks` and `scope`, neither watched by the page's closure.
  // See _ScopeBar.
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Filtered here rather than in the request: the engine's scope parameter has
    // no project dimension, and re-cutting that API would change a contract the
    // web console also speaks. Matched on projectName because that is what the
    // task payload carries (QcTask.projectName).
    final proj = project?.name;
    final visible = proj == null
        ? controller.tasks.toList()
        : controller.tasks.where((t) => t.projectName == proj).toList();
    if (visible.isEmpty) {
      if (controller.loading.value) return const SizedBox.shrink();
      // Say WHICH queue is empty when scoped, so an admin does not read
      // "nothing waiting" as "nothing waiting anywhere".
      final suffix = proj == null ? '' : ' for $proj';
      return Center(
        child: Text(
          switch (controller.scope.value) {
            QcScope.pending => 'Nothing waiting for review$suffix.',
            QcScope.mine => 'You have no task claimed$suffix.',
            QcScope.completed => 'Nothing reviewed yet$suffix.',
          },
          style: TextStyle(color: scheme.onSurfaceVariant),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      itemCount: visible.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) => _TaskCard(
        task: visible[index],
        controller: controller,
      ),
    );
  }
}

/// Confirms sending a finished folder back to QC as a client rework.
///
/// Worth a stop: an exported folder has already been delivered, and the
/// corrected package will REPLACE it in the bucket under the same Group ID.
/// The wording says which of those two situations this folder is in rather
/// than warning about both.
Future<bool> _confirmRevert(BuildContext context, QcTask task) async {
  final delivered = task.isExported && task.groupId != null;
  final answer = await Get.dialog<bool>(
    AlertDialog(
      title: const Text('Send back to QC?'),
      content: Text(
        delivered
            ? 'This folder was delivered as ${task.groupId}.\n\n'
                'It goes back to QC as a client rework and is claimed by you. '
                'When it is approved again, the corrected package REPLACES the '
                'delivered one under the same Group ID.'
            : 'This folder goes back to QC as a client rework and is claimed '
                'by you, so you can correct it now.',
      ),
      actions: [
        TextButton(
          onPressed: () => Get.back(result: false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Get.back(result: true),
          child: const Text('Send back'),
        ),
      ],
    ),
  );
  return answer ?? false;
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({required this.task, required this.controller});

  final QcTask task;
  final QcController controller;

  @override
  // Own Obx: reads `scope` and `loading`. See _ScopeBar.
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lifewood = Theme.of(context).extension<LifewoodColors>()!;
    final scopeValue = controller.scope.value;
    final mine = scopeValue == QcScope.mine;
    // The rule lives in canOpenQcTask so it can be tested on its own: this page
    // needs an AuthController and does a live engine check on build, so a widget
    // test of the card would depend on whether a QC engine happens to be running.
    final openable = canOpenQcTask(scopeValue, task);
    final completed = scopeValue == QcScope.completed;

    return Card(
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: openable
            ? () => openQcReview(
                  controller,
                  folderId: task.folderId,
                  title: task.displayName,
                )
            : null,
        child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    // In Completed the Group ID is the identifier the ingest
                    // team quotes, so it leads. It only exists once the folder
                    // has been exported, so completedIdentifier falls back to
                    // the name and the chip below says which case this is.
                    completed ? task.completedIdentifier : task.displayName,
                    // titleMedium, not titleSmall: this app defines titleSmall
                    // as 12 rather than Material's 14, so the card title was a
                    // step SMALLER than the scope tabs directly above it.
                    // titleMedium is 14, the same as the tabs' labelLarge.
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    [
                      if (task.projectName != null) task.projectName!,
                      task.boxName,
                      // The name still shows when the Group ID took the title,
                      // so a row stays recognisable to the person who keyed it.
                      if (completed && task.groupId != null) task.displayName,
                      'folder ${task.folderSeq}',
                      '${task.imageCount} image(s)',
                    ].join(' · '),
                    style: TextStyle(
                      // 13, deliberately not 14: level with the title it would
                      // cost the card its hierarchy, and this is still a clear
                      // step up from the 12 it was.
                      fontSize: 13,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    children: [
                      if (!task.imageAvailable)
                        _Chip(
                          // Two different situations, and the operator can act
                          // on only one of them. SOME pages missing is fixable
                          // in review - open it and delete or replace them.
                          // NONE readable usually means the image folder moved,
                          // and there is nothing to open.
                          label: task.anyImageAvailable
                              ? '${task.missingImageCount} image(s) missing'
                              : 'Images missing',
                          color: task.anyImageAvailable
                              ? lifewood.warning
                              : scheme.error,
                        ),
                      if (task.hasDraft)
                        _Chip(label: 'Draft saved', color: lifewood.info),
                      // Says WHY a row has or has not got a Group ID, so a
                      // fallback name reads as a stage in the pipeline rather
                      // than as data missing from the row.
                      if (completed)
                        _Chip(
                          label: task.completedState.label,
                          color: switch (task.completedState) {
                            QcCompletedState.exported => lifewood.success,
                            QcCompletedState.awaitingExport => lifewood.info,
                            QcCompletedState.sentBack => lifewood.warning,
                            QcCompletedState.reworkPendingExport =>
                              lifewood.warning,
                          },
                        ),
                      if (completed && task.clientRework)
                        _Chip(label: 'Client rework', color: lifewood.warning),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            if (mine)
              TextButton(
                onPressed: controller.loading.value
                    ? null
                    : () => controller.release(task.folderId),
                child: const Text('Release'),
              )
            else if (scopeValue == QcScope.pending)
              FilledButton(
                onPressed: controller.loading.value || !task.anyImageAvailable
                    ? null
                    : () async {
                        if (!await controller.claim(task.folderId)) return;
                        await openQcReview(
                          controller,
                          folderId: task.folderId,
                          title: task.displayName,
                        );
                      },
                child: const Text('Claim'),
              )
            // The engine answers 409 unless qc_status is PASS: a REWORK folder is
            // under capture rework, not the reviewer's to reopen.
            else if (completed && task.status.toUpperCase() == 'PASS')
              TextButton(
                onPressed: controller.loading.value
                    ? null
                    : () async {
                        if (!await _confirmRevert(context, task)) return;
                        final reopened = await controller.revert(task);
                        if (reopened == null) return;
                        // Straight into the work, like Claim next: the reason
                        // for reverting is to fix something, and the revert
                        // already claimed it for this reviewer.
                        await openQcReview(
                          controller,
                          folderId: reopened.folderId,
                          title: reopened.displayName,
                        );
                      },
                child: const Text('Send back to QC'),
              ),
          ],
        ),
        ),
      ),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, color: color),
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        message,
        style: TextStyle(color: scheme.onErrorContainer, fontSize: 12),
      ),
    );
  }
}

/// Shown when the sidecar is not answering. The engine has no console window, so
/// without this the only symptom would be an empty queue.
class _EngineDown extends StatelessWidget {
  const _EngineDown({required this.onRetry});

  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.error_outline, color: scheme.error),
                  const SizedBox(width: 10),
                  Text(
                    'QC engine is not running',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                'Review cannot run until it starts. It is usually the database '
                'being unreachable or Station Setup not completed. Details are '
                r'in %USERPROFILE%\LWCAM_DBs\qc_engine.log.',
                style: TextStyle(color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                onPressed: () async {
                  await QcEngineService.instance.ensureStarted();
                  await onRetry();
                },
                icon: const Icon(Icons.refresh),
                label: const Text('Start and check again'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
