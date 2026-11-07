// Admin-only screen in the capture app (LWCAM, first stage of the pipeline:
// capture app -> LWIP -> QC -> Upload) for orphan images: captures that never
// got filed into a box folder. The admin assigns each one to a folder or
// discards it. Only boxes that are still open can receive an image; a
// transferred box is never changed after the fact.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../auth/auth_controller.dart';
import '../db/upload_stats_db.dart';
import '../models/capture_box_models.dart';
import '../services/audit_log_service.dart';
import '../services/box_integrity.dart' as integrity;
import '../services/orphan_image_store.dart';
import '../services/snackbar_service.dart';
import '../widgets/enlarged_image_dialog.dart';
import '../widgets/session_app_bar_actions.dart';
import '../theme/app_colors.dart';

/// Admin-only screen for images that could not be filed into a box at capture
/// time (a failed DB assignment, or a capture with no active folder) and could
/// not be auto-healed — the residual case where the folder intent is lost.
/// The admin sees the actual image and either assigns it to a folder or
/// discards it. Capture operators never touch this; they never do DB
/// operations by design.
class OrphanResolutionPage extends StatefulWidget {
  const OrphanResolutionPage({super.key});

  @override
  State<OrphanResolutionPage> createState() => _OrphanResolutionPageState();
}

class _OrphanResolutionPageState extends State<OrphanResolutionPage> {
  final _store = OrphanImageStore.production();
  final _db = UploadStatsDB();

  bool _loading = true;
  List<OrphanEntry> _entries = const [];
  // boxId → box details, for the "known box" grouping labels.
  final Map<int, String> _boxLabels = {};

