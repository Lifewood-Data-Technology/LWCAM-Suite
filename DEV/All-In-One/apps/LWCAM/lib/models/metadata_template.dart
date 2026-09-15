/// Per-project metadata template (spec §8, plan "Per-project Metadata
/// Templates"). Pure Dart — no Flutter/GetX/DB imports, matching the
/// batch_metadata.dart / capture_box_models.dart convention.
///
/// A template configures, per field: enabled on/off, its MODE, free text vs
/// dropdown (editable mode), the dropdown options, mandatory-ness, and the
/// display order (= position within [MetadataTemplate.fields]).
///
/// Every field is one of three modes:
///  - **editable** — appears on the operator form; the operator keys it.
///  - **fixed** — never on the form; a constant [TemplateField.fixedValue].
///  - **mapped** — never keyed; its value is looked up from a MAIN field's
///    selected value via [TemplateField.valueMap] (e.g. Record Type mapped
///    from Title, spec §8.4). The main field must be an enabled, editable,
///    dropdown field — which keeps mappings one level deep (no chains).
///    Mapped fields show as a read-only "derived" tile under their main
///    field on the operator form; an unmapped/blank main value derives blank.
///
/// The field universe is fixed to 14 fields: 8 keyed fields backed by real
/// [CaptureFolder] columns (the spec §8.1 seven + Record Type), and 6
/// fixed-only fields (spec §8.3) with no per-folder storage — those can be
/// fixed or mapped, never editable.
library;

import 'dart:convert';

import 'capture_box_models.dart' show CaptureFolder;

// ── Field ids (stable JSON keys) ────────────────────────────────────────────

/// The 8 fields with real CaptureFolder storage.
const kCoverTagFieldId = 'coverTag';
const kImageTagsFieldId = 'imageTags';
const kTitleFieldId = 'title';
const kVolumeFieldId = 'volume';
const kStartDateFieldId = 'startDate';
const kEndDateFieldId = 'endDate';
const kArchivalRefNoFieldId = 'archivalRefNo';
const kRecordTypeFieldId = 'recordType';

/// The 6 fixed-only fields (spec §8.3) — no per-folder storage; they can be
/// fixed (a constant) or mapped (derived from a main field), never editable.
const kPlaceFieldId = 'place';
const kLanguageFieldId = 'language';
const kRecordCustodianFieldId = 'recordCustodian';
const kDigitizingEntityFieldId = 'digitizingEntity';
const kCaptureOperatorIdFieldId = 'captureOperatorId';
const kCaptureOperatorNameFieldId = 'captureOperatorName';

// ── Field modes ─────────────────────────────────────────────────────────────

const kModeEditable = 'editable';
const kModeFixed = 'fixed';
const kModeMapped = 'mapped';

/// Ids of the 8 keyed (folder-backed) fields — the only ones a template may
/// make editable (appearing on the operator form).
const Set<String> kKeyedFieldIds = {
  kCoverTagFieldId,
  kImageTagsFieldId,
  kTitleFieldId,
  kVolumeFieldId,
  kStartDateFieldId,
  kEndDateFieldId,
  kArchivalRefNoFieldId,
  kRecordTypeFieldId,
};

/// Ids of the 6 fixed-only (spec §8.3) fields.
const Set<String> kFixedOnlyFieldIds = {
  kPlaceFieldId,
  kLanguageFieldId,
  kRecordCustodianFieldId,
  kDigitizingEntityFieldId,
  kCaptureOperatorIdFieldId,
  kCaptureOperatorNameFieldId,
};

/// Default display label per field id (used by [MetadataTemplate.standard]
/// and available to the template editor for any field it renders generically).
const Map<String, String> kDefaultFieldLabels = {
  kCoverTagFieldId: 'Cover Tag',
  kImageTagsFieldId: 'Image Tags',
  kTitleFieldId: 'Title',
  kVolumeFieldId: 'Volume',
  kStartDateFieldId: 'Start Date',
  kEndDateFieldId: 'End Date',
  kArchivalRefNoFieldId: 'Archival Reference Number',
  kRecordTypeFieldId: 'Record Type',
  kPlaceFieldId: 'Place',
  kLanguageFieldId: 'Language',
  kRecordCustodianFieldId: 'Record Custodian',
  kDigitizingEntityFieldId: 'Digitizing Entity',
  kCaptureOperatorIdFieldId: 'Capture Operator ID',
  kCaptureOperatorNameFieldId: 'Capture Operator Name',
};

