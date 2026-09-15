import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/qc_exports_controller.dart';
import '../widgets/session_app_bar_actions.dart';

/// Admin view of the export pipeline: what the last run did, and what is still
/// broken.
///
/// Approving a folder no longer ends the story - the engine exports approved
/// folders on its own - so this screen exists to make that visible. Without it
/// an automatic export that fails is silent, and a batch simply never reaches
/// the ingest team with nothing on screen to say why.
class QcExportsPage extends StatelessWidget {
  const QcExportsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.isRegistered<QcExportsController>()
        ? Get.find<QcExportsController>()
        : Get.put(QcExportsController());

    return Scaffold(
      appBar: AppBar(
        title: const Text('Exports'),
        actions: [
          Obx(
            () => IconButton(
              tooltip: 'Refresh',
              icon: const Icon(Icons.refresh),
              onPressed: c.loading.value ? null : c.load,
            ),
          ),
          ...sessionAppBarActions(context),
        ],
      ),
      body: Obx(() {
        if (c.loading.value && c.run.value == null && c.failures.isEmpty) {
          return const Center(child: CircularProgressIndicator());
        }
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (c.error.value.isNotEmpty)
              _Banner(text: c.error.value, isError: true),
            for (final blocker in c.blockers)
              _Banner(text: blocker, isError: true),
            _RunCard(controller: c),
            const SizedBox(height: 16),
            _FailuresCard(controller: c),
            const SizedBox(height: 16),
            _UploadCard(controller: c),
          ],
        );
      }),
    );
  }
}

class _RunCard extends StatelessWidget {
  const _RunCard({required this.controller});

  final QcExportsController controller;

  @override
  // Its own Obx. The page's Obx closure reads `loading`/`run`/`failures` but
  // not `working`, and this build runs outside it - so a retry left its button
  // enabled while the request was in flight, which invites a second export of
  // the same folder.
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final run = controller.run.value;
    final items = controller.items;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  run == null ? 'No export has run yet' : _summary(run),
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (controller.isRunning)
                  const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  FilledButton.icon(
                    onPressed:
                        controller.working.value ||
                            controller.blockers.isNotEmpty
                        ? null
                        : controller.runExport,
                    icon: const Icon(Icons.play_arrow, size: 18),
                    label: const Text('Run export'),
                  ),
              ],
            ),
            if (items.isNotEmpty) const Divider(height: 24),
            for (final item in items)
              _ItemRow(item: item, controller: controller),
            if (run != null && items.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'That run exported nothing.',
                  style: TextStyle(color: scheme.onSurfaceVariant),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _summary(Map<String, Object?> run) {
    final status = run['status']?.toString() ?? '';
    final parts = <String>[
      '${run['succeeded'] ?? 0} succeeded',
      if ((run['failed'] as num? ?? 0) > 0) '${run['failed']} failed',
      if ((run['skipped'] as num? ?? 0) > 0) '${run['skipped']} skipped',
    ];
    return '$status  ·  ${parts.join('  ·  ')}';
  }
}

class _ItemRow extends StatelessWidget {
  const _ItemRow({required this.item, required this.controller});

  final Map<String, Object?> item;
  final QcExportsController controller;

  @override
  // Own Obx: reads `working`, which no enclosing closure watches. See _RunCard.
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final status = item['status']?.toString() ?? '';
    final failed = status == 'FAILED';
    final folderId = (item['folderId'] as num?)?.toInt();
    // Read UNCONDITIONALLY. This is the widget's own Obx, and GetX requires
    // every build to touch at least one observable; the Retry button below is
    // the only reader and it exists only for a FAILED row, so a SUCCEEDED row
    // used to register nothing and GetX logged "improper use of a GetX".
    final busy = controller.working.value || controller.isRunning;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            switch (status) {
              'SUCCEEDED' => Icons.check_circle_outline,
              'FAILED' => Icons.error_outline,
              'RUNNING' => Icons.hourglass_top,
              _ => Icons.radio_button_unchecked,
            },
            size: 18,
            color: failed
                ? scheme.error
                : status == 'SUCCEEDED'
                ? scheme.primary
                : scheme.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  [
                    'Folder ${item['folderId']}',
                    if (item['groupId'] != null) item['groupId'].toString(),
                    if (item['zipSize'] != null) _size(item['zipSize']),
                  ].join('  ·  '),
                  style: const TextStyle(fontSize: 13),
                ),
                // The engine writes these messages as plain English for the
                // operator; shown verbatim rather than reworded here.
                if (failed && item['error'] != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      item['error'].toString(),
                      style: TextStyle(fontSize: 12, color: scheme.error),
                    ),
                  ),
              ],
            ),
          ),
          if (failed && folderId != null)
            TextButton(
              onPressed: busy ? null : () => controller.retryFolder(folderId),
              child: const Text('Retry'),
            ),
        ],
      ),
    );
  }

  static String _size(Object? bytes) {
    final value = (bytes as num?)?.toDouble() ?? 0;
    if (value < 1024 * 1024) return '${(value / 1024).round()} KB';
    return '${(value / 1024 / 1024).toStringAsFixed(1)} MB';
  }
}

