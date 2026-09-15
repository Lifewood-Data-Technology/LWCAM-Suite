import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:lwcam/controllers/qc_review_controller.dart';
import 'package:lwcam/models/qc_task.dart';
import 'package:lwcam/widgets/qc_metadata_form.dart';

/// The metadata panel has to repaint when the form behind it changes.
///
/// `QcMetadataForm.build` wraps its body in an Obx, but that closure only READS
/// `task`. `_Header` and `_Field` are separate widgets, so their own `build`
/// runs outside the closure and the `dirty` / `form[...]` they read get no GetX
/// subscriber. Changing the title then updated the controller and repainted
/// nothing: the derived Record Type kept the previous title's value and Save
/// draft stayed greyed out, while the Title dropdown appeared to change because
/// a DropdownButtonFormField holds its own FormField state.
///
/// Same failure the page strip had (see qc_review_page_test.dart) - a
/// StatelessWidget reading an observable outside any Obx.
Map<String, Object?> demo01Task() => {
      'id': 7,
      'status': 'pending',
      'sourceHash': 'a' * 64,
      'assignedTo': 3,
      'metadata': <String, Object?>{'folderId': 7},
      'metadataTemplate': {
        'fields': [
          {
            'key': 'title',
            'label': 'Title',
            'input': 'select',
            'mandatory': true,
            'options': [
              'WWI Medical Files',
              'WWI South African Mounted Rifles Military Indexes',
            ],
          },
          {
            'key': 'recordType',
            'label': 'Record Type',
            'input': 'mapped',
            'mappedFrom': 'title',
            'valueMap': {
              'WWI Medical Files': 'Military Medical Records',
              'WWI South African Mounted Rifles Military Indexes':
                  'Military Service Record Indexes',
            },
          },
        ],
      },
      'images': <Object?>[],
    };

Future<QcReviewController> pumpForm(WidgetTester tester) async {
  tester.view.physicalSize = const Size(600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final controller = QcReviewController(7);
  controller.task.value = QcTask.fromJson(demo01Task());
  controller.setField('title', 'WWI Medical Files');
  // _adopt leaves a freshly loaded folder clean; seeding through setField does
  // not, so reset it to the state the operator actually starts from.
  controller.dirty.value = false;

  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: QcMetadataForm(controller: controller))),
  );
  return controller;
}


Map<String, Object?> taskWithText({String volume = 'OLD VALUE'}) => {
      'id': 7,
      'status': 'pending',
      'sourceHash': 'a' * 64,
      'assignedTo': 3,
      'metadata': <String, Object?>{'folderId': 7, 'volume': volume},
      'metadataTemplate': {
        'fields': [
          {'key': 'volume', 'label': 'Volume', 'input': 'text'},
        ],
      },
      'images': <Object?>[],
    };

void main() {
  tearDown(Get.reset);

  testWidgets('a derived field repaints when its source changes',
      (tester) async {
    final controller = await pumpForm(tester);
    expect(find.text('Military Medical Records'), findsOneWidget);

    controller.setField(
        'title', 'WWI South African Mounted Rifles Military Indexes');
    await tester.pump();

    expect(find.text('Military Service Record Indexes'), findsOneWidget,
        reason: 'the mapped field must rebuild when the form changes');
    expect(find.text('Military Medical Records'), findsNothing,
        reason: 'the previous title\'s value must not survive on screen');
  });

  testWidgets('Save draft enables once the form is dirty', (tester) async {
    final controller = await pumpForm(tester);
    final save = find.widgetWithText(FilledButton, 'Save draft');
    expect(tester.widget<FilledButton>(save).onPressed, isNull);

    controller.setField(
        'title', 'WWI South African Mounted Rifles Military Indexes');
    await tester.pump();

    expect(controller.dirty.value, isTrue,
        reason: 'the controller itself must register the edit');
    expect(tester.widget<FilledButton>(save).onPressed, isNotNull,
        reason: 'the header must rebuild so the edit can actually be saved');
  });

  testWidgets('a text field shows a value written into the form externally',
      (tester) async {
    // Applying an AI suggestion ends in _adopt, which does exactly two things to
    // the form: replaces every value, then bumps formRevision. TextFormField
    // reads `initialValue` only when its State is created, and the key never
    // varied for a given field on a given folder - so the draft held the new
    // value, the panel said "Already taken from this review", and the box still
    // showed the old text. Precisely what reads as "the apply did nothing".
    //
    // _adopt itself is private and only reachable through the engine, so this
    // performs its two writes directly - the same limitation noted in
    // qc_ai_load_latest_test.dart.
    final controller = QcReviewController(7);
    controller.task.value = QcTask.fromJson(taskWithText());
    controller.setField('volume', 'OLD VALUE');

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: QcMetadataForm(controller: controller))),
    );
    expect(find.text('OLD VALUE'), findsOneWidget);

    controller.form.value = {'volume': 'NEW VALUE'};
    controller.formRevision.value++;
    await tester.pump();

    expect(find.text('NEW VALUE'), findsOneWidget);
    expect(find.text('OLD VALUE'), findsNothing);
  });

  testWidgets('the revision is what rebuilds it, not the value', (tester) async {
    // Keying on the VALUE would rebuild the field on every keystroke and take
    // the cursor with it. Without a revision bump the old State is reused - this
    // asserts the mechanism, so a future change that drops the bump from _adopt
    // shows up as a behaviour change rather than passing quietly.
    final controller = QcReviewController(7);
    controller.task.value = QcTask.fromJson(taskWithText());
    controller.setField('volume', 'OLD VALUE');

    await tester.pumpWidget(
      MaterialApp(home: Scaffold(body: QcMetadataForm(controller: controller))),
    );

    controller.form.value = {'volume': 'NEW VALUE'};
    await tester.pump();

    expect(find.text('OLD VALUE'), findsOneWidget,
        reason: 'no revision bump, so the field keeps its own editing state');
  });
}
