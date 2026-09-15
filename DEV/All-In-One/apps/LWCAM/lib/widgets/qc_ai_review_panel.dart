import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/qc_ai_review_controller.dart';
import 'qc_ai_review_dialog.dart';
import '../models/qc_ai_review.dart';

/// Shows what the AI review found and lets the reviewer take the parts of it
/// they agree with.
///
/// Deliberately not a verdict screen. The engine reads the pages and reports;
/// the reviewer decides. So findings it cannot stand behind are shown as
/// information with no checkbox rather than hidden, and nothing is written until
/// the reviewer ticks something and presses Apply.
///
/// Model names, endpoints and timings are not shown - those are Admin's
/// business, and none of them change what the reviewer should do next.
class QcAiReviewPanel extends StatelessWidget {
  const QcAiReviewPanel({super.key, required this.controller});

  final QcAiReviewController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final scheme = Theme.of(context).colorScheme;

      if (!controller.review.canEdit) {
        return const _Note('Claim this task to run an AI review.');
      }
      if (controller.disabled.value) {
        return const _Note(
          'AI review is switched off for this station. It can be turned on in '
          'LWCam Admin.',
        );
      }

      final job = controller.job.value;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(controller: controller),
          if (controller.error.value.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                controller.error.value,
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
          Expanded(
            child: job == null
                ? const _Note(
                    'No AI review yet. Run one to compare the keyed metadata '
                    'against what the pages show.',
                  )
                : QcAiReviewFindings(
                    controller: controller,
                    job: job,
                    onEvidenceTap: controller.review.showImageById,
                  ),
          ),
          if (controller.appliable.isNotEmpty && !controller.isStale)
            QcAiReviewApplyBar(controller: controller),
        ],
      );
    });
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller});

  final QcAiReviewController controller;

  @override
  // Its own Obx. The panel's Obx closure never reads `starting`, and this
  // widget's build runs outside that closure, so pressing Run left the button
  // reading "Run" and still enabled until the job arrived - long enough to press
  // it twice.
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final job = controller.job.value;
    final running = job?.isRunning ?? false;

    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                  'AI review',
                  // Bold in both themes: this header names the panel, and at
                  // titleSmall's 12px it read as a caption rather than a heading.
                  style: Theme.of(context)
                      .textTheme
                      .titleSmall
                      ?.copyWith(fontWeight: FontWeight.w700),
                ),
              const SizedBox(width: 8),
              if (job != null && job.trigger == 'preanalysis' && !running)
                Tooltip(
                  message: 'Run automatically before you opened this folder',
                  child: Icon(Icons.schedule,
                      size: 14, color: scheme.onSurfaceVariant),
                ),
              const Spacer(),
              // The findings are shown in a window when they arrive; this is how
              // the reviewer gets that window back after closing it, without
              // re-running anything.
              if (job?.result != null)
                IconButton(
                  tooltip: 'Open the findings in a window',
                  icon: const Icon(Icons.open_in_full, size: 18),
                  onPressed: () =>
                      QcAiReviewDialog.show(context, controller),
                ),
              FilledButton.tonal(
                onPressed: running || controller.starting.value
                    ? null
                    : () => _run(context),
                child: Text(
                  controller.starting.value
                      ? 'Starting…'
                      : job == null
                          ? 'Run'
                          : 'Run again',
                ),
              ),
            ],
          ),
          if (running) ...[
            const SizedBox(height: 8),
            QcAiReviewProgress(controller: controller, job: job!),
          ],
          if (job != null && !running && controller.isStale)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'The folder changed after this review ran, so its findings no '
                'longer describe what is on screen. Run it again.',
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
          if (job?.status == 'failed')
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                job?.error ?? 'The AI review failed.',
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _run(BuildContext context) async {
    // Re-running over findings that still match the folder throws them away,
    // including any the reviewer was part-way through acting on.
    if (controller.wouldDiscardResult) {
      final ok = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Run the review again?'),
          content: const Text(
            'The current findings still match this folder. Running again '
            'replaces them.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Keep'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Run again'),
            ),
          ],
        ),
      );
      if (!(ok ?? false)) return;
    }
    await controller.start();
  }
}

/// Progress bar and stage line for a running review. Shared with the analysing
/// gate on the review page so both describe a job the same way.
///
/// Deliberately has no Obx of its own: everything it reads comes off
/// `job.value`, and every host - the panel, the dialog, the gate - watches that.
/// Nothing here can change without its host rebuilding first.
class QcAiReviewProgress extends StatelessWidget {
  const QcAiReviewProgress({
    super.key,
    required this.controller,
    required this.job,
  });