/// CSV column name (and upload_records column name) for each of the 6
/// fixed-only fields — the SINGLE source shared by the CSV header, the CSV
/// row builder, and the DB schema so they can never drift out of sync.
/// (Record Type is NOT here — it has always had its own `record_type` column
/// among the original 8 metadata columns.)
const List<String> kFixedFieldCsvColumns = [
  'place',
  'language',
  'record_custodian',
  'digitizing_entity',
  'capture_operator_id',
  'capture_operator_name',
];

/// CSV/DB column → field id for the 6 fixed-only fields.
const Map<String, String> kFixedFieldIdByCsvColumn = {
  'place': kPlaceFieldId,
  'language': kLanguageFieldId,
  'record_custodian': kRecordCustodianFieldId,
  'digitizing_entity': kDigitizingEntityFieldId,
  'capture_operator_id': kCaptureOperatorIdFieldId,
  'capture_operator_name': kCaptureOperatorNameFieldId,
};

// ── Standard-template values reproduced from the legacy hardcoded constants
// (batch_metadata.dart) — MetadataTemplate.standard() is the one place these
// now live; batch_metadata.dart's copies remain only as the independent
// parity source metadata_template_test.dart checks against. ───────────────

const List<String> _standardCoverTagValues = [
  'Cover Will Be Captured',
  'Cover Will not Be Captured',
  'Cover Unavailable or Missing',
];

const List<String> _standardImageTagsValues = [
  'Faded or Damaged Documents',
  'Reflective Surface',
  'Document Glued Together',
];

/// Title → Record Type (spec §8.4). Reproduced as the standard template's
/// Record Type field mapping (mode: mapped, mappedFrom: title).
const Map<String, String> kStandardTitleToRecordType = {
  'WWI South African Mounted Rifles Military Indexes': 'Military Service Record Indexes',
  'WWI South African Mounted Rifles Military Personnel Cards': 'Military Service Records',
  'WWI Medical Files': 'Military Medical Records',
  'WWII Medical Files': 'Military Medical Records',
};

const List<String> _standardStartDateValues = ['1914', '1939'];
const List<String> _standardEndDateValues = ['1918', '1945'];

bool _isBlank(String? s) => s == null || s.trim().isEmpty;

// ── TemplateOption ───────────────────────────────────────────────────────────

/// One dropdown choice.
class TemplateOption {
  final String value;

  const TemplateOption({required this.value});

  TemplateOption copyWith({String? value}) => TemplateOption(value: value ?? this.value);

  /// Plain string in JSON. [fromJson] also accepts the earlier
  /// `{'v': ..., 'rt': ...}` map form (per-option Record Type, superseded by
  /// generic field mappings) — the 'rt' payload is simply ignored.
  Object toJson() => value;

  factory TemplateOption.fromJson(Object? json) {
    if (json is Map) {
      return TemplateOption(value: json['v']?.toString() ?? '');
    }
    return TemplateOption(value: json?.toString() ?? '');
  }
}

// ── TemplateField ────────────────────────────────────────────────────────────

class TemplateField {
  final String id;
  final String label;
  final bool enabled;

  /// One of [kModeEditable], [kModeFixed], [kModeMapped].
  final String mode;

  /// 'freeText' | 'dropdown'. Meaningful in editable mode only, but kept
  /// when the mode changes so toggling back restores it.
  final String inputType;

  /// The constant exported in fixed mode.
  final String? fixedValue;

  /// Mapped mode: id of the MAIN field this one derives from. Must resolve
  /// to an enabled, editable, dropdown field (the editor enforces this; the
  /// resolver degrades to null otherwise).
  final String? mappedFrom;

  /// Mapped mode: main field's option value → this field's derived value.
  /// A main value with no entry derives blank (allowed by design).
  final Map<String, String> valueMap;

  final bool mandatory;
  final List<TemplateOption> options;

  const TemplateField({
    required this.id,
    required this.label,
    this.enabled = true,
    this.mode = kModeEditable,
    this.inputType = 'freeText',
    this.fixedValue,
    this.mappedFrom,
    this.valueMap = const {},
    this.mandatory = false,
    this.options = const [],
  });

  /// True for the 8 fields with real CaptureFolder storage — the only ones
  /// that can be editable.
  bool get isKeyedField => kKeyedFieldIds.contains(id);

  bool get isEditable => mode == kModeEditable;
  bool get isFixed => mode == kModeFixed;
  bool get isMapped => mode == kModeMapped;
  bool get isDropdown => inputType == 'dropdown';