  AuditLogService? get _auditOrNull =>
      Get.isRegistered<AuditLogService>() ? Get.find<AuditLogService>() : null;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final entries = await _store.listAll();
      _boxLabels.clear();
      for (final e in entries) {
        if (e.boxId != null && !_boxLabels.containsKey(e.boxId)) {
          final box =
              await _db.getCaptureBoxById(deviceId: e.deviceId, boxId: e.boxId!);
          if (box != null) _boxLabels[e.boxId!] = box.boxDetails;
        }
      }
      if (mounted) setState(() => _entries = entries);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final auth = Get.find<AuthController>();
    if (!(auth.currentUser.value?.isAdmin ?? false)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Unresolved Images')),
        body: const Center(child: Text('Access denied — administrators only.')),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Unresolved Images'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          ...sessionAppBarActions(context),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: Text(
                      'No unresolved images. Every capture has been filed into '
                      'a group.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  children: [
                    for (final e in _entries) _entryTile(context, e),
                  ],
                ),
    );
  }

  Widget _entryTile(BuildContext context, OrphanEntry e) {
    final cs = Theme.of(context).colorScheme;
    final origin = e.boxId != null
        ? 'Group: ${_boxLabels[e.boxId] ?? 'group #${e.boxId}'}'
        : 'Unknown origin';
    final meta = [
      e.deviceFilename,
      if ((e.reason ?? '').isNotEmpty) e.reason!,
      if (e.note != null) 'note: ${e.note}',
      if (e.stashedAt != null) e.stashedAt!.toIso8601String(),
    ].join(' · ');

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: ListTile(
        contentPadding: const EdgeInsets.all(12),
        leading: GestureDetector(
          onTap: () =>
              showEnlargedImage(context, e.file, caption: e.deviceFilename),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Image.file(
              e.file,
              width: 64,
              height: 64,
              cacheWidth: 128,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => Container(
                width: 64,
                height: 64,
                color: cs.surfaceContainerHighest,
                child: const Icon(Icons.broken_image_outlined),
              ),
            ),
          ),
        ),
        title: Text(origin, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(meta, maxLines: 2, overflow: TextOverflow.ellipsis),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            FilledButton.icon(
              onPressed: () => _assign(e),
              icon: const Icon(Icons.drive_file_move_outlined, size: 16),
              label: const Text('Assign'),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => _discard(e),
              style: TextButton.styleFrom(foregroundColor: cs.error),
              child: const Text('Discard'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _assign(OrphanEntry e) async {
    // Only OPEN boxes on the entry's device can receive it (assigning into a
    // transferred box would strand the row).
    final boxes = (await _db.getCaptureBoxes(e.deviceId))
        .where((b) => !b.isTransferred)
        .toList();
    if (boxes.isEmpty) {
      showAppSnackBar('No open group',
          'There is no open group on device ${e.deviceId} to assign this image to.',
          backgroundColor: Get.theme.extension<LifewoodColors>()!.warning,
          colorText: Get.theme.extension<LifewoodColors>()!.onWarning);
      return;
    }

    CaptureBox box =
        boxes.firstWhereOrNull((b) => b.id == e.boxId) ?? boxes.first;
    List<CaptureFolder> folders =
        await _db.getCaptureFolders(deviceId: e.deviceId, boxId: box.id);
    CaptureFolder? folder = folders.firstWhereOrNull((f) => f.id == e.folderId) ??
        (folders.isEmpty ? null : folders.first);

    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: const Text('Assign to a folder'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(e.deviceFilename,
                      style: const TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 12),
                  DropdownButton<int>(
                    isExpanded: true,
                    value: box.id,
                    items: [
                      for (final b in boxes)
                        DropdownMenuItem(value: b.id, child: Text(b.boxDetails)),
                    ],
                    onChanged: (id) async {
                      final chosen = boxes.firstWhere((b) => b.id == id);
                      final f = await _db.getCaptureFolders(
                          deviceId: e.deviceId, boxId: chosen.id);
                      setLocal(() {
                        box = chosen;
                        folders = f;
                        folder = f.isEmpty ? null : f.first;
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  DropdownButton<int>(
                    isExpanded: true,
                    value: folder?.id,
                    hint: const Text('Select a folder'),
                    items: [
                      for (final f in folders)
                        DropdownMenuItem(
                          value: f.id,
                          child: Text(_folderLabel(f)),
                        ),
                    ],
                    onChanged: (id) => setLocal(
                        () => folder = folders.firstWhere((f) => f.id == id)),
                  ),
                  if (folders.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Text('This group has no folders.',
                          style: TextStyle(color: Get.theme.colorScheme.error)),
                    ),
                ],
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    child: const Text('Cancel')),
                ElevatedButton(
                  onPressed: folder == null
                      ? null
                      : () => Navigator.of(ctx).pop(true),
                  child: const Text('Assign'),
                ),
              ],
            );
          },
        );
      },
    );
    if (confirmed != true || folder == null) return;

    try {
      final ok = await retrying(() => _db.assignImageToFolder(
            deviceId: e.deviceId,
            boxId: box.id,
            folderId: folder!.id,
            deviceFilename: e.deviceFilename,
          colorBinding: e.colorBinding,
          ));
      if (!ok) {
        showAppSnackBar('Already assigned',
            'That filename is already assigned to a folder — discard this copy instead.',
            backgroundColor: Get.theme.extension<LifewoodColors>()!.warning,
            colorText: Get.theme.extension<LifewoodColors>()!.onWarning);
        return;
      }
      await _store.resolveInto(e, await integrity.boxImagesDir(e.deviceId, box.id));
      await _auditOrNull?.log(AuditActions.orphanAssigned, details: {
        'file': e.deviceFilename,
        'box': box.id,
        'folder': folder!.id,
      });
      final tail = box.lastTransferState != null
          ? ' Use Retry on the group list to transfer it.'
          : '';
      showAppSnackBar('Assigned', '${e.deviceFilename} filed into the group.$tail',
          backgroundColor: Get.theme.extension<LifewoodColors>()!.success,
          colorText: Get.theme.extension<LifewoodColors>()!.onSuccess);
      await _load();
    } catch (err) {
      showAppSnackBar('Error', '$err',
          backgroundColor: Get.theme.colorScheme.error,
          colorText: Get.theme.colorScheme.onError);
    }
  }

  String _folderLabel(CaptureFolder f) {
    final name = f.folderName ?? 'Folder ${f.folderSeq}';
    return f.title != null && f.title!.isNotEmpty ? '$name · ${f.title}' : name;
  }

  Future<void> _discard(OrphanEntry e) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard image?'),
        content: Text(
            'This permanently deletes ${e.deviceFilename}. It is not moved to '
            'the recycle bin and cannot be recovered.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Theme.of(ctx).colorScheme.error,
                foregroundColor: Theme.of(ctx).colorScheme.onError),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _store.discard(e);
    await _auditOrNull?.log(AuditActions.orphanDiscarded,
        details: {'file': e.deviceFilename, 'box': e.boxId ?? ''});
    showAppSnackBar('Discarded', '${e.deviceFilename} was deleted.',
        backgroundColor: Get.theme.extension<LifewoodColors>()!.info,
        colorText: Get.theme.extension<LifewoodColors>()!.onInfo);
    await _load();
  }
}
