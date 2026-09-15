import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/qc_task.dart';

/// A real page captured from the running QC engine (2026-08-19), not a
/// hand-written guess at the shape. The parser has to survive what the engine
/// actually sends, including the fields it sends as null.
Map<String, Object?> loadFixture() {
  final text = File('test/fixtures/qc_task_page.json').readAsStringSync();
  return jsonDecode(text) as Map<String, Object?>;
}

void main() {
  _completedIdentityTests();
  test('parses a real page from the engine', () {
    final envelope = loadFixture();
    expect(envelope['code'], 0);

    final data = envelope['data'] as Map<String, Object?>;
    final records = (data['records'] as List).cast<Map<String, Object?>>();
    expect(records, isNotEmpty);

    final task = QcTask.fromJson(records.first);
    expect(task.folderId, 18);
    expect(task.boxName, '256 2146-2599');
    expect(task.folderName, '256 2146-2599 - 2199 - 0001');
    expect(task.folderSeq, 1);
    expect(task.title, 'WWII Medical Files');
    expect(task.imageCount, 1);
    expect(task.imageAvailable, isTrue);
    expect(task.hasDraft, isFalse);
    // 64 hex chars: every mutating call sends it back so the engine can refuse
    // an edit written against images that changed underneath the reviewer.
    expect(task.sourceHash.length, 64);
    // Unclaimed, so no owner and no claim time - both arrive as JSON null.
    expect(task.assignedTo, isNull);
    expect(task.claimedAt, isNull);
    expect(task.submittedAt.year, 2026);
  });

  test('falls back to the folder name when no title is keyed yet', () {
    // Early in a box the operator has not typed a title, and the engine sends
    // null. A blank row would leave nothing to identify the task by.
    final task = QcTask.fromJson(const {
      'id': 7,
      'sourceHash': '',
      'imageCount': 3,
      'metadata': {'folderName': 'BOX-1 - 0002', 'boxName': 'BOX-1'},
    });
    expect(task.displayName, 'BOX-1 - 0002');

    final titled = QcTask.fromJson(const {
      'id': 7,
      'metadata': {'folderName': 'BOX-1 - 0002', 'title': '  Ledger  '},
    });
    expect(titled.displayName, 'Ledger');
  });

  test('even the list response carries its pages', () {
    // Both endpoints build the same VO, so the queue already knows every page
    // and its preview URL - no detail round-trip is needed just to show one.
    final envelope = loadFixture();
    final records = ((envelope['data'] as Map<String, Object?>)['records']
            as List)
        .cast<Map<String, Object?>>();
    final fromList = QcTask.fromJson(records.first);
    expect(fromList.images, hasLength(1));
    expect(fromList.images.first.id, 17);
    expect(fromList.images.first.available, isTrue);

    final detail = QcTask.fromJson(const {
      'id': 18,
      'images': [
        {
          'id': 17,
          'filename': 'SAX01_IMG_20260817_111008_001.jpg',
          'available': true,
          'previewUrl': '/api/qc/metadata-tasks/18/images/17/preview?v=1786936260404',
          'separationStart': false,
        },
      ],
      'metadata': {'folderName': 'f'},
    });
    expect(detail.images, hasLength(1));
    expect(detail.images.first.filename, 'SAX01_IMG_20260817_111008_001.jpg');
    // The v= stamp must survive verbatim: it is the cache key, and it is what
    // makes an edited page stop serving its stale preview.
    expect(detail.images.first.previewUrl, contains('v=1786936260404'));
  });

  test('a malformed timestamp degrades instead of killing the list', () {
    final task = QcTask.fromJson(const {
      'id': 1,
      'claimedAt': 'not-a-date',
      'metadata': {'folderName': 'f'},
    });
    expect(task.claimedAt, isNull);
  });
}

void _completedIdentityTests() {
  Map<String, Object?> task({
    String? groupId,
    String status = 'passed',
    String folderName = 'Register 12',
    String? title,
  }) => {
        'id': 1,
        'status': status,
        'sourceHash': 'h' * 64,
        'submittedAt': '2026-09-07T00:00:00Z',
        'metadata': {
          'boxName': 'All Saints Church',
          'folderName': folderName,
          if (title != null) 'title': title,
        },
        if (groupId != null) 'groupId': groupId,
        'isExported': groupId != null,
      };

  group('completed identity', () {
    // The Group ID is assigned at EXPORT, not approval, so the list has to cope
    // with rows that legitimately have none yet - and with rework rows, which
    // never get one at all.
    test('an exported folder leads with its Group ID', () {
      final t = QcTask.fromJson(task(groupId: 'MY01ASC260907000001'));
      expect(t.completedIdentifier, 'MY01ASC260907000001');
      expect(t.completedState, QcCompletedState.exported);
    });

    test('an approved folder not yet exported falls back to the name', () {
      final t = QcTask.fromJson(task(title: 'Baptisms 1899'));
      expect(t.completedIdentifier, 'Baptisms 1899');
      expect(t.completedState, QcCompletedState.awaitingExport);
    });

    test('a folder sent back for rework is labelled as such', () {
      final t = QcTask.fromJson(task(status: 'rework'));
      expect(t.completedState, QcCompletedState.sentBack);
      expect(t.completedIdentifier, 'Register 12');
    });

    test('a blank groupId from the engine counts as absent', () {
      final t = QcTask.fromJson({...task(), 'groupId': '   '});
      expect(t.groupId, isNull);
      expect(t.completedState, QcCompletedState.awaitingExport);
    });

    // A client-rework revert clears is_exported but KEEPS group_id, so the
    // corrected package can republish under the SAME Group ID. Before it
    // ships, the row must not read as Exported - but the Group ID must stay
    // visible so the reviewer can see what it will replace.
    test('a client-rework revert keeps its Group ID but is not Exported', () {
      final t = QcTask.fromJson({
        ...task(groupId: 'MY01ASC260907000001'),
        'isExported': false,
      });
      expect(t.completedIdentifier, 'MY01ASC260907000001');
      expect(t.completedState, QcCompletedState.reworkPendingExport);
    });

    test('clientRework round-trips', () {
      expect(QcTask.fromJson({...task(), 'clientRework': true}).clientRework, isTrue);
      expect(QcTask.fromJson(task()).clientRework, isFalse);
    });
  });
}
