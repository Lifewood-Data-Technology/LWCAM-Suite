import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/qc_task.dart';

/// A mapped field is derived from the field the PROJECT says it comes from.
///
/// The engine rewrites every mapped field on save, so the form has to mirror the
/// same rule or it shows a value the next save replaces. Which fields are mapped
/// is the template's decision: one live project maps Record Type from Title,
/// another maps Start Date from Title, and the field ids differ per project.
QcMetadataField field(
  String key, {
  String input = 'text',
  String? mappedFrom,
  Map<String, String> valueMap = const {},
  String? value,
}) =>
    QcMetadataField(
      key: key,
      label: key,
      input: input,
      mandatory: false,
      options: const [],
      value: value,
      mappedFrom: mappedFrom,
      valueMap: valueMap,
    );

QcMetadataTemplate templateOf(List<QcMetadataField> fields) =>
    QcMetadataTemplate(fields: fields, titleRecordTypeMap: const {});

void main() {
  group('applyMappings', () {
    test('derives a mapped field from its source', () {
      final template = templateOf([
        field('title', input: 'select'),
        field('recordType',
            input: 'mapped',
            mappedFrom: 'title',
            valueMap: {'WWI Medical Files': 'Military Medical Records'}),
      ]);
      final values = <String, String?>{'title': 'WWI Medical Files'};
      template.applyMappings(values);
      expect(values['recordType'], 'Military Medical Records');
    });

    test('maps a field other than recordType', () {
      // The real DEMO01 project maps Start Date from Title.
      final template = templateOf([
        field('title', input: 'select'),
        field('startDate',
            input: 'mapped',
            mappedFrom: 'title',
            valueMap: {'WWI Medical Files': '1914', 'WWII Medical Files': '1939'}),
      ]);
      final values = <String, String?>{'title': 'WWII Medical Files'};
      template.applyMappings(values);
      expect(values['startDate'], '1939');
    });

    test('overwrites a stale stored value rather than keeping it', () {
      // The folder row was keyed under an older template; the template wins.
      final template = templateOf([
        field('title', input: 'select'),
        field('recordType',
            input: 'mapped', mappedFrom: 'title', valueMap: {'A': 'B'}),
      ]);
      final values = <String, String?>{
        'title': 'A',
        'recordType': 'Something else entirely',
      };
      template.applyMappings(values);
      expect(values['recordType'], 'B');
    });

    test('a source value outside the map derives nothing', () {
      final template = templateOf([
        field('title', input: 'select'),
        field('recordType',
            input: 'mapped', mappedFrom: 'title', valueMap: {'A': 'B'}),
      ]);
      final values = <String, String?>{'title': 'Not in the map'};
      template.applyMappings(values);
      expect(values['recordType'], isNull);
    });

    test('surrounding whitespace on the source still matches', () {
      final template = templateOf([
        field('title', input: 'select'),
        field('recordType',
            input: 'mapped', mappedFrom: 'title', valueMap: {'A': 'B'}),
      ]);
      final values = <String, String?>{'title': '  A  '};
      template.applyMappings(values);
      expect(values['recordType'], 'B');
    });

    test('mapping from a mapped field resolves to nothing', () {
      // One level deep, matching the capture form and the engine: otherwise the
      // result would depend on the order the fields happen to be listed in.
      final template = templateOf([
        field('title', input: 'select'),
        field('recordType',
            input: 'mapped', mappedFrom: 'title', valueMap: {'A': 'B'}),
        field('place',
            input: 'mapped', mappedFrom: 'recordType', valueMap: {'B': 'C'}),
      ]);
      final values = <String, String?>{'title': 'A'};
      template.applyMappings(values);
      expect(values['recordType'], 'B');
      expect(values['place'], isNull);
    });

    test('mapping from a fixed field resolves to nothing', () {
      final template = templateOf([
        field('language', input: 'fixed', value: 'English'),
        field('place',
            input: 'mapped',
            mappedFrom: 'language',
            valueMap: {'English': 'UK'}),
      ]);
      final values = <String, String?>{'language': 'English'};
      template.applyMappings(values);
      expect(values['place'], isNull);
    });

    test('a field mapped from itself resolves to nothing', () {
      final template = templateOf([
        field('title', input: 'mapped', mappedFrom: 'title', valueMap: {'A': 'B'}),
      ]);
      final values = <String, String?>{'title': 'A'};
      template.applyMappings(values);
      expect(values['title'], isNull);
    });
  });

  group('template shape', () {
    test('parses mappedFrom and valueMap off the wire', () {
      final parsed = QcMetadataField.fromJson({
        'key': 'recordType',
        'label': 'Record Type',
        'input': 'mapped',
        'mappedFrom': 'title',
        'valueMap': {'A': 'B'},
      });
      expect(parsed.isMapped, isTrue);
      expect(parsed.isEditable, isFalse);
      expect(parsed.mappedFrom, 'title');
      expect(parsed.valueMap, {'A': 'B'});
    });

    test('mappedFieldsFrom finds every field deriving from one source', () {
      final template = templateOf([
        field('title', input: 'select'),
        field('recordType', input: 'mapped', mappedFrom: 'title'),
        field('startDate', input: 'mapped', mappedFrom: 'title'),
        field('volume'),
      ]);
      expect(
        template.mappedFieldsFrom('title').map((f) => f.key),
        ['recordType', 'startDate'],
      );
      expect(template.mappedFieldsFrom('volume'), isEmpty);
    });

    test('a plain text field is editable, a fixed one is not', () {
      expect(field('volume').isEditable, isTrue);
      expect(field('place', input: 'fixed', value: 'X').isEditable, isFalse);
    });
  });
}
