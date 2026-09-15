// Throwaway check against a RUNNING engine. Deliberately not named *_test.dart
// so `flutter test` never picks it up: it needs the engine and the database.
//
// What it proves that a unit test cannot: the hand-built multipart body in
// QcApiClient.insertBefore is one the engine actually parses. Every other
// endpoint is JSON, so this encoder has no second user to shake out its bugs.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/qc_api_client.dart';

void main() {
  test('insert, reorder and delete round-trip against the live engine',
      () async {
    final api = QcApiClient.instance;
    await api.signIn('Albert', 'Albert');

    final page = await api.tasks(scope: 'pending');
    final rows = (page['records'] as List).cast<Map<String, Object?>>();
    final folderId = (rows.first['folderId'] ?? rows.first['id']) as int;
    print('folder $folderId');

    try {
      await api.claim(folderId);
    } catch (e) {
      print('claim: $e');
    }

    Map<String, Object?> task = await api.task(folderId);
    List<Map<String, Object?>> imagesOf(Map<String, Object?> t) =>
        (t['images'] as List).cast<Map<String, Object?>>();

    final before = imagesOf(task);
    final anchorId = before.first['id'] as int;
    print('before: ${before.length} pages, ids '
        '${before.map((i) => i['id']).toList()}');

    final fixture = Platform.environment['INSERT_FIXTURE'];
    if (fixture == null) {
      fail('Set INSERT_FIXTURE to a .png/.jpg to upload, and start the engine '
          'on 127.0.0.1:8080, before running this check.');
    }
    final bytes = await File(fixture).readAsBytes();

    // --- insert -----------------------------------------------------------
    task = await api.insertBefore(
      folderId,
      anchorId,
      task['sourceHash'] as String,
      filename: 'inserted-page.png',
      bytes: bytes,
    );
    var images = imagesOf(task);
    expect(images.length, before.length + 1,
        reason: 'the multipart body did not reach the engine as a file');
    final inserted = images.first;
    final insertedId = inserted['id'] as int;
    print('after insert: ${images.length} pages, first id $insertedId '
        'state ${inserted['draftState']}');
    expect(insertedId, lessThan(0), reason: 'draft additions number downward');
    expect(inserted['draftState'], 'inserted');

    // --- reorder ----------------------------------------------------------
    final ids = images.map((i) => i['id'] as int).toList();
    final moved = List<int>.from(ids)..removeAt(0);
    moved.add(insertedId); // send the inserted page to the back
    task = await api.reorder(folderId, task['sourceHash'] as String, moved);
    images = imagesOf(task);
    expect(images.map((i) => i['id']).toList(), moved);
    print('after reorder: ${images.map((i) => i['id']).toList()}');

    // A list that is not an exact permutation must be refused, not guessed at.
    await expectLater(
      api.reorder(folderId, task['sourceHash'] as String, [insertedId]),
      throwsA(isA<QcApiException>()),
    );

    // --- delete -----------------------------------------------------------
    task = await api.deleteImage(
        folderId, insertedId, task['sourceHash'] as String);
    images = imagesOf(task);
    expect(images.length, before.length);
    expect(images.any((i) => i['id'] == insertedId), isFalse);
    print('after delete: ${images.length} pages, ids '
        '${images.map((i) => i['id']).toList()}');

    // The captured pages must come back in their original order.
    expect(images.map((i) => i['id']).toList(),
        before.map((i) => i['id']).toList());

    // The toolbar offers Delete on any page, so the one-page folder case is a
    // real click. The engine must refuse it with a message, not a 500.
    if (images.length == 1) {
      try {
        await api.deleteImage(
            folderId, images.first['id'] as int, task['sourceHash'] as String);
        fail('the engine deleted the last remaining page');
      } on QcApiException catch (e) {
        print('last-page guard: ${e.message}');
        expect(e.message, contains('last image'));
      }
    }

    await api.release(folderId);
    print('PASS');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