  TemplateField copyWith({
    String? label,
    bool? enabled,
    String? mode,
    String? inputType,
    String? fixedValue,
    bool clearFixedValue = false,
    String? mappedFrom,
    bool clearMappedFrom = false,
    Map<String, String>? valueMap,
    bool? mandatory,
    List<TemplateOption>? options,
  }) {
    return TemplateField(
      id: id,
      label: label ?? this.label,
      enabled: enabled ?? this.enabled,
      mode: mode ?? this.mode,
      inputType: inputType ?? this.inputType,
      fixedValue: clearFixedValue ? null : (fixedValue ?? this.fixedValue),
      mappedFrom: clearMappedFrom ? null : (mappedFrom ?? this.mappedFrom),
      valueMap: valueMap ?? this.valueMap,
      mandatory: mandatory ?? this.mandatory,
      options: options ?? this.options,
    );
  }

  Map<String, Object?> toJson() => {
    'id': id,
    'label': label,
    'enabled': enabled,
    'mode': mode,
    'inputType': inputType,
    'fixedValue': fixedValue,
    'mappedFrom': mappedFrom,
    'valueMap': valueMap,
    'mandatory': mandatory,
    'options': options.map((o) => o.toJson()).toList(),
  };

  factory TemplateField.fromJson(Map<String, Object?> json) {
    final id = json['id']?.toString() ?? '';
    final rawOptions = (json['options'] as List?) ?? const [];
    final rawValueMap = (json['valueMap'] as Map?) ?? const {};
    // Mode with legacy fallback: snapshots written before modes existed carry
    // a `fixed` bool instead.
    var mode = json['mode']?.toString() ??
        ((json['fixed'] as bool? ?? false) ? kModeFixed : kModeEditable);
    if (!const {kModeEditable, kModeFixed, kModeMapped}.contains(mode)) {
      mode = kModeEditable;
    }
    // Fixed-only fields (no folder storage) can never be editable —
    // defensive against a hand-edited/corrupt store.
    if (kFixedOnlyFieldIds.contains(id) && mode == kModeEditable) {
      mode = kModeFixed;
    }
    return TemplateField(
      id: id,
      label: json['label']?.toString() ?? kDefaultFieldLabels[id] ?? id,
      enabled: json['enabled'] as bool? ?? true,
      mode: mode,
      inputType: json['inputType']?.toString() ?? 'freeText',
      fixedValue: json['fixedValue']?.toString(),
      mappedFrom: json['mappedFrom']?.toString(),
      valueMap: {
        for (final e in rawValueMap.entries) e.key.toString(): e.value?.toString() ?? '',
      },
      mandatory: json['mandatory'] as bool? ?? false,
      options: rawOptions.map(TemplateOption.fromJson).toList(),
    );
  }
}

// ── MetadataTemplate ─────────────────────────────────────────────────────────

class MetadataTemplate {
  static const int currentVersion = 2;

  final int version;
  final List<TemplateField> fields;

  const MetadataTemplate({this.version = currentVersion, this.fields = const []});

