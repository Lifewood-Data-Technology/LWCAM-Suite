import 'package:flutter/material.dart';

import '../models/qc_task.dart';

/// Collects which pages need redoing and why.
///
/// Only pages that exist in the database are offered. A page added during
/// review has no row to attach a rework log to, and naming one makes the engine
/// refuse the whole request - so they are left out here rather than failing at
/// the end with a message about ids.
///
/// Every chosen page needs its own reason: the operator redoing the capture
/// reads these, and "bad" against five pages tells them nothing.
class QcRejectDialog extends StatefulWidget {
  const QcRejectDialog({
    super.key,
    required this.images,
    required this.droppedInsertedPages,
  });

  /// Official pages only.
  final List<QcTaskImage> images;

  /// How many draft-inserted pages are not shown, so the dialog can say so
  /// rather than appear to have lost them.
  final int droppedInsertedPages;

  @override
  State<QcRejectDialog> createState() => _QcRejectDialogState();
}

class _QcRejectDialogState extends State<QcRejectDialog> {
  final _reasons = <int, TextEditingController>{};
  final _chosen = <int>{};

  /// Typed once, applied to every chosen page - the common case is one fault
  /// across a run of pages.
  final _shared = TextEditingController();
  bool _useShared = true;

  @override
  void dispose() {
    for (final controller in _reasons.values) {
      controller.dispose();
    }
    _shared.dispose();
    super.dispose();
  }

  /// What the caller gets back: page id to reason, already trimmed.
  Map<int, String> get _result => {
        for (final id in _chosen)
          if (_reasonFor(id).trim().isNotEmpty) id: _reasonFor(id).trim(),
      };

  String _reasonFor(int id) =>
      _useShared ? _shared.text : (_reasons[id]?.text ?? '');

  bool get _canSend =>
      _chosen.isNotEmpty && _result.length == _chosen.length;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return AlertDialog(
      title: const Text('Send for rework'),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'The folder goes back to the capture operator and your draft '
              'edits are discarded.',
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
            if (widget.droppedInsertedPages > 0)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${widget.droppedInsertedPages} page(s) you added during '
                  'review cannot be sent for rework and are not listed.',
                  style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
                ),
              ),
            const SizedBox(height: 12),
            Row(
              children: [
                Checkbox(
                  value: _useShared,
                  onChanged: (v) => setState(() => _useShared = v ?? true),
                ),
                const Expanded(
                  child: Text('Same reason for every page',
                      style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
            if (_useShared)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: TextField(
                  controller: _shared,
                  decoration: const InputDecoration(
                    labelText: 'What needs redoing',
                    isDense: true,
                  ),
                  maxLines: 2,
                  onChanged: (_) => setState(() {}),
                ),
              ),
            const Divider(height: 1),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: widget.images.length,
                itemBuilder: (context, i) {
                  final image = widget.images[i];
                  final chosen = _chosen.contains(image.id);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      CheckboxListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        value: chosen,
                        title: Text(
                          'Page ${i + 1} — ${image.filename}',
                          style: const TextStyle(fontSize: 13),
                        ),
                        onChanged: (v) => setState(() {
                          if (v ?? false) {
                            _chosen.add(image.id);
                            _reasons.putIfAbsent(
                                image.id, () => TextEditingController());
                          } else {
                            _chosen.remove(image.id);
                          }
                        }),
                      ),
                      if (chosen && !_useShared)
                        Padding(
                          padding: const EdgeInsets.only(left: 32, bottom: 8),
                          child: TextField(
                            controller: _reasons[image.id],
                            decoration: const InputDecoration(
                              labelText: 'Reason for this page',
                              isDense: true,
                            ),
                            onChanged: (_) => setState(() {}),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
            if (_chosen.isNotEmpty && !_canSend)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Every chosen page needs a reason.',
                  style: TextStyle(fontSize: 12, color: scheme.error),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _canSend ? () => Navigator.pop(context, _result) : null,
          child: Text('Rework (${_chosen.length})'),
        ),
      ],
    );
  }
}
