import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/controllers/box_session_controller.dart';
import 'package:lwcam/models/capture_box_models.dart';

CaptureBoxEntry _entry(
  String name, {
  required String status,
  int reworkCount = 0,
  DateTime? createdAt,
}) =>
    CaptureBoxEntry(
      box: CaptureBox(
        id: name.hashCode & 0xffff,
        deviceId: 'SAX01',
        boxDetails: name,
        status: status,
        createdAt: createdAt,
      ),
      folderCount: 1,
      imageCount: 1,
      allFoldersComplete: true,
      reworkCount: reworkCount,
    );

void main() {
  // Requested order: boxes QC sent back, then boxes still being captured, then
  // completed ones. A rework box IS transferred, so this cannot be done in
  // getCaptureBoxes' SQL ORDER BY — the counts come from PostgreSQL.
  group('sortBoxEntries', () {
    test('orders rework, then in-progress, then completed', () {
      final entries = [
        _entry('done', status: 'TRANSFERRED'),
        _entry('open', status: 'OPEN'),
        _entry('rework', status: 'TRANSFERRED', reworkCount: 2),
      ];
      sortBoxEntries(entries);
      expect(entries.map((e) => e.box.boxDetails).toList(),
          ['rework', 'open', 'done']);
    });

    test('newest first within a group', () {
      final entries = [
        _entry('older', status: 'OPEN', createdAt: DateTime(2026, 7, 1)),
        _entry('newer', status: 'OPEN', createdAt: DateTime(2026, 7, 20)),
      ];
      sortBoxEntries(entries);
      expect(entries.first.box.boxDetails, 'newer');
    });

    test('a rework box outranks an in-progress box', () {
      final entries = [
        _entry('open', status: 'OPEN', createdAt: DateTime(2026, 7, 28)),
        _entry('rework',
            status: 'TRANSFERRED',
            reworkCount: 1,
            createdAt: DateTime(2026, 7, 1)),
      ];
      sortBoxEntries(entries);
      // Even though the open box is much newer.
      expect(entries.first.box.boxDetails, 'rework');
    });

    test('keeps the query order when created_at is missing', () {
      final entries = [
        _entry('first', status: 'OPEN'),
        _entry('second', status: 'OPEN'),
      ];
      sortBoxEntries(entries);
      expect(entries.map((e) => e.box.boxDetails).toList(), ['first', 'second']);
    });

    test('needsRework is driven by the count', () {
      expect(_entry('a', status: 'TRANSFERRED').needsRework, isFalse);
      expect(
          _entry('b', status: 'TRANSFERRED', reworkCount: 1).needsRework, isTrue);
    });
  });
}
