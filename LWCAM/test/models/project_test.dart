import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/metadata_template.dart';
import 'package:lwcam/models/project.dart';

void main() {
  group('generateProjectKey', () {
    test('produces unique keys across rapid calls', () {
      final keys = List.generate(50, (_) => generateProjectKey()).toSet();
      expect(keys.length, 50);
    });
  });

  group('Project JSON round-trip', () {
    test('preserves all fields', () {
      final p = Project(
        key: 'p123',
        projectId: 'PRJ-1',
        name: 'Archive Digitization',
        startDate: DateTime(2026, 7, 15),
        hasData: true,
        createdAt: DateTime(2026, 7, 1),
        createdBy: 'SuperAdmin',
      );
      final back = Project.fromJson(p.toJson());
      expect(back.key, 'p123');
      expect(back.projectId, 'PRJ-1');
      expect(back.name, 'Archive Digitization');
      expect(back.startDate, DateTime(2026, 7, 15));
      expect(back.hasData, isTrue);
      expect(back.createdBy, 'SuperAdmin');
    });

    test('defaults missing/malformed fields instead of throwing', () {
      final back = Project.fromJson(<String, Object?>{'key': 'p1'});
      expect(back.key, 'p1');
      expect(back.projectId, '');
      expect(back.name, '');
      expect(back.hasData, isFalse);
      expect(back.createdAt, isNull);
      // Unparsable start date falls back rather than throwing.
      expect(back.startDate, DateTime.fromMillisecondsSinceEpoch(0));
    });
  });

  group('Project copyWith', () {
    test('key is immutable across copyWith', () {
      final p = Project(key: 'p1', projectId: 'A', name: 'X', startDate: DateTime(2026, 1, 1));
      final renamed = p.copyWith(projectId: 'B', name: 'Y');
      expect(renamed.key, 'p1');
      expect(renamed.projectId, 'B');
      expect(renamed.name, 'Y');
    });

    test('hasData can be flipped without touching other fields', () {
      final p = Project(key: 'p1', projectId: 'A', name: 'X', startDate: DateTime(2026, 1, 1));
      final stamped = p.copyWith(hasData: true);
      expect(stamped.hasData, isTrue);
      expect(stamped.projectId, 'A');
      expect(stamped.name, 'X');
    });
  });

  group('Project.template', () {
    test('absent template defaults to null (built-in standard applies)', () {
      final p = Project(key: 'p1', projectId: 'A', name: 'X', startDate: DateTime(2026, 1, 1));
      expect(p.template, isNull);
      final back = Project.fromJson(p.toJson());
      expect(back.template, isNull);
    });

    test('round-trips a custom template through JSON', () {
      final tpl = MetadataTemplate.standard();
      final p = Project(
        key: 'p1',
        projectId: 'A',
        name: 'X',
        startDate: DateTime(2026, 1, 1),
        template: tpl,
      );
      final back = Project.fromJson(p.toJson());
      expect(back.template, isNotNull);
      expect(back.template!.fields.length, tpl.fields.length);
    });

    test('copyWith(clearTemplate: true) resets to null', () {
      final p = Project(
        key: 'p1',
        projectId: 'A',
        name: 'X',
        startDate: DateTime(2026, 1, 1),
        template: MetadataTemplate.standard(),
      );
      final cleared = p.copyWith(clearTemplate: true);
      expect(cleared.template, isNull);
    });

    test('copyWith(template: ...) sets a new template without clearTemplate', () {
      final p = Project(key: 'p1', projectId: 'A', name: 'X', startDate: DateTime(2026, 1, 1));
      final tpl = MetadataTemplate.standard();
      final updated = p.copyWith(template: tpl);
      expect(updated.template, isNotNull);
    });
  });
}
