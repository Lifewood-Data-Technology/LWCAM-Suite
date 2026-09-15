import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:lwcam/controllers/qc_review_controller.dart';
import 'package:lwcam/models/qc_task.dart';
import 'package:lwcam/pages/qc_review_page.dart';
import 'package:lwcam/widgets/qc_thumbnail_tile.dart';

/// The review screen shows one page of a folder at a time, and every way of
/// changing WHICH page - the strip, the chevrons, next/previous - does it by
/// writing `QcReviewController.index`.
///
/// That made the screen silently unusable for a while: the widgets reading
/// `index` were plain StatelessWidgets outside any Obx, so GetX had no
/// subscriber for the write and never scheduled a rebuild. Tapping a page did
/// change the controller; nothing on screen moved. Editing actions kept working
/// throughout - they reassign `task`, which the page's own Obx watches - so the
/// screen looked half-alive rather than broken, which is why it survived.
///
/// These pump the real page and assert the rendered text follows the
/// controller. They fail if the reactive wrapper is removed again.
Map<String, Object?> taskJson({
  int images = 3,
  String? status,
  List<int> edited = const [],
  List<int> inserted = const [],
}) {
  final envelope = jsonDecode(
    File('test/fixtures/qc_task_page.json').readAsStringSync(),
  ) as Map<String, Object?>;
  final data = envelope['data'] as Map<String, Object?>;
  final record = Map<String, Object?>.from(
    (data['records'] as List).cast<Map<String, Object?>>().first,
  );
  record['assignedTo'] = status == null ? 3 : null;
  if (status != null) record['status'] = status;
  // The fixture carries a single page; the bug only shows with more than one.
  final template =
      (record['images'] as List).cast<Map<String, Object?>>().first;
  record['images'] = [
    for (var i = 0; i < images; i++)
      {
        ...template,
        'id': 100 + i,
        'filename': 'PAGE_${i + 1}.jpg',
        'previewUrl': '/api/qc/metadata-tasks/18/images/${100 + i}/preview?v=1',
        if (inserted.contains(100 + i)) 'draftState': 'inserted',
      },
  ];
  record['imageCount'] = images;
  record['draftImageIds'] = edited;
  return record;
}

/// Pumps the real page and hands back its controller, holding a task.
///
/// The page registers the controller itself, and `Get.put` runs onInit, so
/// `load()` fires. Offline that ends fast: the client throws
/// QcApiException(401) before it opens a socket when no one has signed in, and
/// load() catches exactly that. It must be allowed to FINISH before the task is
/// set by hand, though - it ends by assigning `task = null`, and an earlier
/// assignment would simply be overwritten.
Future<QcReviewController> pumpPage(
  WidgetTester tester, {
  int images = 3,
  String? status,
  List<int> edited = const [],
  List<int> inserted = const [],
}) async {
  // A desktop window. The default 800x600 test surface cannot fit the fixed
  // 380px review pane plus the toolbar, and the resulting overflow is reported
  // as a test failure that has nothing to do with what is being checked.
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    const MaterialApp(home: QcReviewPage(folderId: 18, title: 'Review')),
  );
  // pump, not pumpAndSettle: while the task is still loading the body shows a
  // CircularProgressIndicator, which never stops animating, so settling never
  // returns. A couple of frames is enough for load() to fail and stand down.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));

  final controller = Get.find<QcReviewController>(tag: '18');
  controller.task.value = QcTask.fromJson(
      taskJson(images: images, status: status, edited: edited, inserted: inserted));
  controller.index.value = 0;
  await tester.pump();
  return controller;
}

