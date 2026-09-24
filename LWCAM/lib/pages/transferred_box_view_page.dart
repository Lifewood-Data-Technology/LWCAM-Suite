import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../controllers/box_session_controller.dart';
import '../db/upload_stats_db.dart';
import '../models/capture_box_models.dart';
import '../services/box_integrity.dart' show localImageNameForCloudImage;
import '../services/thumbnail_service.dart';
import '../theme/app_colors.dart';
import '../widgets/enlarged_image_dialog.dart';

class _FolderView {
  final CaptureFolder folder;
  final List<MapEntry<String, String>> metadataRows; // label -> effective value
  final List<String> filenames; // assigned image filenames, in order

  _FolderView({
    required this.folder,
    required this.metadataRows,
    required this.filenames,
  });
}

/// Read-only view of a TRANSFERRED box: metadata + thumbnails, no
/// capture/edit/transfer affordances anywhere. Deliberately a fresh,
/// lightweight page — NOT gallery_page.dart, which starts scrcpy + a live ADB
/// poll in initState, wrong for a local, offline, read-only view.
/// Everything is loaded once, locally: folders + assignments + the box's
/// snapshotted template + a one-shot listing of persisted thumbnails (see
/// `BoxSessionController.persistBoxThumbnails`, run at transfer time before
/// the full-resolution images are deleted). Boxes transferred before this
/// feature shipped have no saved thumbnails — those slots render a
/// placeholder and a banner note explains why.
///
/// REWORK is NOT here. A box QC sent images back for opens the CAPTURE page in
/// rework mode instead (gallery_page.dart), because recapturing needs the phone
/// mirror, the shutter and the image grid, which only that page has. This page
/// briefly hosted a rework mode on 2026-07-30; it was moved the same day.
class TransferredBoxViewPage extends StatefulWidget {
  final CaptureBox box;
  const TransferredBoxViewPage(this.box, {super.key});

  @override
  State<TransferredBoxViewPage> createState() => _TransferredBoxViewPageState();
}

class _TransferredBoxViewPageState extends State<TransferredBoxViewPage> {
  final BoxSessionController _session = Get.find<BoxSessionController>();
  final UploadStatsDB _db = UploadStatsDB();