  /// The built-in template reproducing today's hardcoded behaviour + the
  /// spec §8.3 fixed values + Record Type mapped from Title per §8.4. This
  /// is what a `null` [Project.template], and any box whose snapshot fails
  /// to parse, fall back to.
  factory MetadataTemplate.standard() {
    return MetadataTemplate(
      fields: [
        TemplateField(
          id: kCoverTagFieldId,
          label: kDefaultFieldLabels[kCoverTagFieldId]!,
          inputType: 'dropdown',
          mandatory: true,
          options: _standardCoverTagValues.map((v) => TemplateOption(value: v)).toList(),
        ),
        TemplateField(
          id: kTitleFieldId,
          label: kDefaultFieldLabels[kTitleFieldId]!,
          inputType: 'dropdown',
          mandatory: true,
          options:
              kStandardTitleToRecordType.keys.map((v) => TemplateOption(value: v)).toList(),
        ),
        // Record Type derived from Title (spec §8.4) — its own field, mapped.
        const TemplateField(
          id: kRecordTypeFieldId,
          label: 'Record Type',
          mode: kModeMapped,
          mappedFrom: kTitleFieldId,
          valueMap: kStandardTitleToRecordType,
        ),
        TemplateField(
          id: kVolumeFieldId,
          label: kDefaultFieldLabels[kVolumeFieldId]!,
          mandatory: true,
        ),
        TemplateField(
          id: kStartDateFieldId,
          label: kDefaultFieldLabels[kStartDateFieldId]!,
          inputType: 'dropdown',
          mandatory: true,
          options: _standardStartDateValues.map((v) => TemplateOption(value: v)).toList(),
        ),
        TemplateField(
          id: kEndDateFieldId,
          label: kDefaultFieldLabels[kEndDateFieldId]!,
          inputType: 'dropdown',
          mandatory: true,
          options: _standardEndDateValues.map((v) => TemplateOption(value: v)).toList(),
        ),
        TemplateField(
          id: kImageTagsFieldId,
          label: kDefaultFieldLabels[kImageTagsFieldId]!,
          inputType: 'dropdown',
          options: _standardImageTagsValues.map((v) => TemplateOption(value: v)).toList(),
        ),
        TemplateField(
          id: kArchivalRefNoFieldId,
          label: kDefaultFieldLabels[kArchivalRefNoFieldId]!,
        ),
        TemplateField(
          id: kPlaceFieldId,
          label: kDefaultFieldLabels[kPlaceFieldId]!,
          mode: kModeFixed,
          fixedValue: 'South Africa',
        ),
        TemplateField(
          id: kLanguageFieldId,
          label: kDefaultFieldLabels[kLanguageFieldId]!,
          mode: kModeFixed,
          fixedValue: 'English',
        ),
        TemplateField(
          id: kRecordCustodianFieldId,
          label: kDefaultFieldLabels[kRecordCustodianFieldId]!,
          mode: kModeFixed,
          fixedValue: 'South Africa Department of Defense',
        ),
        TemplateField(
          id: kDigitizingEntityFieldId,
          label: kDefaultFieldLabels[kDigitizingEntityFieldId]!,
          mode: kModeFixed,
          fixedValue: 'Lifewood',
        ),
        TemplateField(
          id: kCaptureOperatorIdFieldId,
          label: kDefaultFieldLabels[kCaptureOperatorIdFieldId]!,
          mode: kModeFixed,
          fixedValue: 'cis.user.MM38-RXW3',
        ),
        TemplateField(
          id: kCaptureOperatorNameFieldId,
          label: kDefaultFieldLabels[kCaptureOperatorNameFieldId]!,
          mode: kModeFixed,
          fixedValue: 'lifewoodza01',
        ),
      ],
    );
  }

  /// Parses a stored snapshot (`CaptureBox.templateJson`) or a project's live
  /// template JSON string; null, empty, or malformed JSON all fall back to
  /// [standard] rather than throwing — a box must always be able to open.
  static MetadataTemplate fromJsonStringOrStandard(String? jsonString) {
    if (jsonString == null || jsonString.trim().isEmpty) return MetadataTemplate.standard();
    try {
      final decoded = jsonDecode(jsonString);
      if (decoded is! Map) return MetadataTemplate.standard();
      return MetadataTemplate.fromJson(decoded.cast<String, Object?>());
    } catch (_) {
      return MetadataTemplate.standard();
    }
  }

  Map<String, Object?> toJson() => {
    'version': version,
    'fields': fields.map((f) => f.toJson()).toList(),
  };

  factory MetadataTemplate.fromJson(Map<String, Object?> json) {
    final rawFields = (json['fields'] as List?) ?? const [];
    return MetadataTemplate(
      version: (json['version'] as num?)?.toInt() ?? currentVersion,
      fields: rawFields
          .whereType<Map>()
          .map((e) => TemplateField.fromJson(e.cast<String, Object?>()))
          .toList(),
    );
  }

  // ── Lookups ────────────────────────────────────────────────────────────

  TemplateField? fieldById(String id) {
    for (final f in fields) {
      if (f.id == id) return f;
    }
    return null;
  }

  /// Fields that appear (editable) on the operator form, in display order.
  List<TemplateField> get orderedFormFields =>
      fields.where((f) => f.enabled && f.isEditable).toList();

  /// Enabled mapped fields deriving from [mainFieldId], in display order —
  /// the operator form renders one read-only "derived" tile per entry,
  /// directly under the main field.
  List<TemplateField> mappedFieldsFor(String mainFieldId) =>
      fields.where((f) => f.enabled && f.isMapped && f.mappedFrom == mainFieldId).toList();

  /// Resolves a MAPPED field's derived value for a given main-field value —
  /// used by the operator form for live derived tiles (the main value comes
  /// from in-progress form state, not the stored folder).
  String? mappedValueFor(TemplateField mapped, String? mainValue) {
    if (mainValue == null) return null;
    final v = mapped.valueMap[mainValue.trim()];
    return _isBlank(v) ? null : v;
  }