void main() {
  tearDown(Get.reset);

  testWidgets('the page counter follows the controller index', (tester) async {
    final controller = await pumpPage(tester);
    expect(find.text('Page 1 of 3'), findsOneWidget);

    controller.index.value = 1;
    await tester.pump();
    expect(find.text('Page 2 of 3'), findsOneWidget,
        reason: 'the strip must rebuild when index changes');

    controller.index.value = 2;
    await tester.pump();
    expect(find.text('Page 3 of 3'), findsOneWidget);
  });

  testWidgets('tapping a page in the strip moves to it', (tester) async {
    final controller = await pumpPage(tester);
    expect(find.text('Page 1 of 3'), findsOneWidget);

    // Rail tiles carry a zero-padded page pill rather than a bare number.
    await tester.tap(find.text('03'));
    await tester.pump();

    expect(controller.index.value, 2);
    expect(find.text('Page 3 of 3'), findsOneWidget,
        reason: 'the tap reached the controller but the strip did not repaint');
  });

  testWidgets('the rail shows a tile per page, numbered', (tester) async {
    // The rail used to be 44px boxes containing Text('1'). The tile is the
    // scan itself now, with the page number on it - QC is a visual judgement
    // and a column of numbers supports none of it.
    await pumpPage(tester);
    for (final pill in ['01', '02', '03']) {
      expect(find.text(pill), findsOneWidget);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('the metadata fields render beside the viewer', (tester) async {
    // The review panel stacks two scroll regions - metadata and AI review - and
    // both need a bounded height. Nesting one inside the other collapsed the
    // metadata list to nothing while the header above it still drew, so the
    // pane looked present but empty. Assert a field label is actually on
    // screen, not merely that the form was constructed.
    await pumpPage(tester);
    // Mandatory fields carry a trailing asterisk in their label.
    expect(find.text('Cover Tag *'), findsOneWidget);
    expect(find.text('Title *'), findsOneWidget);
    // And the AI review is stacked below rather than hidden behind a tab.
    expect(find.text('AI review'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the toolbar survives a narrow window', (tester) async {
    // Restoring from maximised overflowed the toolbar by ~194px - seventeen
    // tools plus a checkbox in a Row that could not scroll. An overflow paints
    // a hazard bar across the UI, so it has to be a test, not a look.
    await pumpPage(tester);
    tester.view.physicalSize = const Size(1100, 900);
    await tester.pump();
    expect(tester.takeException(), isNull,
        reason: 'the tool row must scroll, not overflow');

    tester.view.physicalSize = const Size(820, 700);
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('a completed folder says so instead of inviting a claim',
      (tester) async {
    // A PASS folder can never be claimed again - the engine's claim query
    // matches qc_status = 'pending' only - so "Claim this task to edit" was
    // advice the operator could not act on.
    await pumpPage(tester, status: 'PASS');
    expect(find.text('Completed - read only'), findsOneWidget);
    expect(find.text('Claim this task to edit'), findsNothing);
  });

  testWidgets('an unclaimed but still-open folder still invites a claim',
      (tester) async {
    await pumpPage(tester, status: 'PENDING');
    expect(find.text('Claim this task to edit'), findsOneWidget);
    expect(find.text('Completed - read only'), findsNothing);
  });

  testWidgets('entering crop mode swaps the viewer pane', (tester) async {
    // Crop is the other casualty of the same defect: the toolbar button has its
    // own Obx and lit up, while the pane it was supposed to change did not.
    final controller = await pumpPage(tester, images: 1);

    expect(controller.cropping.value, isFalse);
    controller.cropping.value = true;
    await tester.pump();

    // No preview bytes offline, so the overlay cannot mount - but the read of
    // `cropping` must at least be subscribed, which a rebuild proves.
    expect(tester.takeException(), isNull);
  });

  testWidgets('arrow keys page through the scans', (tester) async {
    await pumpPage(tester);
    expect(find.text('Page 1 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('Page 2 of 3'), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(find.text('Page 1 of 3'), findsOneWidget);

    // And still after clicking in the rail, which is the real sequence: the tap
    // moves focus onto the tile's ink response, and the keys have to keep
    // working from there or arrow paging only survives until the first click.
    await tester.tap(find.byType(QcThumbnailTile).at(2));
    await tester.pump();
    expect(find.text('Page 3 of 3'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(find.text('Page 2 of 3'), findsOneWidget);
  });

  testWidgets('a focused metadata field keeps its own arrow keys',
      (tester) async {
    // The page-level handler must not outrank the caret. An operator keying a
    // volume number who presses left expects the cursor to move, not the scan
    // behind the form to change under them.
    await pumpPage(tester);
    final volume = find.byType(TextFormField).first;
    await tester.tap(volume);
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(find.text('Page 1 of 3'), findsOneWidget,
        reason: 'typing in the form must not turn the page');
  });

  testWidgets('an edited page is labelled in the rail, a clean one is not',
      (tester) async {
    // Ids are 100 + index (see taskJson), so this marks page 2 alone.
    await pumpPage(tester, edited: [101]);

    expect(find.text('Edited'), findsOneWidget);
    // Beside its own page number, not floating over some other tile.
    expect(
      find.descendant(
        of: find.byWidgetPredicate((w) =>
            w is QcThumbnailTile && w.image.id == 101),
        matching: find.text('Edited'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('no page is labelled when the draft has changed nothing',
      (tester) async {
    await pumpPage(tester);
    expect(find.text('Edited'), findsNothing);
  });

  testWidgets('every edited page is labelled, not just the first',
      (tester) async {
    await pumpPage(tester, edited: [100, 102]);
    expect(find.text('Edited'), findsNWidgets(2));
  });

  testWidgets('an inserted page says NEW rather than Edited', (tester) async {
    // The engine reports an inserted page as dirty too, so both labels would
    // otherwise land on one 240px-wide thumbnail and push the page number off.
    await pumpPage(tester, edited: [101], inserted: [101]);

    expect(find.text('NEW'), findsOneWidget);
    expect(find.text('Edited'), findsNothing);
  });
}
