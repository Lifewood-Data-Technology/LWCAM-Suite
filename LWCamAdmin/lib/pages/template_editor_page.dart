import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/projects_controller.dart';
import '../models/metadata_template.dart';
import '../models/project.dart';
import '../services/snackbar_service.dart';
import '../theme/app_colors.dart';

/// SuperAdmin-only editor for a project's [MetadataTemplate]: which of the
/// 14 spec fields are enabled, their MODE (editable / fixed / mapped — see
/// metadata_template.dart), free text vs dropdown + options (editable),
/// constant value (fixed), or a value map derived from another field
/// (mapped), mandatory-ness, and display order (drag to reorder). Volume is
/// locked — it always stays enabled/mandatory/editable/free-text since
/// folder naming depends on it.
///
/// Edits are snapshotted into NEW groups only (see BoxSessionController.createBox);
/// groups already open keep whichever template they were created with.
class TemplateEditorPage extends StatefulWidget {
  final Project project;
  final ProjectsController controller;

  const TemplateEditorPage({super.key, required this.project, required this.controller});

  @override
  State<TemplateEditorPage> createState() => _TemplateEditorPageState();
}

class _TemplateEditorPageState extends State<TemplateEditorPage> {
  late List<TemplateField> _fields;
  final Map<String, TextEditingController> _fixedValueControllers = {};
  final Map<String, TextEditingController> _newOptionControllers = {};
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _fields = List.of((widget.project.template ?? MetadataTemplate.standard()).fields);
    for (final f in _fields) {
      _fixedValueControllers[f.id] = TextEditingController(text: f.fixedValue ?? '');
      _newOptionControllers[f.id] = TextEditingController();
    }
  }

  @override
  void dispose() {
    for (final c in _fixedValueControllers.values) {
      c.dispose();
    }
    for (final c in _newOptionControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  TemplateField? _fieldByIdInList(String? id) {
    if (id == null) return null;
    for (final f in _fields) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// Fields another field may map from: enabled, editable, dropdown, and not
  /// itself — keeps mappings one level deep (a mapped field can never be a
  /// main field, so no chains).
  List<TemplateField> _mappableCandidates(TemplateField excluding) => _fields
      .where((f) => f.id != excluding.id && f.enabled && f.isEditable && f.isDropdown)
      .toList();

  void _updateField(int index, TemplateField Function(TemplateField) update) {
    setState(() => _fields[index] = update(_fields[index]));
  }

  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final field = _fields.removeAt(oldIndex);
      _fields.insert(newIndex, field);
    });
  }

  Future<void> _resetToDefault() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Reset to default?'),
        content: const Text(
            'This discards your changes on this screen and restores the built-in standard template. You still need to tap Save to apply it.'),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Reset')),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() {
      _fields = List.of(MetadataTemplate.standard().fields);
      for (final f in _fields) {
        _fixedValueControllers[f.id]!.text = f.fixedValue ?? '';
      }
    });
  }

  Future<void> _save() async {
    for (final f in _fields) {
      if (!f.enabled) continue;
      if (f.isFixed) {
        if ((f.fixedValue ?? '').trim().isEmpty) {
          showAppSnackBar('Error', 'Set a value for "${f.label}" (it is fixed and enabled).',
              backgroundColor: Get.theme.colorScheme.error,
              colorText: Get.theme.colorScheme.onError,
              width: kCompactSnackBarWidth);
          return;
        }
      } else if (f.isMapped) {
        final main = _fieldByIdInList(f.mappedFrom);
        if (main == null || !main.enabled || !main.isEditable || !main.isDropdown) {
          showAppSnackBar('Error', '"${f.label}" needs a field to map from — pick one.',
              backgroundColor: Get.theme.colorScheme.error,
              colorText: Get.theme.colorScheme.onError,
              width: kCompactSnackBarWidth);
          return;
        }
      } else if (f.isDropdown && f.options.isEmpty) {
        showAppSnackBar('Error', 'Add at least one option for "${f.label}".',
            backgroundColor: Get.theme.colorScheme.error,
              colorText: Get.theme.colorScheme.onError,
              width: kCompactSnackBarWidth);
        return;
      }
    }

    setState(() => _saving = true);
    try {
      await widget.controller.setProjectTemplate(
        key: widget.project.key,
        template: MetadataTemplate(fields: _fields),
      );
      showAppSnackBar('Saved', 'Template updated for ${widget.project.name}.',
          backgroundColor: Get.theme.extension<LifewoodColors>()!.success,
          colorText: Get.theme.extension<LifewoodColors>()!.onSuccess,
          width: kCompactSnackBarWidth);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      showAppSnackBar('Error', '$e',
          backgroundColor: Get.theme.colorScheme.error,
              colorText: Get.theme.colorScheme.onError,
              width: kCompactSnackBarWidth);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // The default TextButton foreground is the brand primary (dark green),
    // near-invisible on this AppBar's own dark green background — same fix
    // as HomePage's Logout button.
    final appBarFg = Theme.of(context).appBarTheme.foregroundColor ??
        Theme.of(context).colorScheme.onSurface;
    final appBarFgBorder = BorderSide(color: appBarFg.withValues(alpha: 0.65));
    return Scaffold(
      appBar: AppBar(
        title: Text('Template — ${widget.project.name}'),
        actions: [
          OutlinedButton.icon(
              onPressed: _saving ? null : _resetToDefault,
              style: OutlinedButton.styleFrom(foregroundColor: appBarFg, side: appBarFgBorder),
              icon: const Icon(Icons.restore, size: 18),
              label: const Text('Reset to default')),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: _saving ? null : _save,
            style: OutlinedButton.styleFrom(foregroundColor: appBarFg, side: appBarFgBorder),
            icon: _saving
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2, color: appBarFg))
                : const Icon(Icons.save, size: 18),
            label: const Text('Save'),
          ),
          const SizedBox(width: 12),
        ],
      ),
      body: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            color: LifewoodColors.of(context).infoContainer,
            child: Text(
              'Groups already open keep the template they were created with — only NEW groups pick up changes made here.',
              style: TextStyle(
                  fontSize: 13,
                  color: LifewoodColors.of(context).onInfoContainer),
            ),
          ),
          Expanded(
            child: ReorderableListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              // Each tile already wires up its own drag handle (the leading
              // icon via ReorderableDragStartListener) — without this,
              // ReorderableListView also appends its own default handle at
              // the far right of every row, showing up as a second "="
              // crammed against the rounded card corner.
              buildDefaultDragHandles: false,
              itemCount: _fields.length,
              onReorder: _reorder,
              itemBuilder: (context, index) => _fieldTile(index, _fields[index]),
            ),
          ),
        ],
      ),
    );
  }

  String _modeLabel(String mode) {
    switch (mode) {
      case kModeEditable:
        return 'Editable (shown on form)';
      case kModeFixed:
        return 'Fixed (constant)';
      case kModeMapped:
        return 'Mapped (derived)';
      default:
        return mode;
    }
  }

  String _summaryFor(TemplateField field) {
    if (!field.enabled) return 'Disabled';
    if (field.isFixed) {
      final v = field.fixedValue;
      return 'Fixed: ${(v == null || v.isEmpty) ? '(no value set)' : v}';
    }
    if (field.isMapped) {
      final mainLabel = _fieldByIdInList(field.mappedFrom)?.label ?? '(not set)';
      return 'Mapped from $mainLabel · ${field.valueMap.length} mapping(s)';
    }
    final parts = <String>[field.isDropdown ? 'Dropdown' : 'Free text'];
    if (field.mandatory) parts.add('mandatory');
    if (field.isDropdown) parts.add('${field.options.length} option(s)');
    return parts.join(' · ');
  }

  Widget _fieldTile(int index, TemplateField field) {
    final locked = field.id == kVolumeFieldId;
    return Card(
      key: ValueKey(field.id),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ExpansionTile(
        leading: ReorderableDragStartListener(
          index: index,
          child: const Icon(Icons.drag_handle),
        ),
        title: Text(field.label, style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: Text(_summaryFor(field)),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: locked
                ? Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      'Always enabled, mandatory, editable free text — locked '
                      'because folder naming depends on it. You can still drag '
                      'it to reposition it on the form.',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                          fontSize: 13),
                    ),
                  )
                : _fieldBody(index, field),
          ),
        ],
      ),
    );
  }

  Widget _modeSelector(int index, TemplateField field, List<String> availableModes) {
    return Row(
      children: [
        const Text('Mode: '),
        const SizedBox(width: 8),
        DropdownButton<String>(
          value: field.mode,
          items: [
            for (final m in availableModes) DropdownMenuItem(value: m, child: Text(_modeLabel(m))),
          ],
          onChanged: (v) {
            if (v != null) _updateField(index, (f) => f.copyWith(mode: v));
          },
        ),
      ],
    );
  }

  Widget _fieldBody(int index, TemplateField field) {
    // Fixed-only (spec §8.3) fields have no per-folder storage, so they can
    // only ever be fixed or mapped, never editable.
    final availableModes =
        field.isKeyedField ? const [kModeEditable, kModeFixed, kModeMapped] : const [kModeFixed, kModeMapped];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Enabled'),
          value: field.enabled,
          onChanged: (v) => _updateField(index, (f) => f.copyWith(enabled: v)),
        ),
        if (field.enabled) ...[
          _modeSelector(index, field, availableModes),
          const SizedBox(height: 8),
          if (field.isFixed)
            TextField(
              controller: _fixedValueControllers[field.id],
              decoration: const InputDecoration(labelText: 'Fixed value'),
              onChanged: (v) => _updateField(index, (f) => f.copyWith(fixedValue: v)),
            )
          else if (field.isMapped)
            _mappedBody(index, field)
          else ...[
            // Editable — only reachable for the 8 keyed fields.
            Row(
              children: [
                const Text('Input type: '),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: field.inputType,
                  items: const [
                    DropdownMenuItem(value: 'freeText', child: Text('Free text')),
                    DropdownMenuItem(value: 'dropdown', child: Text('Dropdown')),
                  ],
                  onChanged: (v) {
                    if (v != null) _updateField(index, (f) => f.copyWith(inputType: v));
                  },
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Mandatory'),
              value: field.mandatory,
              onChanged: (v) => _updateField(index, (f) => f.copyWith(mandatory: v)),
            ),
            if (field.isDropdown) _optionsEditor(index, field),
          ],
        ],
      ],
    );
  }

  /// "Mapped from" picker + one value input per option of the chosen main
  /// field. A main option with no entry derives blank — gaps are allowed by
  /// design, so nothing here forces completeness.
  Widget _mappedBody(int index, TemplateField field) {
    final candidates = _mappableCandidates(field);
    final candidateIds = candidates.map((f) => f.id).toSet();
    final currentMainId = candidateIds.contains(field.mappedFrom) ? field.mappedFrom : null;
    final mainField = _fieldByIdInList(currentMainId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text('Mapped from: '),
            const SizedBox(width: 8),
            Expanded(
              child: DropdownButton<String>(
                isExpanded: true,
                value: currentMainId,
                hint: const Text('Select a field'),
                items: [
                  for (final c in candidates) DropdownMenuItem(value: c.id, child: Text(c.label)),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  // Old value map keys almost certainly don't match the new
                  // main field's options — start fresh.
                  _updateField(index, (f) => f.copyWith(mappedFrom: v, valueMap: const {}));
                },
              ),
            ),
          ],
        ),
        if (candidates.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'No enabled, editable dropdown fields available to map from yet.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13),
            ),
          ),
        if (mainField != null) ...[
          const SizedBox(height: 8),
          const Text('Values (blank = not derived for that option)',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
          const SizedBox(height: 4),
          for (final opt in mainField.options)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: [
                  Expanded(
                    flex: 2,
                    child: Text(opt.value, overflow: TextOverflow.ellipsis),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 8),
                    child: Icon(Icons.arrow_forward, size: 16),
                  ),
                  Expanded(
                    flex: 3,
                    child: TextFormField(
                      key: ValueKey('map_${field.id}_${opt.value}'),
                      initialValue: field.valueMap[opt.value] ?? '',
                      decoration: const InputDecoration(isDense: true),
                      onChanged: (v) => _updateField(index, (f) {
                        final map = Map<String, String>.of(f.valueMap);
                        if (v.trim().isEmpty) {
                          map.remove(opt.value);
                        } else {
                          map[opt.value] = v;
                        }
                        return f.copyWith(valueMap: map);
                      }),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }

  Widget _optionsEditor(int index, TemplateField field) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 8),
        const Text('Options', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        if (field.options.isEmpty)
          Text('No options yet.',
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                  fontSize: 13)),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final opt in field.options)
              InputChip(
                label: Text(opt.value),
                onDeleted: () => _updateField(
                  index,
                  (f) => f.copyWith(
                    options: f.options.where((o) => o.value != opt.value).toList(),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _newOptionControllers[field.id],
                decoration: const InputDecoration(labelText: 'New option', isDense: true),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                final ctl = _newOptionControllers[field.id]!;
                final text = ctl.text.trim();
                if (text.isEmpty) return;
                if (field.options.any((o) => o.value == text)) return;
                _updateField(
                  index,
                  (f) => f.copyWith(options: [...f.options, TemplateOption(value: text)]),
                );
                ctl.clear();
              },
              child: const Text('Add'),
            ),
          ],
        ),
      ],
    );
  }
}