  bool _loading = true;
  List<_FolderView> _folders = [];
  Directory? _thumbsDir;
  Set<String> _availableThumbs = {};
  Map<String, String> _thumbNameByImage = {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final box = widget.box;
    final deviceId = _session.deviceId;
    final template = _session.templateForBox(box);

    final folders = await _db.getCaptureFolders(deviceId: deviceId, boxId: box.id);
    final assignments =
        await _db.getAssignmentsForBox(deviceId: deviceId, boxId: box.id);

    final filenamesByFolder = <int, List<String>>{};
    for (final entry in assignments.entries) {
      (filenamesByFolder[entry.value] ??= []).add(entry.key);
    }
    for (final list in filenamesByFolder.values) {
      list.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }

    // Same effective-value resolution as buildBoxTransferPlan, generalized
    // to every enabled field so this view stays correct for any template.
    final displayFields = template.fields.where((f) => f.enabled).toList();
    final views = [
      for (final f in folders)
        _FolderView(
          folder: f,
          metadataRows: [
            for (final field in displayFields)
              MapEntry(field.label, template.effectiveValueOf(field.id, f) ?? ''),
          ],
          filenames: filenamesByFolder[f.id] ?? const [],
        ),
    ];

    Directory? thumbsDir;
    var available = <String>{};
    var thumbNameByImage = <String, String>{};
    try {
      thumbsDir = await ThumbnailService.boxThumbsDir(deviceId, box.id);
      if (await thumbsDir.exists()) {
        final files = thumbsDir.listSync().whereType<File>().toList();
        available = files.map((f) => p.basename(f.path)).toSet();
        final selectedAt = <String, DateTime>{};
        for (final file in files) {
          final storedImageName = p.basenameWithoutExtension(file.path);
          final localName = localImageNameForCloudImage(
            deviceId,
            storedImageName,
            assignments.keys,
          );
          if (!assignments.containsKey(localName)) continue;
          final modified = file.lastModifiedSync();
          if (selectedAt[localName]?.isAfter(modified) ?? false) continue;
          selectedAt[localName] = modified;
          thumbNameByImage[localName] = p.basename(file.path);
        }
      }
    } catch (_) {}

    if (!mounted) return;
    setState(() {
      _folders = views;
      _thumbsDir = thumbsDir;
      _availableThumbs = available;
      _thumbNameByImage = thumbNameByImage;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final box = widget.box;
    final transferredLabel = box.transferredAt != null
        ? 'Transferred ${box.transferredAt!.toLocal().toString().split('.').first}'
        : 'Transferred';

    return Scaffold(
      appBar: AppBar(
        title: Text(box.boxDetails.isEmpty ? '(no group details)' : box.boxDetails),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : Column(
              children: [
                Container(
                  width: double.infinity,
                  color: LifewoodColors.of(context).info,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  child: Row(
                    children: [
                      Icon(Icons.visibility,
                          color: LifewoodColors.of(context).onInfo, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text('View only — $transferredLabel',
                            style: TextStyle(
                                color: LifewoodColors.of(context).onInfo)),
                      ),
                    ],
                  ),
                ),
                if (_availableThumbs.isEmpty)
                  Container(
                    width: double.infinity,
                    color: LifewoodColors.of(context).warningContainer,
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text(
                      'No thumbnails were saved for this group (transferred before this '
                      'feature was added). Metadata is still shown below.',
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              LifewoodColors.of(context).onWarningContainer),
                    ),
                  ),
                Expanded(
                  child: _folders.isEmpty
                      ? const Center(child: Text('This group has no folders.'))
                      : ListView.builder(
                          padding: const EdgeInsets.all(12),
                          itemCount: _folders.length,
                          itemBuilder: (context, i) => _folderCard(_folders[i]),
                        ),
                ),
              ],
            ),
    );
  }

  Widget _folderCard(_FolderView fv) {
    final title = fv.folder.folderName ?? 'Folder ${fv.folder.folderSeq}';
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 15)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 16,
              runSpacing: 4,
              children: [
                for (final row in fv.metadataRows)
                  if (row.value.isNotEmpty)
                    SizedBox(
                      width: 260,
                      child: RichText(
                        text: TextSpan(
                          style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 12),
                          children: [
                            TextSpan(
                                text: '${row.key}: ',
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                            TextSpan(text: row.value),
                          ],
                        ),
                      ),
                    ),
              ],
            ),
            const SizedBox(height: 8),
            Text('${fv.filenames.length} image(s)',
                style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
            const SizedBox(height: 8),
            _thumbnailGrid(fv.filenames),
          ],
        ),
      ),
    );
  }

  Widget _thumbnailGrid(List<String> filenames) {
    if (filenames.isEmpty) return const SizedBox.shrink();
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 5,
        crossAxisSpacing: 6,
        mainAxisSpacing: 6,
      ),
      itemCount: filenames.length,
      itemBuilder: (context, i) {
        final name = filenames[i];
        final thumbName = _thumbNameByImage[name] ?? '$name.png';
        final exists = _thumbsDir != null && _availableThumbs.contains(thumbName);
        if (!exists) {
          return Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Icon(Icons.image_not_supported_outlined,
                color: Theme.of(context).colorScheme.outline),
          );
        }
        final thumbFile = File(p.join(_thumbsDir!.path, thumbName));
        return GestureDetector(
          onTap: () => showEnlargedImage(context, thumbFile, caption: name),
          child: Image.file(thumbFile, cacheWidth: 256, fit: BoxFit.cover),
        );
      },
    );
  }
}