  /// Raw stored value of a keyed field on [folder] — null for a fixed-only
  /// field id (no folder storage) or an unrecognized id.
  String? keyedValueOf(String fieldId, CaptureFolder folder) {
    switch (fieldId) {
      case kCoverTagFieldId:
        return folder.coverTag;
      case kImageTagsFieldId:
        return folder.imageTags;
      case kTitleFieldId:
        return folder.title;
      case kVolumeFieldId:
        return folder.volume;
      case kStartDateFieldId:
        return folder.startDate;
      case kEndDateFieldId:
        return folder.endDate;
      case kArchivalRefNoFieldId:
        return folder.archivalRefNo;
      case kRecordTypeFieldId:
        return folder.recordType;
      default:
        return null;
    }
  }

  /// The value that should actually be used/exported for [fieldId]:
  /// disabled → null; fixed → the constant; mapped → looked up from the main
  /// field's effective value; editable → the keyed value. Mapping resolution
  /// is deliberately one level deep: the main field must itself be editable,
  /// so a mapped-from-mapped chain degrades to null instead of recursing.
  String? effectiveValueOf(String fieldId, CaptureFolder folder) {
    final field = fieldById(fieldId);
    if (field == null || !field.enabled) return null;
    if (field.isFixed) return field.fixedValue;
    if (field.isMapped) {
      final mainId = field.mappedFrom;
      if (mainId == null || mainId == field.id) return null;
      final main = fieldById(mainId);
      if (main == null || !main.enabled || !main.isEditable) return null;
      return mappedValueFor(field, keyedValueOf(mainId, folder));
    }
    return keyedValueOf(fieldId, folder);
  }

  /// Effective value of one of the 6 fixed-only CSV columns (see
  /// [kFixedFieldCsvColumns]) for [folder]. Per-folder because a §8.3 field
  /// may be MAPPED (e.g. Language mapped from Title), which varies by folder.
  String? fixedCsvValueOf(String csvColumn, CaptureFolder folder) {
    final fieldId = kFixedFieldIdByCsvColumn[csvColumn];
    if (fieldId == null) return null;
    return effectiveValueOf(fieldId, folder);
  }

  /// Rebuilds [folder] with [values] (fieldId -> new value, only for fields
  /// that appear on the form) applied; any keyed field not present in
  /// [values] (disabled/fixed/mapped in this template) passes through
  /// unchanged. Mirrors the direct-construction pattern the dialog already
  /// used (not CaptureFolder.copyWith, which cannot clear a field to null).
  CaptureFolder applyValues(CaptureFolder base, Map<String, String?> values) {
    String? pick(String fieldId, String? baseValue) =>
        values.containsKey(fieldId) ? values[fieldId] : baseValue;
    return CaptureFolder(
      id: base.id,
      boxId: base.boxId,
      folderSeq: base.folderSeq,
      coverTag: pick(kCoverTagFieldId, base.coverTag),
      imageTags: pick(kImageTagsFieldId, base.imageTags),
      title: pick(kTitleFieldId, base.title),
      volume: pick(kVolumeFieldId, base.volume),
      startDate: pick(kStartDateFieldId, base.startDate),
      endDate: pick(kEndDateFieldId, base.endDate),
      archivalRefNo: pick(kArchivalRefNoFieldId, base.archivalRefNo),
      recordType: pick(kRecordTypeFieldId, base.recordType),
      folderName: base.folderName,
      createdAt: base.createdAt,
      updatedAt: base.updatedAt,
    );
  }

  /// Mandatory fields still missing/invalid on [folder], per this template.
  /// Only EDITABLE fields are validated (fixed fields always have a value;
  /// mapped fields derive automatically; disabled fields aren't collected).
  /// A dropdown field's stored value must still be one of the CURRENT
  /// options to count as present — this is what makes a "keep-but-flag"
  /// stale value (an option removed from the template after keying) block
  /// the transfer gate without the dialog having destroyed the data.
  List<String> missingMandatoryFieldsOf(CaptureFolder folder) {
    final missing = <String>[];
    for (final field in fields) {
      if (!field.enabled || !field.isEditable || !field.mandatory) continue;
      final raw = keyedValueOf(field.id, folder);
      if (field.isDropdown) {
        final values = field.options.map((o) => o.value).toSet();
        if (raw == null || !values.contains(raw)) missing.add(field.label);
      } else {
        if (_isBlank(raw)) missing.add(field.label);
      }
    }
    return missing;
  }

  bool isCompleteOf(CaptureFolder folder) => missingMandatoryFieldsOf(folder).isEmpty;
}