  final QcAiReviewController controller;
  final QcAiReviewJob job;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final stage = controller.stage;
    final total = job.totalImages;
    final done = job.processedImages;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        LinearProgressIndicator(
          // Queued and comparing have nothing to count, so they run
          // indeterminate rather than sitting at a misleading zero.
          value: stage == 'extracting' && total > 0 ? done / total : null,
          minHeight: 3,
        ),
        const SizedBox(height: 6),
        Text(
          switch (stage) {
            'queued' => 'Waiting to start…',
            'extracting' =>
              total > 0 ? 'Reading pages ($done of $total)…' : 'Reading pages…',
            'comparing' => 'Comparing against the metadata…',
            _ => 'Working…',
          },
          style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
        ),
      ],
    );
  }
}

/// The findings themselves: the overall verdict, then a card per field.
///
/// Shared by the inline panel and the findings dialog so the two can never drift
/// apart. Returns a ListView, so whoever hosts it must give it a BOUNDED height
/// - see the comment on the panel's split in qc_review_page.dart.
///
/// No Obx of its own, for the same reason as [QcAiReviewProgress]: `appliable`,
/// `advisory` and `isStale` all derive from `job.value`, which every host reads.
/// The per-finding checkboxes are a different matter and _FieldCard owns that.
class QcAiReviewFindings extends StatelessWidget {
  const QcAiReviewFindings({
    super.key,
    required this.controller,
    required this.job,
    this.onEvidenceTap,
  });

  final QcAiReviewController controller;
  final QcAiReviewJob job;

  /// Called with an evidence line's image id. When null the evidence is plain
  /// text; the dialog passes a callback that closes itself and moves the viewer.
  final ValueChanged<int>? onEvidenceTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final result = job.result;

    if (job.isRunning) {
      return const _Note('The review is running. Findings appear as it works.');
    }
    if (job.status == 'cancelled') {
      return _Note(job.cancelReason ?? 'The review was cancelled.');
    }
    if (result == null) {
      return const _Note('This review produced no findings.');
    }

    final appliable = controller.appliable;
    final advisory = controller.advisory;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      children: [
        _Overall(status: result.overallStatus),
        if (appliable.isEmpty && advisory.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              'Nothing to report against the current metadata.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ),
        if (appliable.isNotEmpty) ...[
          const SizedBox(height: 12),
          _SectionLabel(
            controller.isStale ? 'Suggestions (out of date)' : 'Suggestions',
          ),
          for (final field in appliable)
            _FieldCard(
              controller: controller,
              field: field,
              selectable: !controller.isStale,
              alreadyApplied: result.acceptedFields.contains(field.key),
              onEvidenceTap: onEvidenceTap,
            ),
        ],
        if (advisory.isNotEmpty) ...[
          const SizedBox(height: 16),
          const _SectionLabel('Also noted'),
          for (final field in advisory)
            _FieldCard(
              controller: controller,
              field: field,
              selectable: false,
              alreadyApplied: result.acceptedFields.contains(field.key),
              onEvidenceTap: onEvidenceTap,
            ),
        ],
      ],
    );
  }
}

class _Overall extends StatelessWidget {
  const _Overall({required this.status});

  final String status;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (text, icon, color) = switch (status) {
      'consistent' => (
          'The metadata matches what the pages show.',
          Icons.check_circle_outline,
          scheme.primary,
        ),
      'needs_review' => (
          'Some fields disagree with the pages.',
          Icons.error_outline,
          scheme.error,
        ),
      _ => (
          'The pages did not show enough to judge the metadata.',
          Icons.help_outline,
          scheme.onSurfaceVariant,
        ),
    };

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
      ],
    );
  }
}

class _FieldCard extends StatelessWidget {
  const _FieldCard({
    required this.controller,
    required this.field,
    required this.selectable,
    required this.alreadyApplied,
    this.onEvidenceTap,
  });

  final QcAiReviewController controller;
  final QcAiReviewField field;
  final bool selectable;
  final bool alreadyApplied;
  final ValueChanged<int>? onEvidenceTap;