/// The upload phase: what reached the bucket, what is waiting, what failed.
///
/// Shown even when upload is off, as one line saying so - an operator asking
/// "did this go up?" should find the answer here rather than a blank space.
class _UploadCard extends StatelessWidget {
  const _UploadCard({required this.controller});

  final QcExportsController controller;

  @override
  // Own Obx: reads `working` and `uploads`. See _RunCard.
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final u = controller.uploads.value;
    final enabled = u?['enabled'] == true;
    final problem = u?['problem']?.toString();
    final pending = (u?['pending'] as List?) ?? const [];
    final current = u?['current'] as Map?;
    final failures = controller.uploadFailures;
    final recent = ((u?['recent'] as List?) ?? const [])
        .cast<Map<String, Object?>>();

    final String title;
    if (u == null) {
      title = 'Upload';
    } else if (!enabled) {
      title = 'Upload to S3 is off on this station';
    } else {
      final prefix = (u['prefix']?.toString() ?? '').isEmpty
          ? ''
          : '/${u['prefix']}';
      title = 'Upload to s3://${u['bucket'] ?? '?'}$prefix';
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                ),
                if (controller.isUploading)
                  const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (failures.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  FilledButton.tonal(
                    onPressed: controller.working.value
                        ? null
                        : controller.retryUploads,
                    child: const Text('Retry failed uploads'),
                  ),
                ],
              ],
            ),
            if (enabled && problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '$problem (Station Setup in LWCam Admin)',
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ),
            if (enabled && problem == null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  [
                    '${u?['uploadedCount'] ?? 0} uploaded',
                    if (pending.isNotEmpty) '${pending.length} waiting',
                    if (current != null) 'sending ${current['package']}',
                  ].join('  ·  '),
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final failure in failures) ...[
              const Divider(height: 20),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    failure['package']?.toString() ?? '',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (failure['error'] != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        failure['error'].toString(),
                        style: TextStyle(fontSize: 12, color: scheme.error),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      failure['nextAttemptAt'] == null
                          ? 'Retrying on the next sweep'
                          : 'Failed ${failure['attempts']} time(s); '
                                'next try ${_clock(failure['nextAttemptAt'])}',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (recent.isNotEmpty) ...[
              const Divider(height: 20),
              Text(
                'Recently uploaded',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
              for (final item in recent)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.cloud_done_outlined,
                        size: 16,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '${item['package']}  ·  ${_ItemRow._size(item['size'])}'
                          '  ·  ${_clock(item['uploadedAt'])}',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  /// Local wall-clock for an ISO timestamp; the engine writes UTC.
  static String _clock(Object? iso) {
    final parsed = DateTime.tryParse(iso?.toString() ?? '')?.toLocal();
    if (parsed == null) return '';
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(parsed.hour)}:${two(parsed.minute)}';
  }
}

class _FailuresCard extends StatelessWidget {
  const _FailuresCard({required this.controller});

  final QcExportsController controller;

  @override
  // Own Obx: reads `working`, which no enclosing closure watches. See _RunCard.
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final failures = controller.failures;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  failures.isEmpty
                      ? 'No unresolved failures'
                      : 'Unresolved failures (${failures.length})',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (failures.isNotEmpty)
                  FilledButton.tonal(
                    onPressed: controller.working.value || controller.isRunning
                        ? null
                        : controller.retryAllFailed,
                    child: const Text('Retry all failed'),
                  ),
              ],
            ),
            if (failures.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  // Says why the list is not just the last run's failures.
                  'These stay listed until the folder exports successfully.',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            for (final failure in failures) ...[
              const Divider(height: 20),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          failure['folderName']?.toString() ??
                              'Folder ${failure['folderId']}',
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (failure['error'] != null)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              failure['error'].toString(),
                              style: TextStyle(
                                fontSize: 12,
                                color: scheme.error,
                              ),
                            ),
                          ),
                        if ((failure['attempts'] as num? ?? 0) > 1)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              'Failed ${failure['attempts']} times',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: controller.working.value || controller.isRunning
                        ? null
                        : () => controller.retryFolder(
                            (failure['folderId'] as num).toInt(),
                          ),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, this.isError = false});

  final String text;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isError ? scheme.errorContainer : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          color: isError ? scheme.onErrorContainer : scheme.onSurface,
        ),
      ),
    );
  }
}
