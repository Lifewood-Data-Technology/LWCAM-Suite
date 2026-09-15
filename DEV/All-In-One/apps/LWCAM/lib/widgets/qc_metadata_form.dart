import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/qc_review_controller.dart';
import '../models/qc_task.dart';

/// The metadata panel of the review screen.
///
/// Renders whatever the project's template declares rather than a fixed list of
/// inputs: each project decides which fields exist, which are mandatory, which
/// are dropdowns and which are pinned constants. Hard-coding them here would
/// mean a template change in LWCam Admin silently not reaching QC.
///
/// Every edit goes to the reviewer's DRAFT. Nothing touches `capture_folders`
/// until the task is approved.
class QcMetadataForm extends StatelessWidget {
  const QcMetadataForm({super.key, required this.controller});

  final QcReviewController controller;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final task = controller.task.value;
      if (task == null) return const SizedBox.shrink();
      final fields = task.template.fields;
      final claimed = task.assignedTo != null;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _Header(controller: controller, claimed: claimed),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              children: [
                if (fields.isEmpty)
                  const Text('This project has no metadata template.')
                else
                  for (final field in fields)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: _Field(
                        field: field,
                        controller: controller,
                        // Reading is open to anyone who can see the folder;
                        // editing needs the lock, so an unclaimed task shows the
                        // values but refuses input rather than losing the edit
                        // at save time.
                        enabled: claimed,
                      ),
                    ),
              ],
            ),
          ),
        ],
      );
    });
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.controller, required this.claimed});

  final QcReviewController controller;
  final bool claimed;

  // Its own Obx. The panel's Obx closure only reads `task`, and this widget's
  // build runs outside that closure, so `dirty`/`saving` got no subscriber and
  // Save draft stayed greyed out after a real edit. Same trap the page strip
  // hit - see the comment on _PageStrip in qc_review_page.dart.
  @override
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final missing = controller.missingMandatory;

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
              Text('Metadata', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(width: 8),
              if (controller.dirty.value)
                Text(
                  'unsaved',
                  style: TextStyle(fontSize: 11, color: scheme.error),
                )
              else if (controller.task.value?.draftMetadataDirty ?? false)
                Text(
                  'draft saved',
                  style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
                ),
              const Spacer(),
              FilledButton(
                onPressed: claimed &&
                        controller.dirty.value &&
                        !controller.saving.value
                    ? () async {
                        final ok = await controller.save();
                        if (!ok) return;
                      }
                    : null,
                child: Text(controller.saving.value ? 'Saving…' : 'Save draft'),
              ),
            ],
          ),
          if (!claimed)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                controller.isSettled
                    ? 'This folder is completed. Its metadata is read only.'
                    : 'Claim this task to edit its metadata.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ),
          if (claimed && missing.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Still required: ${missing.map((f) => f.label).join(', ')}',
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
          if (controller.error.value.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                controller.error.value,
                style: TextStyle(fontSize: 12, color: scheme.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.field,
    required this.controller,
    required this.enabled,
  });

  final QcMetadataField field;
  final QcReviewController controller;
  final bool enabled;

  // Its own Obx, for the same reason as _Header: a field derived from another
  // one is written into `form` by setField, and without a subscriber here the
  // panel kept showing the value the PREVIOUS title mapped to. The Title
  // dropdown looked like it had changed regardless, because a
  // DropdownButtonFormField keeps its own FormField state - which is what made
  // this read as "the mapping does not work" rather than "the panel did not
  // repaint".
  @override
  Widget build(BuildContext context) => Obx(() => _build(context));

  Widget _build(BuildContext context) {
    final value = controller.form[field.key];
    final label = field.mandatory ? '${field.label} *' : field.label;

    // Pinned by the project - the engine overwrites whatever is sent, so showing
    // an editable box would be a lie.
    if (field.isFixed) {
      // No note. A fixed field is already visibly uneditable, and repeating
      // "set by the project" under six of them in a row cost more vertical
      // space than the metadata could spare - the form is meant to be read in
      // one look, not scrolled.
      return _ReadOnly(label: label, value: field.value ?? '');
    }

    // Derived from another field on every save, by the project's own mapping.
    // Which fields those are is the template's decision - Record Type is the
    // usual one, but a project can equally map Start Date from Title.
    if (field.isMapped) {
      final source = controller.task.value?.template.fieldFor(field.mappedFrom ?? '');
      return _ReadOnly(
        label: label,
        value: value ?? '',
        note: source == null
            ? 'derived by the project'
            : 'derived from the ${source.label.toLowerCase()}',
      );
    }

    if (field.isSelect) {
      // A value already keyed that is no longer in the template must remain
      // selectable, or opening an older folder would silently blank it.
      final options = <String>[
        ...field.options,
        if (value != null && value.isNotEmpty && !field.options.contains(value))
          value,
      ];
      return DropdownButtonFormField<String?>(
        initialValue: value,
        isExpanded: true,
        // Matches the TextFormField below: Flutter defaults a dropdown to
        // titleMedium (14) and a text field to bodyLarge (16), so without this
        // the dropdown rows in this form render smaller than the typed ones.
        style: Theme.of(context).textTheme.bodyLarge,
        decoration: InputDecoration(labelText: label, isDense: true),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('—')),
          for (final option in options)
            DropdownMenuItem<String?>(value: option, child: Text(option)),
        ],
        onChanged: enabled ? (v) => controller.setField(field.key, v) : null,
      );
    }

    return TextFormField(
      // Includes the adopt revision: without it the field keeps the text it was
      // built with, so applying an AI suggestion changed the draft and left the
      // old value on screen. Not the value itself - that would rebuild on every
      // keystroke and take the cursor with it.
      key: ValueKey('${field.key}-${controller.task.value?.folderId}'
          '-${controller.formRevision.value}'),
      initialValue: value,
      enabled: enabled,
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
      ),
      onChanged: (v) => controller.setField(field.key, v),
    );
  }
}

class _ReadOnly extends StatelessWidget {
  const _ReadOnly({
    required this.label,
    required this.value,
    this.note,
  });

  final String label;
  final String value;
  final String? note;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Greyed but readable, which is a narrower target than it sounds. Setting
    // `enabled: false` on the decoration is the obvious way to grey a field and
    // the wrong one: Flutter then drops the value text to 38% alpha, which is
    // "disabled" rather than "still viewable" - and the value is the whole point
    // of showing a locked field at all. So the ground, border and labels are
    // muted explicitly and the value keeps full contrast.
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        filled: true,
        // System-derived = Sea Salt (surfaceContainerLow in light), so it
        // scans apart from the white editable fields beside it.
        fillColor: scheme.surfaceContainerLow,
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
        helperText: note,
        helperStyle: TextStyle(color: scheme.onSurfaceVariant),
        // The lock says "not yours to change" without the vertical cost of a
        // note under every one of them - see the comment at the call site.
        suffixIcon: Icon(
          Icons.lock_outline,
          size: 18,
          color: scheme.onSurfaceVariant,
        ),
        suffixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 24),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      child: Text(value.isEmpty ? '—' : value),
    );
  }
}