  // Its own Obx. The panel's Obx closure never reads `selected`, and this
  // widget's build runs outside that closure anyway - so ticking a finding
  // repainted nothing: the checkbox stayed empty and the Apply count stayed at
  // zero. Same trap as the metadata form and the page strip before it.
  @override
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final ticked = controller.selected.contains(field.key);

    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 12, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                if (selectable)
                  Checkbox(
                    value: ticked,
                    onChanged: controller.applying.value
                        ? null
                        : (v) => controller.toggle(field.key, v ?? false),
                  )
                else
                  const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    field.key,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                _VerdictChip(field: field),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 12, top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (alreadyApplied)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        'Already taken from this review',
                        style: TextStyle(fontSize: 11, color: scheme.primary),
                      ),
                    ),
                  _Value(label: 'Keyed', value: field.currentValue),
                  if (field.suggestedValue?.isNotEmpty ?? false)
                    _Value(label: 'Pages show', value: field.suggestedValue),
                  // What it saw, and on which page - the reviewer can go and
                  // look rather than take the finding on trust.
                  for (final evidence in field.evidence)
                    _Evidence(
                      evidence: evidence,
                      onTap: onEvidenceTap == null
                          ? null
                          : () => onEvidenceTap!(evidence.imageId),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One observation, and the page it came from.
///
/// Tappable where the host offers somewhere to go: checking a finding means
/// looking at the scan, and hunting for the filename in the rail by hand is the
/// slow way to do that.
class _Evidence extends StatelessWidget {
  const _Evidence({required this.evidence, this.onTap});

  final QcAiReviewEvidence evidence;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Text(
      '${evidence.filename}: ${evidence.observation}',
      style: TextStyle(
        fontSize: 11,
        color: onTap == null ? scheme.onSurfaceVariant : scheme.primary,
      ),
    );
    if (onTap == null) {
      return Padding(padding: const EdgeInsets.only(top: 6), child: text);
    }
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: text,
        ),
      ),
    );
  }
}

class _Value extends StatelessWidget {
  const _Value({required this.label, required this.value});

  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: RichText(
        text: TextSpan(
          style: DefaultTextStyle.of(context).style.copyWith(fontSize: 12),
          children: [
            TextSpan(
              text: '$label: ',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            TextSpan(text: (value?.isEmpty ?? true) ? '—' : value),
          ],
        ),
      ),
    );
  }
}

class _VerdictChip extends StatelessWidget {
  const _VerdictChip({required this.field});

  final QcAiReviewField field;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (label, color) = switch (field.verdict) {
      'match' => ('agrees', scheme.primary),
      'mismatch' => ('differs', scheme.error),
      'not_visible' => ('not on the pages', scheme.onSurfaceVariant),
      _ => ('unsure', scheme.onSurfaceVariant),
    };

    return Tooltip(
      // Confidence is the engine's own bar for what may be applied, so it is
      // worth showing rather than hiding behind a colour.
      message: 'Confidence ${(field.confidence * 100).round()}%',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(label, style: TextStyle(fontSize: 11, color: color)),
      ),
    );
  }
}

/// The "n of m selected" row and the Apply button, with every disabled rule that
/// goes with them. Shared by the panel and the dialog.
class QcAiReviewApplyBar extends StatelessWidget {
  const QcAiReviewApplyBar({
    super.key,
    required this.controller,
    this.onApplied,
  });

  final QcAiReviewController controller;

  /// Called only when an apply SUCCEEDS. The dialog closes itself on that; the
  /// inline panel has nowhere to go and passes nothing. A failure deliberately
  /// does not fire it - `controller.error` is what the operator needs to see,
  /// and it cannot be read on a surface that has just closed.
  final VoidCallback? onApplied;

  // Its own Obx, for the same reason as _FieldCard: the selection count and the
  // Apply button both depend on `selected`, which no enclosing Obx reads.
  @override
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = controller.selected.length;
    final total = controller.appliable.length;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: controller.applying.value
                ? null
                : count == total
                    ? controller.clearSelection
                    : controller.selectAll,
            child: Text(count == total ? 'Clear' : 'Select all'),
          ),
          const Spacer(),
          Text(
            '$count of $total',
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(width: 8),
          FilledButton(
            onPressed: count == 0 || controller.applying.value
                ? null
                : () async {
                    if (await controller.apply()) onApplied?.call();
                  },
            child: Text(controller.applying.value ? 'Applying…' : 'Apply'),
          ),
        ],
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
}

class _Note extends StatelessWidget {
  const _Note(this.text);

  final String text;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ),
      );
}
