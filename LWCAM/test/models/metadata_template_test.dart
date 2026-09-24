import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/batch_metadata.dart'
    show kCoverTagValues, kImageTagsValues, kTitleValues, recordTypeForTitle;
import 'package:lwcam/models/capture_box_models.dart';
import 'package:lwcam/models/metadata_template.dart';

void main() {
  group('MetadataTemplate.standard() parity with legacy constants', () {
    final tpl = MetadataTemplate.standard();

    test('dropdown option lists match the old k-constants', () {
      expect(tpl.fieldById(kCoverTagFieldId)!.options.map((o) => o.value).toList(),
          kCoverTagValues);
      expect(tpl.fieldById(kImageTagsFieldId)!.options.map((o) => o.value).toList(),
          kImageTagsValues);
      expect(
          tpl.fieldById(kTitleFieldId)!.options.map((o) => o.value).toList(), kTitleValues);
      // The standard template SEEDS these years as plain option data; the
      // fields themselves are ordinary dropdown-or-free-text fields.
      expect(tpl.fieldById(kStartDateFieldId)!.options.map((o) => o.value).toList(),
          ['1914', '1939']);
      expect(tpl.fieldById(kEndDateFieldId)!.options.map((o) => o.value).toList(),
          ['1918', '1945']);
    });

    test('Record Type is its own mapped field, matching the legacy §8.4 map', () {
      final recordTypeField = tpl.fieldById(kRecordTypeFieldId)!;
      expect(recordTypeField.isMapped, isTrue);
      expect(recordTypeField.mappedFrom, kTitleFieldId);
      for (final title in kTitleValues) {
        expect(recordTypeField.valueMap[title], recordTypeForTitle(title));
      }
    });

    test('effectiveValueOf(recordType) derives from Title exactly like the legacy map', () {
      for (final title in kTitleValues) {
        final f = CaptureFolder(boxId: 1, title: title);
        expect(tpl.effectiveValueOf(kRecordTypeFieldId, f), recordTypeForTitle(title));
      }
      final unknown = CaptureFolder(boxId: 1, title: 'Some Unknown Title');
      expect(tpl.effectiveValueOf(kRecordTypeFieldId, unknown), isNull);
      final blank = const CaptureFolder(boxId: 1);
      expect(tpl.effectiveValueOf(kRecordTypeFieldId, blank), isNull);
    });

    test('fixed fields carry the spec §8.3 values and are excluded from the form', () {
      expect(tpl.fieldById(kPlaceFieldId)!.fixedValue, 'South Africa');
      expect(tpl.fieldById(kLanguageFieldId)!.fixedValue, 'English');
      expect(tpl.fieldById(kRecordCustodianFieldId)!.fixedValue,
          'South Africa Department of Defense');
      expect(tpl.fieldById(kDigitizingEntityFieldId)!.fixedValue, 'Lifewood');
      expect(tpl.fieldById(kCaptureOperatorIdFieldId)!.fixedValue, 'cis.user.MM38-RXW3');
      expect(tpl.fieldById(kCaptureOperatorNameFieldId)!.fixedValue, 'lifewoodza01');
      for (final id in kFixedOnlyFieldIds) {
        expect(tpl.fieldById(id)!.isFixed, isTrue);
        expect(tpl.orderedFormFields.any((f) => f.id == id), isFalse);
      }
    });

    test('orderedFormFields reproduces the legacy dialog order (Record Type excluded — mapped)',
        () {
      expect(tpl.orderedFormFields.map((f) => f.id).toList(), [
        kCoverTagFieldId,
        kTitleFieldId,
        kVolumeFieldId,
        kStartDateFieldId,
        kEndDateFieldId,
        kImageTagsFieldId,
        kArchivalRefNoFieldId,
      ]);
    });

    test('missingMandatoryFieldsOf matches the removed getter, exact label order', () {
      // All blank.
      expect(tpl.missingMandatoryFieldsOf(const CaptureFolder(boxId: 1)),
          ['Cover Tag', 'Title', 'Volume', 'Start Date', 'End Date']);

      // Partial + one invalid dropdown value.
      final partial = CaptureFolder(
        boxId: 1,
        coverTag: kCoverTagValues.first,
        title: 'Not a real title',
        volume: '  ',
        startDate: '1914',
      );
      expect(tpl.missingMandatoryFieldsOf(partial), ['Title', 'Volume', 'End Date']);

      // Complete.
      final complete = CaptureFolder(
        boxId: 1,
        coverTag: kCoverTagValues.first,
        title: kTitleValues.first,
        volume: 'ABC file no. 1',
        startDate: '1914',
        endDate: '1918',
      );
      expect(tpl.missingMandatoryFieldsOf(complete), isEmpty);
      expect(tpl.isCompleteOf(complete), isTrue);
    });

    test('optional dropdown (imageTags) is never validated for membership', () {
      final f = CaptureFolder(
        boxId: 1,
        coverTag: kCoverTagValues.first,
        title: kTitleValues.first,
        volume: 'ABC file no. 1',
        startDate: '1914',
        endDate: '1918',
        imageTags: 'not a real option',
      );
      expect(tpl.isCompleteOf(f), isTrue);
    });

    test('Record Type (mapped) is never validated as mandatory even though it never has a value',
        () {
      // Record Type has mandatory:false by default anyway, but the key
      // invariant is that mapped fields are skipped regardless of mandatory.
      final f = CaptureFolder(boxId: 1, title: 'Some Unknown Title');
      expect(tpl.missingMandatoryFieldsOf(f), isNot(contains('Record Type')));
    });
  });

  group('TemplateOption JSON', () {
    test('encodes as a bare string', () {
      const option = TemplateOption(value: 'X');
      expect(option.toJson(), 'X');
      final back = TemplateOption.fromJson(option.toJson());
      expect(back.value, 'X');
    });

    test('fromJson tolerates the legacy {v,rt} map form, ignoring rt', () {
      final back = TemplateOption.fromJson({'v': 'X', 'rt': 'Y'});
      expect(back.value, 'X');
    });
  });

  group('MetadataTemplate JSON round-trip', () {
    test('MetadataTemplate.standard() round-trips through JSON unchanged', () {
      final tpl = MetadataTemplate.standard();
      final back = MetadataTemplate.fromJson(tpl.toJson());
      expect(back.fields.length, tpl.fields.length);
      for (var i = 0; i < tpl.fields.length; i++) {
        expect(back.fields[i].id, tpl.fields[i].id);
        expect(back.fields[i].mode, tpl.fields[i].mode);
        expect(back.fields[i].mandatory, tpl.fields[i].mandatory);
        expect(back.fields[i].mappedFrom, tpl.fields[i].mappedFrom);
        expect(back.fields[i].valueMap, tpl.fields[i].valueMap);
        expect(back.fields[i].options.map((o) => o.value).toList(),
            tpl.fields[i].options.map((o) => o.value).toList());
      }
      // Behaviour survives the round-trip too.
      final f = CaptureFolder(boxId: 1, title: kTitleValues.first);
      expect(back.effectiveValueOf(kRecordTypeFieldId, f),
          tpl.effectiveValueOf(kRecordTypeFieldId, f));
    });

    test('fromJsonStringOrStandard falls back to standard() on null/empty/malformed input', () {
      final std = MetadataTemplate.standard();
      for (final bad in [null, '', '   ', 'not json', '{"fields": "not a list but ok"}', '[]']) {
        final result = MetadataTemplate.fromJsonStringOrStandard(bad);
        expect(result.fields.length, std.fields.length);
        expect(result.orderedFormFields.map((f) => f.id).toList(),
            std.orderedFormFields.map((f) => f.id).toList());
      }
    });

    test('fromJsonStringOrStandard parses a real snapshot', () {
      final tpl = MetadataTemplate.standard();
      final jsonString = jsonEncode(tpl.toJson());
      final back = MetadataTemplate.fromJsonStringOrStandard(jsonString);
      expect(back.fields.length, tpl.fields.length);
    });

    test('a fixed-only field id is forced to fixed mode even if JSON says otherwise', () {
      final tampered = MetadataTemplate(fields: [
        const TemplateField(
            id: kPlaceFieldId, label: 'Place', mode: kModeEditable, fixedValue: 'X'),
      ]);
      final back = MetadataTemplate.fromJson(tampered.toJson());
      expect(back.fieldById(kPlaceFieldId)!.isFixed, isTrue);
    });

    test('legacy fixed:true/false JSON (pre-mode snapshots) maps to fixed/editable mode', () {
      final legacyFixed = MetadataTemplate.fromJson({
        'version': 1,
        'fields': [
          {'id': kCoverTagFieldId, 'label': 'Cover Tag', 'fixed': true, 'fixedValue': 'X'},
        ],
      });
      expect(legacyFixed.fieldById(kCoverTagFieldId)!.isFixed, isTrue);

      final legacyEditable = MetadataTemplate.fromJson({
        'version': 1,
        'fields': [
          {'id': kCoverTagFieldId, 'label': 'Cover Tag', 'fixed': false},
        ],
      });
      expect(legacyEditable.fieldById(kCoverTagFieldId)!.isEditable, isTrue);
    });

    test('an unrecognized mode string falls back to editable', () {
      final back = MetadataTemplate.fromJson({
        'version': 2,
        'fields': [
          {'id': kCoverTagFieldId, 'label': 'Cover Tag', 'mode': 'bogus'},
        ],
      });
      expect(back.fieldById(kCoverTagFieldId)!.isEditable, isTrue);
    });
  });

  group('Template variants: disabled / reorder', () {
    test('a disabled field never appears in orderedFormFields', () {
      final tpl = MetadataTemplate(fields: [
        const TemplateField(id: kArchivalRefNoFieldId, label: 'Archival Ref No', enabled: false),
      ]);
      expect(tpl.orderedFormFields, isEmpty);
    });

    test('a keyed field switched to fixed mode disappears from the form and is never validated',
        () {
      final tpl = MetadataTemplate(fields: [
        const TemplateField(
          id: kCoverTagFieldId,
          label: 'Cover Tag',
          mode: kModeFixed,
          fixedValue: 'Always This',
          mandatory: true,
        ),
      ]);
      expect(tpl.orderedFormFields, isEmpty);
      expect(tpl.fieldById(kCoverTagFieldId)!.isFixed, isTrue);
      // Never flagged missing even though mandatory=true and folder has no value.
      expect(tpl.missingMandatoryFieldsOf(const CaptureFolder(boxId: 1)), isEmpty);
    });

    test('field order follows list position (reorder)', () {
      final tpl = MetadataTemplate(fields: [
        const TemplateField(id: kVolumeFieldId, label: 'Volume', mandatory: true),
        const TemplateField(id: kCoverTagFieldId, label: 'Cover Tag', inputType: 'dropdown'),
      ]);
      expect(tpl.orderedFormFields.map((f) => f.id).toList(),
          [kVolumeFieldId, kCoverTagFieldId]);
    });

    test('an optional (non-mandatory) field is never listed as missing', () {
      final tpl = MetadataTemplate(fields: [
        const TemplateField(id: kArchivalRefNoFieldId, label: 'Archival Ref No'),
      ]);
      expect(tpl.missingMandatoryFieldsOf(const CaptureFolder(boxId: 1)), isEmpty);
    });
  });

  group('Mapped mode: generic field mappings', () {
    test('mappedFieldsFor returns enabled mapped fields deriving from the given main field', () {
      final tpl = MetadataTemplate(fields: [
        const TemplateField(
            id: kTitleFieldId, label: 'Title', inputType: 'dropdown', options: [
          TemplateOption(value: 'A'),
        ]),
        const TemplateField(
          id: kRecordTypeFieldId,
          label: 'Record Type',
          mode: kModeMapped,
          mappedFrom: kTitleFieldId,
          valueMap: {'A': 'Type A'},
        ),
        const TemplateField(
          id: kLanguageFieldId,
          label: 'Language',
          mode: kModeMapped,
          mappedFrom: kTitleFieldId,
          valueMap: {'A': 'English'},
        ),
      ]);
      expect(tpl.mappedFieldsFor(kTitleFieldId).map((f) => f.id).toSet(),
          {kRecordTypeFieldId, kLanguageFieldId});
      expect(tpl.mappedFieldsFor(kVolumeFieldId), isEmpty);
    });

    test('a disabled mapped field is excluded from mappedFieldsFor', () {
      final tpl = MetadataTemplate(fields: [
        const TemplateField(
          id: kRecordTypeFieldId,
          label: 'Record Type',
          enabled: false,
          mode: kModeMapped,
          mappedFrom: kTitleFieldId,
          valueMap: {'A': 'Type A'},
        ),
      ]);
      expect(tpl.mappedFieldsFor(kTitleFieldId), isEmpty);
    });

    test('mappedValueFor: a main value with no entry derives null (blank) — gaps allowed', () {
      const mapped = TemplateField(
        id: kRecordTypeFieldId,
        label: 'Record Type',
        mode: kModeMapped,
        mappedFrom: kTitleFieldId,
        valueMap: {'A': 'Type A'},
      );
      final tpl = MetadataTemplate(fields: [mapped]);
      expect(tpl.mappedValueFor(mapped, 'A'), 'Type A');
      expect(tpl.mappedValueFor(mapped, 'B (no mapping entry)'), isNull);
      expect(tpl.mappedValueFor(mapped, null), isNull);
    });

    test('effectiveValueOf(mapped) requires the main field to be enabled AND editable', () {
      // Main field disabled → null.
      final disabledMain = MetadataTemplate(fields: [
        const TemplateField(
            id: kTitleFieldId, label: 'Title', enabled: false, inputType: 'dropdown'),
        const TemplateField(
          id: kRecordTypeFieldId,
          label: 'Record Type',
          mode: kModeMapped,
          mappedFrom: kTitleFieldId,
          valueMap: {'A': 'Type A'},
        ),
      ]);
      final f = CaptureFolder(boxId: 1, title: 'A');
      expect(disabledMain.effectiveValueOf(kRecordTypeFieldId, f), isNull);

      // Main field itself fixed (not editable) → null (a fixed field has no
      // per-folder keyed value to look up by).
      final fixedMain = MetadataTemplate(fields: [
        const TemplateField(
            id: kTitleFieldId, label: 'Title', mode: kModeFixed, fixedValue: 'A'),
        const TemplateField(
          id: kRecordTypeFieldId,
          label: 'Record Type',
          mode: kModeMapped,
          mappedFrom: kTitleFieldId,
          valueMap: {'A': 'Type A'},
        ),
      ]);
      expect(fixedMain.effectiveValueOf(kRecordTypeFieldId, f), isNull);
    });

    test('mapped-from-mapped chains degrade to null instead of recursing', () {
      final tpl = MetadataTemplate(fields: [
        const TemplateField(
          id: kRecordTypeFieldId,
          label: 'Record Type',
          mode: kModeMapped,
          mappedFrom: kLanguageFieldId,
          valueMap: {'English': 'X'},
        ),
        const TemplateField(
          id: kLanguageFieldId,
          label: 'Language',
          mode: kModeMapped,
          mappedFrom: kTitleFieldId,
          valueMap: {'A': 'English'},
        ),
      ]);
      final f = CaptureFolder(boxId: 1, title: 'A');
      // Language's main (kLanguageFieldId's mappedFrom -> title) isn't even
      // consulted: recordType's main (language) is itself mapped, not
      // editable, so resolution stops there.
      expect(tpl.effectiveValueOf(kRecordTypeFieldId, f), isNull);
    });

    test('a §8.3 fixed-only field can be MAPPED, resolved per-folder via fixedCsvValueOf', () {
      final tpl = MetadataTemplate(fields: [
        const TemplateField(
            id: kTitleFieldId, label: 'Title', inputType: 'dropdown', options: [
          TemplateOption(value: 'WWI Medical Files'),
          TemplateOption(value: 'WWII Medical Files'),
        ]),
        const TemplateField(
          id: kLanguageFieldId,
          label: 'Language',
          mode: kModeMapped,
          mappedFrom: kTitleFieldId,
          valueMap: {'WWI Medical Files': 'English', 'WWII Medical Files': 'Afrikaans'},
        ),
      ]);
      final f1 = CaptureFolder(boxId: 1, title: 'WWI Medical Files');
      final f2 = CaptureFolder(boxId: 1, title: 'WWII Medical Files');
      expect(tpl.fixedCsvValueOf('language', f1), 'English');
      expect(tpl.fixedCsvValueOf('language', f2), 'Afrikaans');
    });
  });

  group('effectiveValueOf / fixedCsvValueOf', () {
    test('effectiveValueOf returns null for a disabled field', () {
      final tpl = MetadataTemplate(fields: [
        const TemplateField(id: kCoverTagFieldId, label: 'Cover Tag', enabled: false),
      ]);
      final f = CaptureFolder(boxId: 1, coverTag: 'Something');
      expect(tpl.effectiveValueOf(kCoverTagFieldId, f), isNull);
    });

    test('effectiveValueOf returns fixedValue for a fixed field regardless of folder data', () {
      final tpl = MetadataTemplate(fields: [
        const TemplateField(
            id: kCoverTagFieldId, label: 'Cover Tag', mode: kModeFixed, fixedValue: 'Constant'),
      ]);
      final f = CaptureFolder(boxId: 1, coverTag: 'Ignored');
      expect(tpl.effectiveValueOf(kCoverTagFieldId, f), 'Constant');
    });

    test('effectiveValueOf returns the keyed value for an editable field', () {
      final tpl = MetadataTemplate.standard();
      final f = CaptureFolder(boxId: 1, coverTag: 'Cover Will Be Captured');
      expect(tpl.effectiveValueOf(kCoverTagFieldId, f), 'Cover Will Be Captured');
    });

    test('fixedCsvValueOf resolves each of the 6 columns from the standard template', () {
      final tpl = MetadataTemplate.standard();
      final f = const CaptureFolder(boxId: 1);
      expect(tpl.fixedCsvValueOf('place', f), 'South Africa');
      expect(tpl.fixedCsvValueOf('language', f), 'English');
      expect(tpl.fixedCsvValueOf('record_custodian', f), 'South Africa Department of Defense');
      expect(tpl.fixedCsvValueOf('digitizing_entity', f), 'Lifewood');
      expect(tpl.fixedCsvValueOf('capture_operator_id', f), 'cis.user.MM38-RXW3');
      expect(tpl.fixedCsvValueOf('capture_operator_name', f), 'lifewoodza01');
      expect(tpl.fixedCsvValueOf('not_a_real_column', f), isNull);
    });

    test('fixedCsvValueOf returns null when the field is disabled', () {
      final tpl = MetadataTemplate(fields: [
        const TemplateField(
            id: kPlaceFieldId, label: 'Place', enabled: false, mode: kModeFixed, fixedValue: 'X'),
      ]);
      expect(tpl.fixedCsvValueOf('place', const CaptureFolder(boxId: 1)), isNull);
    });
  });

  group('applyValues', () {
    test('applies only the fields present in the values map; others pass through', () {
      final tpl = MetadataTemplate.standard();
      final base = CaptureFolder(
        id: 5,
        boxId: 1,
        folderSeq: 2,
        coverTag: 'Old Cover',
        title: 'Old Title',
        volume: 'Old Volume',
      );
      final updated = tpl.applyValues(base, {
        kCoverTagFieldId: 'New Cover',
        kTitleFieldId: null, // explicit clear
      });
      expect(updated.id, 5);
      expect(updated.boxId, 1);
      expect(updated.folderSeq, 2);
      expect(updated.coverTag, 'New Cover');
      expect(updated.title, isNull);
      expect(updated.volume, 'Old Volume'); // untouched, passes through
    });

    test('applies an editable Record Type like any other keyed field', () {
      final tpl = MetadataTemplate(fields: const [
        TemplateField(id: kRecordTypeFieldId, label: 'Record Type'),
      ]);
      final base = CaptureFolder(boxId: 1, recordType: 'Old');
      final updated = tpl.applyValues(base, {kRecordTypeFieldId: 'New'});
      expect(updated.recordType, 'New');
    });
  });
}
