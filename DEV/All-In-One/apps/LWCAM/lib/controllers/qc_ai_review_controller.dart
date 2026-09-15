import 'package:get/get.dart';

import '../models/qc_ai_review.dart';
import '../models/qc_task.dart';
import '../services/node_config_service.dart';
import '../services/qc_ai_poller.dart';
import '../services/qc_api_client.dart';
import 'qc_review_controller.dart';

/// Whether this station runs an AI review over every folder on its own.
///
/// Read from the LOCAL node config, not the engine: `ai_preanalysis_enabled` is
/// only exposed by `GET /api/admin/settings/paths`, which is admin-gated and so
/// unreachable for a `qc` account. The same `lwcam_node_config.json` drives the
/// engine, so the two cannot disagree.
///
/// False whenever the config has not loaded - an unknown setting must never hold
/// a folder shut.
bool _autoRunFromNodeConfig() {
  if (!Get.isRegistered<NodeConfigService>()) return false;
  return Get.find<NodeConfigService>().cached?.aiPreanalysisEnabled ?? false;
}

/// Runs the AI metadata review for the task on screen and holds its findings.
///
/// Kept apart from [QcReviewController] on a clean line: this owns the JOB, the
/// review controller owns the TASK. Applying a suggestion is a metadata write,
/// so it goes through the review controller and comes back as a new task, the
/// same as any other edit.
class QcAiReviewController extends GetxController {
  QcAiReviewController(
    this.review, {
    QcApiClient? api,
    QcAiPoller? poller,
    bool? autoRunEnabled,
  })  : _api = api ?? QcApiClient.instance,
        _poller = poller ?? QcAiPoller(),
        autoRun = autoRunEnabled ?? _autoRunFromNodeConfig();

  final QcReviewController review;

  /// This station reviews every folder automatically, so the reviewer is held at
  /// an "analysing" screen until the findings exist rather than being handed a
  /// task whose review lands minutes later. Injected in tests.
  final bool autoRun;
  final QcApiClient _api;
  final QcAiPoller _poller;

  final job = Rxn<QcAiReviewJob>();
  final loading = false.obs;
  final starting = false.obs;
  final applying = false.obs;
  final error = ''.obs;

  /// Set when the engine says AI review is switched off. That is a decision made
  /// in LWCam Admin, not a fault, so the panel explains rather than offers a
  /// retry that cannot succeed.
  final disabled = false.obs;

  /// Fields the reviewer has ticked to apply.
  final selected = <String>{}.obs;

  /// Suggestions the engine would actually accept. Anything else is shown as a
  /// finding but cannot be ticked - the engine rejects it with a 400, so a
  /// checkbox would only be a slower way to reach the same answer.
  List<QcAiReviewField> get appliable =>
      job.value?.result?.fieldReviews.where((f) => f.canApply).toList() ??
      const [];

  /// Findings worth a reviewer's attention even though they cannot be applied:
  /// low confidence, or the page did not show the field at all.
  List<QcAiReviewField> get advisory =>
      job.value?.result?.fieldReviews.where((f) => !f.canApply).toList() ??
      const [];

  /// True when the findings describe a folder that has since changed, so acting
  /// on them would be acting on an old picture.
  bool get isStale => job.value?.stale ?? false;

  String? get stage => QcAiPoller.resolveStage(job.value);

  /// True once [loadLatest] has actually run, rather than bailed on the claim.
  bool _latestLoaded = false;
  Worker? _taskReady;

  @override
  void onInit() {
    super.onInit();
    loadLatest();
    // ...and again when the task lands. This controller is built during the
    // page's first build, while QcReviewController.load() is still in flight, so
    // `canEdit` is false and the call above returns without asking the engine
    // anything. Nothing else re-ran it, which left `job` null for the rest of
    // the session - and a null job makes start() send force:false, so the engine
    // handed back the previous FAILED job instead of running a new one. From the
    // operator's side the button simply did nothing.
    _taskReady = ever<QcTask?>(review.task, (_) {
      if (!_latestLoaded) loadLatest();
    });
  }

  @override
  void onClose() {
    _taskReady?.dispose();
    _poller.stop();
    super.onClose();
  }

  /// Picks up a review that already exists - most often one the AI scanner ran
  /// before the reviewer opened the folder.
  Future<void> loadLatest() async {
    if (!review.canEdit) return;
    _latestLoaded = true;
    loading.value = true;
    try {
      final data = await _api.latestAiReview(review.folderId);
      if (data == null) {
        job.value = null;
        return;
      }
      final latest = QcAiReviewJob.fromJson(data);
      _adopt(latest);
      // A job left running from a previous session still needs watching.
      if (latest.isRunning) _watch(latest);
    } on QcApiException catch (e) {
      // 403 means the claim is not ours; the panel already says to claim first.
      if (e.statusCode != 403) error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  /// Whether starting now would discard a good result, so the view can ask.
  bool get wouldDiscardResult => QcAiPoller.startAction(job.value).confirmRerun;

  Future<bool> start() async {
    final task = review.task.value;
    if (task == null || !review.canEdit) return false;
    starting.value = true;
    error.value = '';
    try {
      final started = QcAiReviewJob.fromJson(await _api.startAiReview(
        task.folderId,
        task.sourceHash,
        force: QcAiPoller.startAction(job.value).force,
      ));
      disabled.value = false;
      _adopt(started);
      if (started.isRunning) _watch(started);
      return true;
    } on QcApiException catch (e) {
      // 503 is the engine reporting a setting, not a failure.
      if (e.statusCode == 503) {
        disabled.value = true;
      }
      error.value = e.message;
      return false;
    } finally {
      starting.value = false;
    }
  }

  void _watch(QcAiReviewJob from) {
    _poller.start(
      folderId: review.folderId,
      jobId: from.jobId,
      initial: from,
      onUpdate: _adopt,
      onFinished: _adopt,
      onFatal: (e) => error.value = e.message,
    );
  }

  /// Takes a job as the current one, dropping any ticks it invalidates.
  void _adopt(QcAiReviewJob value) {
    job.value = value;
    // A new job's findings are not the old job's, and a field that is no longer
    // appliable must not stay ticked - the apply would be rejected wholesale.
    final keys = value.result?.fieldReviews
            .where((f) => f.canApply)
            .map((f) => f.key)
            .toSet() ??
        const <String>{};
    selected.removeWhere((key) => !keys.contains(key));
  }

  void toggle(String key, bool on) {
    if (on) {
      selected.add(key);
    } else {
      selected.remove(key);
    }
  }

  void selectAll() {
    selected
      ..clear()
      ..addAll(appliable.map((f) => f.key));
  }

  void clearSelection() => selected.clear();

  /// Writes the ticked suggestions into the metadata draft.
  ///
  /// Nothing is applied unless the engine still agrees the review matches the
  /// folder; if it does not, it answers 409 and the reviewer is told to run it
  /// again rather than being handed a silent partial write.
  Future<bool> apply() async {
    final current = job.value;
    if (current == null || selected.isEmpty) return false;
    applying.value = true;
    error.value = '';
    try {
      final ok = await review.applyAiSuggestions(
        current.inputHash,
        selected.toList(),
      );
      if (!ok) {
        error.value = review.error.value;
        return false;
      }
      selected.clear();
      // The applied values are now the metadata, so the findings that described
      // the old ones are out of date; ask the engine for the current picture.
      await loadLatest();
      return true;
    } finally {
      applying.value = false;
    }
  }
}
