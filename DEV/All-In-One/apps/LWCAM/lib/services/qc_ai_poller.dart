import 'dart:async';

import '../models/qc_ai_review.dart';
import 'qc_api_client.dart';

/// Polls one AI review job until it finishes.
///
/// The pacing rules are ported from the web console's poller rather than
/// reinvented: they encode two things learned there. Poll fast while the job is
/// visibly moving and back off when it is not, so a long extraction does not
/// hammer the engine. And separate the errors that mean "stop" from the ones
/// that mean "try again" - a dropped loopback connection is worth retrying, a
/// 403 never is.
class QcAiPoller {
  QcAiPoller({QcApiClient? api}) : _api = api ?? QcApiClient.instance;

  final QcApiClient _api;

  /// Backoff ladder. The first delay is short because most jobs report their
  /// first page quickly.
  static const delaysMs = <int>[1000, 2000, 4000, 8000, 10000];

  /// Codes that mean the job is not ours to watch any more: someone else took
  /// the claim, the job is gone, or the folder moved on. Retrying any of these
  /// just repeats the same answer.
  static const fatalStatusCodes = <int>[403, 404, 409];

  Timer? _timer;
  bool _stopped = false;

  /// Guards against a reply from a previous job landing after a restart and
  /// overwriting the current one.
  int _generation = 0;

  int _delayIndex = 0;
  String _lastSignature = '';

  /// How far apart two polls should be, given whether the job moved since the
  /// last one. Progress resets the ladder; a quiet job climbs it.
  static int nextDelayIndex(int current, {required bool progressed}) {
    if (progressed) return 0;
    return current + 1 >= delaysMs.length ? delaysMs.length - 1 : current + 1;
  }

  /// What changing here counts as the job having moved.
  static String progressSignature(QcAiReviewJob job) =>
      '${job.status}:${job.stage ?? ''}:'
      '${job.processedImages}:${job.totalImages}';

  /// Whether starting a review now should force a new run, and whether to ask
  /// the reviewer first.
  ///
  /// A failed or cancelled job is worth retrying outright. A finished job that
  /// still matches the folder would be thrown away by a re-run, so that one is
  /// worth a confirmation. Anything else - no job, or one already running -
  /// needs neither.
  static ({bool force, bool confirmRerun}) startAction(QcAiReviewJob? job) {
    if (job == null) return (force: false, confirmRerun: false);
    if (job.status == 'failed' || job.status == 'cancelled') {
      return (force: true, confirmRerun: false);
    }
    if (job.status == 'succeeded' && !job.stale) {
      return (force: true, confirmRerun: true);
    }
    return (force: false, confirmRerun: false);
  }

  /// The stage to show, filling in what the engine leaves implicit.
  ///
  /// A running job that has read every page but not yet reported is comparing,
  /// even before it says so.
  static String? resolveStage(QcAiReviewJob? job) {
    if (job == null) return null;
    if (job.status == 'queued') return 'queued';
    final stage = job.stage;
    if (stage != null && stage.isNotEmpty) return stage;
    if (job.status != 'running') return null;
    if (job.totalImages > 0 && job.processedImages >= job.totalImages) {
      return 'comparing';
    }
    return 'extracting';
  }

  /// Watches [jobId] until it reaches a terminal state.
  ///
  /// [onUpdate] fires on every reply, [onFinished] once when the job settles,
  /// and [onFatal] when polling has to give up.
  void start({
    required int folderId,
    required String jobId,
    required void Function(QcAiReviewJob job) onUpdate,
    required void Function(QcAiReviewJob job) onFinished,
    required void Function(QcApiException error) onFatal,
    QcAiReviewJob? initial,
  }) {
    stop();
    _stopped = false;
    final generation = ++_generation;
    _delayIndex = 0;
    _lastSignature = initial == null ? '' : progressSignature(initial);
    _schedule(generation, folderId, jobId, onUpdate, onFinished, onFatal);
  }

  void stop() {
    _stopped = true;
    _generation++;
    _timer?.cancel();
    _timer = null;
    _delayIndex = 0;
    _lastSignature = '';
  }

  void _schedule(
    int generation,
    int folderId,
    String jobId,
    void Function(QcAiReviewJob) onUpdate,
    void Function(QcAiReviewJob) onFinished,
    void Function(QcApiException) onFatal,
  ) {
    if (_stopped || generation != _generation) return;
    _timer = Timer(
      Duration(milliseconds: delaysMs[_delayIndex]),
      () => _poll(generation, folderId, jobId, onUpdate, onFinished, onFatal),
    );
  }

  Future<void> _poll(
    int generation,
    int folderId,
    String jobId,
    void Function(QcAiReviewJob) onUpdate,
    void Function(QcAiReviewJob) onFinished,
    void Function(QcApiException) onFatal,
  ) async {
    if (_stopped || generation != _generation) return;
    try {
      final job = QcAiReviewJob.fromJson(await _api.aiReviewJob(folderId, jobId));
      if (_stopped || generation != _generation) return;

      onUpdate(job);
      if (job.isFinished) {
        _timer = null;
        onFinished(job);
        return;
      }

      final signature = progressSignature(job);
      _delayIndex =
          nextDelayIndex(_delayIndex, progressed: signature != _lastSignature);
      _lastSignature = signature;
      _schedule(generation, folderId, jobId, onUpdate, onFinished, onFatal);
    } on QcApiException catch (e) {
      if (_stopped || generation != _generation) return;
      if (e.statusCode != null && fatalStatusCodes.contains(e.statusCode)) {
        _timer = null;
        onFatal(e);
        return;
      }
      // Everything else is worth another try: the engine is a local process and
      // a dropped connection here usually means it was busy, not broken.
      _delayIndex = nextDelayIndex(_delayIndex, progressed: false);
      _schedule(generation, folderId, jobId, onUpdate, onFinished, onFatal);
    }
  }
}
