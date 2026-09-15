import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:lwcam/controllers/qc_ai_review_controller.dart';
import 'package:lwcam/controllers/qc_review_controller.dart';
import 'package:lwcam/models/qc_task.dart';

/// The AI panel must learn about an existing review even though it is built
/// BEFORE the task it depends on has loaded.
///
/// `loadLatest` bails while `review.canEdit` is false, and this controller is
/// created during the page's first build, when QcReviewController.load() is
/// still in flight. Nothing re-ran it, so `job` stayed null for the whole
/// session - and a null job makes `start()` send force:false, which the engine
/// answers by handing back the previous FAILED job instead of running a new one.
/// The operator sees a button that does nothing at all.
///
/// QcApiClient has a private constructor and cannot be faked, so these assert
/// through observable state: signed out, the client throws QcApiException(401)
/// before it opens a socket, and loadLatest records that in `error`. A
/// non-empty `error` therefore means the call was actually attempted.
Map<String, Object?> taskJson({int? assignedTo}) => {
      'id': 7,
      'status': 'pending',
      'sourceHash': 'a' * 64,
      'assignedTo': assignedTo,
      'metadata': <String, Object?>{'folderId': 7},
      'metadataTemplate': {'fields': <Object?>[]},
      'images': <Object?>[],
    };

QcAiReviewController controllerBuiltBeforeTheTask(QcReviewController review) {
  final ai = QcAiReviewController(review);
  ai.onInit();
  return ai;
}

void main() {
  tearDown(Get.reset);

  test('nothing is asked while the task has not loaded', () async {
    final review = QcReviewController(7);
    final ai = controllerBuiltBeforeTheTask(review);
    await pumpEventQueue();

    expect(ai.error.value, isEmpty,
        reason: 'there is no claim to ask about yet');
  });

  test('an unclaimed task still asks nothing', () async {
    // Reading an unclaimed folder is allowed; asking for its AI job is a 403.
    final review = QcReviewController(7);
    final ai = controllerBuiltBeforeTheTask(review);

    review.task.value = QcTask.fromJson(taskJson(assignedTo: null));
    await pumpEventQueue();

    expect(ai.error.value, isEmpty);
  });

  test('the latest review is fetched once a claimed task arrives', () async {
    final review = QcReviewController(7);
    final ai = controllerBuiltBeforeTheTask(review);
    expect(ai.error.value, isEmpty);

    review.task.value = QcTask.fromJson(taskJson(assignedTo: 3));
    await pumpEventQueue();

    expect(ai.error.value, isNotEmpty,
        reason: 'the panel must ask the engine once the claim is known - '
            'without this it never learns the previous job failed, and its '
            'next start() sends force:false');
  });
}
