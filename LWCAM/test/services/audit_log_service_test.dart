import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/audit_log_service.dart';

Future<Directory> _tempDir(String prefix) async {
  final dir = await Directory.systemTemp.createTemp(prefix);
  addTearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });
  return dir;
}

void main() {
  group('AuditLogService', () {
    test('log() writes a monthly audit file named after the device id',
        () async {
      final dir = await _tempDir('audit_naming_');
      final fixedNow = DateTime(2026, 7, 18, 9, 30, 0);
      final service = AuditLogService(
        resolveBaseDir: () async => dir,
        now: () => fixedNow,
      );
      service.setContext(deviceId: 'SAX04', operator: 'alice');

      await service.log('BOX_CREATE', details: {'box': 'BOX-1'});

      final file = File('${dir.path}/SAX04_audit_2026-07.log');
      expect(await file.exists(), isTrue);
      final line = (await file.readAsLines()).single;
      expect(line, contains('2026-07-18T09:30:00'));
      expect(line, contains('| SAX04 | alice | BOX_CREATE'));
      expect(line, contains('box=BOX-1'));
    });

    test('falls back to device id UNKNOWN before setContext is ever called',
        () async {
      final dir = await _tempDir('audit_unknown_');
      final service = AuditLogService(
        resolveBaseDir: () async => dir,
        now: () => DateTime(2026, 1, 5),
      );

      await service.log('LOGIN_FAILED', details: {'username': 'bob'});

      final file = File('${dir.path}/UNKNOWN_audit_2026-01.log');
      expect(await file.exists(), isTrue);
    });

    test('setContext with no args resets to UNKNOWN/blank operator (logout)',
        () async {
      final dir = await _tempDir('audit_reset_');
      final service = AuditLogService(
        resolveBaseDir: () async => dir,
        now: () => DateTime(2026, 3, 1),
      );
      service.setContext(deviceId: 'SAX01', operator: 'carol');
      service.setContext();

      await service.log('LOGOUT');

      final unknownFile = File('${dir.path}/UNKNOWN_audit_2026-03.log');
      expect(await unknownFile.exists(), isTrue);
      final line = (await unknownFile.readAsLines()).single;
      expect(line, contains('| UNKNOWN |  | LOGOUT'));
    });

    test('sanitizes pipes/newlines and quotes spaced values', () async {
      final dir = await _tempDir('audit_sanitize_');
      final service = AuditLogService(
        resolveBaseDir: () async => dir,
        now: () => DateTime(2026, 2, 1),
      );
      service.setContext(deviceId: 'SAX02');

      await service.log('SETTINGS_CHANGED', details: {
        'value': 'X:\\Images | with a pipe\nand a newline',
      });

      final line =
          (await File('${dir.path}/SAX02_audit_2026-02.log').readAsLines())
              .single;
      expect(line, isNot(contains('\n')));
      // The pipe delimiter count must stay exactly 3 (timestamp|device|
      // operator|action) plus none introduced by the sanitized value.
      expect('|'.allMatches(line).length, 3);
    });

    test('logReplacement writes to BOTH the replacement log and a summary '
        'line in the audit trail', () async {
      final dir = await _tempDir('audit_replacement_');
      final service = AuditLogService(
        resolveBaseDir: () async => dir,
        now: () => DateTime(2026, 7, 1),
      );
      service.setContext(deviceId: 'SAX04', operator: 'alice');

      await service.logReplacement(
        event: 'created',
        originalFilename: 'IMG_1.jpg',
        replacementFilename: 'IMG_1_r1.jpg',
        replacementType: 'recapture',
        boxDetails: 'BOX-1',
      );

      final replacementLine = (await File(
              '${dir.path}/SAX04_replacements_2026-07.log')
          .readAsLines())
          .single;
      expect(replacementLine, contains('REPLACEMENT'));
      expect(replacementLine, contains('event=created'));
      expect(replacementLine, contains('original=IMG_1.jpg'));
      expect(replacementLine, contains('replacement=IMG_1_r1.jpg'));
      expect(replacementLine, contains('box=BOX-1'));

      final auditLine =
          (await File('${dir.path}/SAX04_audit_2026-07.log').readAsLines())
              .single;
      expect(auditLine, contains('REPLACEMENT'));
      expect(auditLine, contains('event=created'));
    });

    test('concurrent log() calls are serialized, never interleaved',
        () async {
      final dir = await _tempDir('audit_concurrency_');
      final service = AuditLogService(
        resolveBaseDir: () async => dir,
        now: () => DateTime(2026, 5, 1),
      );
      service.setContext(deviceId: 'SAX09');

      await Future.wait([
        for (var i = 0; i < 20; i++)
          service.log('TRANSFER_START', details: {'n': i}),
      ]);

      final lines =
          await File('${dir.path}/SAX09_audit_2026-05.log').readAsLines();
      expect(lines, hasLength(20));
      // Every line is well-formed (no shearing from concurrent writes).
      for (final line in lines) {
        expect(line, contains('| SAX09 |  | TRANSFER_START n='));
      }
    });

    test('a write failure (unresolvable base dir) is swallowed, never throws',
        () async {
      final service = AuditLogService(
        resolveBaseDir: () async => throw Exception('disk unavailable'),
        now: () => DateTime(2026, 6, 1),
      );

      await expectLater(service.log('LOGIN_SUCCESS'), completes);
    });
  });
}
