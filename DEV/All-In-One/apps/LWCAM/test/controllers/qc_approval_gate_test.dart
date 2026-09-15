import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/controllers/qc_review_controller.dart';
import 'package:lwcam/models/qc_task.dart';

/// Approve is the only action in the review screen that writes to
/// `capture_folders`, and the engine refuses it outright if the metadata is not
/// complete. These check that the reviewer is told BEFORE committing rather than
/// bounced afterwards - and, more importantly, that a folder which should be
/// blocked never gets an enabled button.
Map<String, Object?> taskJson({
  bool claimed = true,
  bool withImages = true,
}) {
  final envelope = jsonDecode(
    File('test/fixtures/qc_task_page.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final data = envelope['data'] as Map<String, Object?>;
  final record = Map<String, Object?>.from(
    (data['records'] as List).cast<Map<String, Object?>>().first,
  );
  record['assignedTo'] = claimed ? 3 : null;
  if (!withImages) record['images'] = <Object?>[];
  return record;
}

/// The fixture's own mandatory set: coverTag, title, volume, startDate, endDate.
QcReviewController controllerWith(
  Map<String, Object?> json, {
  Map<String, String?> form = const {},
}) {
  final controller = QcReviewController(18);
  controller.task.value = QcTask.fromJson(json);
  controller.form.value = Map<String, String?>.from(form);
  return controller;
}

const complete = <String, String?>{
  'coverTag': 'Cover Unavailable or Missing',
  'title': 'WWII Medical Files',
  'volume': '256 2146-2599',
  'startDate': '1939',
  'endDate': '1945',
};

void main() {
  test('a complete, claimed folder can be approved', () {
    final controller = controllerWith(taskJson(), form: complete);
    expect(controller.blocksApproval, isNull);
  });

  test('an unclaimed folder cannot be approved', () {
    final controller =
        controllerWith(taskJson(claimed: false), form: complete);
    expect(controller.blocksApproval, contains('Claim'));
  });

  test('a missing mandatory field is named, not just refused', () {
    // The engine answers "Required metadata is missing: <labels>"; saying which
    // field beforehand is the whole point of checking here.
    final form = Map<String, String?>.from(complete)..remove('volume');
    final controller = controllerWith(taskJson(), form: form);
    expect(controller.blocksApproval, contains('Volume'));
  });

  test('an empty string counts as missing, not as filled', () {
    final form = Map<String, String?>.from(complete)..['title'] = '';
    final controller = controllerWith(taskJson(), form: form);
    expect(controller.blocksApproval, isNotNull);
  });

  test('archive dates are free text - never ordered or parsed here', () {
    // Owner decision: start/end date are stored verbatim ("1877-Mar-05"), so
    // the client cannot compare them and must not refuse on shape.
    final form = Map<String, String?>.from(complete)
      ..['startDate'] = '1945'
      ..['endDate'] = '1877-Mar-05';
    final controller = controllerWith(taskJson(), form: form);
    expect(controller.blocksApproval, isNull);
  });

  test('a folder with no pages cannot be approved', () {
    final controller =
        controllerWith(taskJson(withImages: false), form: complete);
    expect(controller.blocksApproval, contains('no pages'));
  });

  test('fixed fields are never treated as missing', () {
    // The project pins them and the engine overwrites whatever is sent, so the
    // reviewer has no way to fill them in - blocking on one would be a dead end.
    final controller = controllerWith(taskJson(), form: complete);
    expect(controller.form['place'], isNull);
    expect(controller.blocksApproval, isNull);
  });

  group('pages offered for rework', () {
    test('only pages the database knows about are offered', () {
      // A page inserted during review is numbered downward from -1 and has no
      // row to attach a rework log to; naming one makes the engine refuse the
      // whole request.
      final json = taskJson();
      final images = List<Map<String, Object?>>.from(
        (json['images'] as List).cast<Map<String, Object?>>(),
      );
      final inserted = Map<String, Object?>.from(images.first)
        ..['id'] = -1
        ..['filename'] = 'inserted.png'
        ..['draftState'] = 'inserted';
      json['images'] = [inserted, ...images];

      final controller = controllerWith(json, form: complete);
      expect(controller.task.value!.images, hasLength(2));
      expect(controller.officialImages, hasLength(1));
      expect(controller.officialImages.every((i) => i.id > 0), isTrue);
    });
  });
}
