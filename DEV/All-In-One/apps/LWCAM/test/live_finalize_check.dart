// Throwaway check against a RUNNING engine. Not named *_test.dart so the suite
// never picks it up - it CHANGES capture_folders, and the caller is expected to
// have snapshotted the row first (scratchpad/folder_state.py).
//
// Set FINALIZE_MODE=reject or FINALIZE_MODE=approve.
//
// What it proves that unit tests cannot: the terminal calls really move the
// folder out of the queue, and the guards the buttons rely on are the engine's
// guards too.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/qc_api_client.dart';

void main() {
  test('approve / reject against the live engine', () async {
    final mode = Platform.environment['FINALIZE_MODE'];
    if (mode != 'approve' && mode != 'reject') {
      fail('Set FINALIZE_MODE to approve or reject.');
    }

    final api = QcApiClient.instance;
    await api.signIn('Albert', 'Albert');

    final page = await api.tasks(scope: 'pending');
    final rows = (page['records'] as List).cast<Map<String, Object?>>();
    expect(rows, isNotEmpty, reason: 'nothing pending to finalize');
    final folderId = (rows.first['folderId'] ?? rows.first['id']) as int;

    await api.claim(folderId);
    final task = await api.task(folderId);
    final sourceHash = task['sourceHash'] as String;
    final images = (task['images'] as List).cast<Map<String, Object?>>();
    print('folder $folderId, ${images.length} page(s), status ${task['status']}');

    if (mode == 'reject') {
      // A page that is not in the folder must be refused, or a stale UI could
      // attach rework to someone else's document.
      await expectLater(
        api.reject(folderId, sourceHash, {999999: 'not our page'}),
        throwsA(isA<QcApiException>()),
      );
      print('foreign-page guard: refused');

      // The engine also insists on at least one page with a reason.
      await expectLater(
        api.reject(folderId, sourceHash, const {}),
        throwsA(isA<QcApiException>()),
      );
      print('empty-selection guard: refused');

      await api.reject(
        folderId,
        sourceHash,
        {images.first['id'] as int: 'Page is out of focus along the top edge.'},
      );
      print('rejected');
    } else {
      await api.approve(folderId, sourceHash, comment: 'verified end to end');
      print('approved');
    }

    // Either way the folder leaves the pending queue and the claim is gone.
    final after = await api.tasks(scope: 'pending');
    final stillPending = (after['records'] as List)
        .cast<Map<String, Object?>>()
        .any((r) => (r['folderId'] ?? r['id']) == folderId);
    expect(stillPending, isFalse, reason: 'folder is still pending');
    print('left the pending queue');

    // And a second terminal call on it must fail rather than double-commit.
    await expectLater(
      api.approve(folderId, sourceHash),
      throwsA(isA<QcApiException>()),
    );
    print('second finalize: refused');
    print('PASS ($mode)');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
