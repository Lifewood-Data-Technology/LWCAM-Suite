// Metadata dialog for one folder of a capture box (LWCAM capture app).
// Despite the file name it is a dialog, not a page route. The fields come
// from the project's metadata template; the result goes back to the caller.
import 'package:flutter/material.dart';

import '../models/capture_box_models.dart';
import '../models/metadata_template.dart';
import '../services/path_utils.dart' show sanitizeWindowsName;
import '../theme/app_colors.dart';

/// Metadata form for ONE folder of a capture box (spec §8 fields), driven by
/// the box's [MetadataTemplate] snapshot — which fields appear, their type,
/// order, and mandatory-ness are all template config, not hardcoded here.
/// Shown as a MODAL DIALOG (not a page route: pushing a full page over the
/// gallery animated the heavy grid on open AND close — the dialog leaves the
/// page underneath untouched, so open/close is instant). Pops with the
/// edited [CaptureFolder] draft, or null on Cancel — persisting is the
/// caller's job (BoxSessionController). Drafts with missing mandatory fields
/// are allowed; completeness is enforced at the box transfer gate.
///
/// Volume is always a form field (locked by the template: always enabled,
/// mandatory, free text). Nothing is parsed out of it — it IS the destination
/// folder's name, previewed sanitized in a helper line so a typed "/" or ":"
/// is visibly replaced before transfer.
class FolderMetadataDialog extends StatefulWidget {
  /// The draft being edited. For a NEW folder the caller passes a prefilled
  /// draft; carry-over between folders is off, so it arrives blank.
  final CaptureFolder initial;

  /// Title context, e.g. 'New folder' / 'Edit folder 2'.
  final String heading;

  /// Box details shown read-only so the operator sees the naming context.
  final String boxDetails;

  /// The box's metadata template snapshot — determines which fields show,
  /// their type/order/mandatory-ness, and dropdown options.
  final MetadataTemplate template;

  const FolderMetadataDialog({
    super.key,
    required this.initial,
    required this.heading,
    required this.boxDetails,
    required this.template,
  });

  @override
  State<FolderMetadataDialog> createState() => _FolderMetadataDialogState();
}

class _FolderMetadataDialogState extends State<FolderMetadataDialog> {
  /// One entry per dropdown-type field on the form (keyed by field id).
  final Map<String, String?> _dropdownValues = {};

  /// One entry per free-text-type field on the form (keyed by field id).
  final Map<String, TextEditingController> _textControllers = {};

  /// Main-field ids whose derived-tile group is currently EXPANDED. Empty on
  /// open, so every derived group starts collapsed (a compact summary line)
  /// and only takes full space once the operator expands it.
  final Set<String> _expandedDerivedGroups = {};

  @override
  void initState() {
    super.initState();
    final e = widget.initial;
    for (final field in widget.template.orderedFormFields) {
      final raw = widget.template.keyedValueOf(field.id, e);
      if (field.isDropdown) {
        // Keep-but-flag: a stored value no longer in the current options
        // stays selected (see _dropdownForField) rather than being nulled
        // out — nulling would silently destroy previously-keyed data.
        _dropdownValues[field.id] = raw;
      } else {
        final ctl = TextEditingController(text: raw ?? '');
        if (field.id == kVolumeFieldId) {
          ctl.addListener(() => setState(() {})); // live folder-name preview
        }
        _textControllers[field.id] = ctl;
      }
    }
  }

  @override
  void dispose() {
    for (final ctl in _textControllers.values) {
      ctl.dispose();
    }
    super.dispose();
  }

  CaptureFolder _build() {
    final values = <String, String?>{};
    for (final field in widget.template.orderedFormFields) {
      if (field.isDropdown) {
        values[field.id] = _dropdownValues[field.id];
      } else {
        final text = _textControllers[field.id]!.text.trim();
        values[field.id] = text.isEmpty ? null : text;
      }
    }
    // Fields not on the form (disabled/fixed in this template) pass through
    // from widget.initial unchanged — see MetadataTemplate.applyValues.
    return widget.template.applyValues(widget.initial, values);
  }

  void _save() {
    Navigator.of(context).pop(_build());
  }

  /// Current in-progress form value of [fieldId] — dropdown fields live in
  /// [_dropdownValues], free-text fields in [_textControllers]. Used to
  /// resolve a mapped field's live derived tile as the operator types/picks.
  String? _currentFormValueOf(String fieldId) {
    if (_dropdownValues.containsKey(fieldId)) return _dropdownValues[fieldId];
    return _textControllers[fieldId]?.text;
  }

  @override
  Widget build(BuildContext context) {
    final draft = _build();
    final formFields = widget.template.orderedFormFields;
    final volumeCtl = _textControllers[kVolumeFieldId];
    // The destination folder IS the Volume. Previewing it sanitized is worth a
    // line, because that is where a typed "/" or ":" visibly becomes "_".
    // Blank-check BEFORE sanitizing, the same trap computeFolderNames has:
    // sanitizeWindowsName('') returns "_", so sanitizing first meant an unkeyed
    // Volume previewed as a folder literally named "_" and the "blank" branch
    // below could never run.
    final volumeText = (volumeCtl?.text ?? '').trim();
    final folderNamePreview =
        volumeText.isEmpty ? '' : sanitizeWindowsName(volumeText);

    return Dialog(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 640,
          maxHeight: MediaQuery.of(context).size.height * 0.92,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 12, 0),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.heading,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: 'Cancel',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _statusBanner(draft),
                    const SizedBox(height: 12),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surfaceContainerLow,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.inventory_2_outlined,
                              size: 20,
                              color: Theme.of(context).colorScheme.onSurfaceVariant),
                          const SizedBox(width: 8),
                          Expanded(
                            // Selectable: this is the one identifier an operator
                            // has to carry into another system by hand, and a
                            // plain Text cannot be highlighted or copied.
                            child: SelectableText('Group: ${widget.boxDetails}',
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600, fontSize: 13)),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    for (final field in formFields) ...[
                      _fieldWidget(field),
                      ..._derivedGroupWidgets(field.id),
                      if (field.id == kVolumeFieldId) ...[
                        const SizedBox(height: 8),
                        _derivedTile(
                          Icons.folder_outlined,
                          'Folder name (from Volume)',
                          folderNamePreview.isEmpty
                              ? 'blank — the folder will be named after the group'
                              : folderNamePreview,
                        ),
                      ],
                      const SizedBox(height: 12),
                    ],
                    Text(
                      '* mandatory. Drafts with missing fields can be saved and '
                      'finished later — transfer is blocked until every folder '
                      'is complete.',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _save,
                    icon: const Icon(Icons.save),
                    label: const Text('Save'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statusBanner(CaptureFolder draft) {
    final complete = widget.template.isCompleteOf(draft);
    final missing = widget.template.missingMandatoryFieldsOf(draft);
    final lw = LifewoodColors.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: complete ? lw.successContainer : lw.warningContainer,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: complete ? lw.success : lw.warning),
      ),
      child: Row(
        children: [
          Icon(complete ? Icons.check_circle : Icons.info_outline,
              color: complete ? lw.success : lw.warning),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              complete
                  ? 'Metadata complete — all mandatory fields are keyed.'
                  : 'Draft — still missing: ${missing.join(', ')}',
              style: TextStyle(
                  color: complete
                      ? lw.onSuccessContainer
                      : lw.onWarningContainer),
            ),
          ),
        ],
      ),
    );
  }

  Widget _fieldWidget(TemplateField field) {
    final label = field.mandatory ? '${field.label} *' : '${field.label} (optional)';
    if (field.isDropdown) {
      return _dropdownForField(field, label);
    }
    return TextField(
      controller: _textControllers[field.id],
      // No example hint: the shape of a Volume, a Group Details or any other
      // keyed value differs per project, so a worked example from one project
      // is wrong everywhere else.
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
    );
  }

  /// Every dropdown offers an empty "— None —" selection; mandatory-ness is
  /// enforced by MetadataTemplate.missingMandatoryFieldsOf, not the widget.
  /// A stored value no longer present in [field.options] (the template's
  /// dropdown list changed after this folder was keyed) stays selectable and
  /// is visually flagged — see the class doc's "keep-but-flag" note.
  Widget _dropdownForField(TemplateField field, String label) {
    final value = _dropdownValues[field.id];
    final optionValues = field.options.map((o) => o.value).toList();
    final isStale = value != null && !optionValues.contains(value);
    // Flutter defaults a TextField to bodyLarge (16 here) but a
    // DropdownButtonFormField to titleMedium (14), so a keyed dropdown value
    // rendered two points smaller than the free-text field directly above it
    // in the same form. Pin it to the TextField's style so a row of fields
    // reads as one form.
    final baseStyle = Theme.of(context).textTheme.bodyLarge;
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      style: baseStyle,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      items: [
        const DropdownMenuItem<String>(value: null, child: Text('— None —')),
        ...optionValues.map((o) =>
            DropdownMenuItem(value: o, child: Text(o, overflow: TextOverflow.ellipsis))),
        if (isStale)
          DropdownMenuItem(
            value: value,
            // copyWith, not a bare TextStyle: a fresh one would drop the size
            // again and make the stale entry the odd one out.
            child: Text('$value (no longer allowed)',
                overflow: TextOverflow.ellipsis,
                style: baseStyle?.copyWith(
                    color: Theme.of(context).colorScheme.error)),
          ),
      ],
      onChanged: (v) => setState(() => _dropdownValues[field.id] = v),
    );
  }

  /// The collapsible derived-tile group for [mainFieldId] (empty list when
  /// the field derives nothing). Rendered directly under the main field, so
  /// each derived value stays next to the field it comes from.
  List<Widget> _derivedGroupWidgets(String mainFieldId) {
    final mapped = widget.template.mappedFieldsFor(mainFieldId);
    if (mapped.isEmpty) return const [];
    return [
      const SizedBox(height: 8),
      _derivedGroup(mainFieldId, mapped),
    ];
  }

  /// A minimize/maximize group of derived tiles. Collapsed (the default) it's
  /// a single summary line listing the derived field names; expanded it shows
  /// each derived value in its own tile below the summary.
  Widget _derivedGroup(String mainFieldId, List<TemplateField> mapped) {
    final expanded = _expandedDerivedGroups.contains(mainFieldId);
    final labels = mapped.map((f) => f.label).join(', ');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(8),
          child: InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() {
              if (expanded) {
                _expandedDerivedGroups.remove(mainFieldId);
              } else {
                _expandedDerivedGroups.add(mainFieldId);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(expanded ? Icons.expand_less : Icons.expand_more,
                      size: 20,
                      color: Theme.of(context).colorScheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      expanded ? 'Derived (${mapped.length}) — tap to hide' : 'Derived: $labels',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (expanded)
          for (final m in mapped) ...[
            const SizedBox(height: 8),
            _derivedTile(
              Icons.category_outlined,
              '${m.label} (derived)',
              widget.template.mappedValueFor(m, _currentFormValueOf(mainFieldId)) ?? '—',
            ),
          ],
      ],
    );
  }

  Widget _derivedTile(IconData icon, String label, String value) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: cs.onSurfaceVariant),
          const SizedBox(width: 8),
          Text('$label: ',
              style: TextStyle(color: cs.onSurfaceVariant, fontSize: 13)),
          Expanded(
            // Selectable for the same reason as the box row above: the file
            // number is transcribed into other systems by hand.
            child: SelectableText(value,
                style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          ),
        ],
      ),
    );
  }
}
