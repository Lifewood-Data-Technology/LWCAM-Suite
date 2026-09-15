/// One AI-assisted metadata review job and its findings.
///
/// The engine reads the pages, compares what it sees against the keyed
/// metadata, and reports per field. It never writes anything by itself: the
/// reviewer picks which suggestions to take, and only suggestions the engine is
/// willing to stand behind can be picked at all (see [QcAiReviewField.canApply]).
class QcAiReviewJob {
  final String jobId;
  final int folderId;

  /// Identifies the exact metadata and pages this job looked at. Apply sends it
  /// back, and the engine refuses the apply if the folder has moved on since.
  final String inputHash;

  /// queued, running, succeeded, failed or cancelled.
  final String status;

  /// queued, extracting or comparing. Absent on a finished job.
  final String? stage;

  /// manual when the reviewer asked for it, preanalysis when the scanner ran it
  /// ahead of time.
  final String trigger;

  /// True once the folder has changed since the job ran, so its findings
  /// describe something that is no longer on screen.
  final bool stale;

  final String? error;
  final String? cancelReason;
  final int processedImages;
  final int totalImages;
  final QcAiReviewResult? result;

  const QcAiReviewJob({
    required this.jobId,
    required this.folderId,
    required this.inputHash,
    required this.status,
    required this.stage,
    required this.trigger,
    required this.stale,
    required this.error,
    required this.cancelReason,
    required this.processedImages,
    required this.totalImages,
    required this.result,
  });

  bool get isFinished =>
      status == 'succeeded' || status == 'failed' || status == 'cancelled';

  bool get isRunning => status == 'queued' || status == 'running';

  factory QcAiReviewJob.fromJson(Map<String, Object?> json) {
    final progress = json['progress'] as Map<String, Object?>? ?? const {};
    final result = json['result'] as Map<String, Object?>?;
    return QcAiReviewJob(
      jobId: json['jobId']?.toString() ?? '',
      folderId: (json['folderId'] as num?)?.toInt() ?? 0,
      inputHash: json['inputHash']?.toString() ?? '',
      status: json['status']?.toString() ?? '',
      stage: json['stage']?.toString(),
      trigger: json['trigger']?.toString() ?? 'manual',
      stale: json['stale'] as bool? ?? false,
      error: json['error']?.toString(),
      cancelReason: json['cancelReason']?.toString(),
      processedImages: (progress['processedImages'] as num?)?.toInt() ?? 0,
      totalImages: (progress['totalImages'] as num?)?.toInt() ?? 0,
      result: result == null ? null : QcAiReviewResult.fromJson(result),
    );
  }
}

class QcAiReviewResult {
  /// consistent, needs_review or insufficient_evidence.
  final String overallStatus;
  final List<QcAiReviewField> fieldReviews;

  /// Keys the reviewer has already taken from this job.
  final List<String> acceptedFields;

  const QcAiReviewResult({
    required this.overallStatus,
    required this.fieldReviews,
    required this.acceptedFields,
  });

  factory QcAiReviewResult.fromJson(Map<String, Object?> json) =>
      QcAiReviewResult(
        overallStatus: json['overallStatus']?.toString() ?? '',
        fieldReviews: (json['fieldReviews'] as List?)
                ?.whereType<Map<String, Object?>>()
                .map(QcAiReviewField.fromJson)
                .toList() ??
            const [],
        acceptedFields: (json['acceptedFields'] as List?)
                ?.map((key) => key.toString())
                .toList() ??
            const [],
      );
}

class QcAiReviewField {
  final String key;

  /// What the metadata said when the job ran. The engine compares this against
  /// the live value on apply and refuses if it has changed underneath.
  final String? currentValue;
  final String? suggestedValue;

  /// match, mismatch, uncertain or not_visible.
  final String verdict;
  final double confidence;
  final List<QcAiReviewEvidence> evidence;

  const QcAiReviewField({
    required this.key,
    required this.currentValue,
    required this.suggestedValue,
    required this.verdict,
    required this.confidence,
    required this.evidence,
  });

  /// The engine's own bar for accepting a suggestion.
  ///
  /// It rejects an apply that does not clear all three of these with a 400, so
  /// offering the checkbox anyway would just be a slower way to say no. Mirrored
  /// from `APPLY_CONFIDENCE` and the guard in `apply_ai_review_suggestions`.
  static const applyConfidence = 0.8;

  bool get canApply =>
      verdict == 'mismatch' &&
      confidence >= applyConfidence &&
      (suggestedValue?.isNotEmpty ?? false);

  factory QcAiReviewField.fromJson(Map<String, Object?> json) =>
      QcAiReviewField(
        key: json['key']?.toString() ?? '',
        currentValue: json['currentValue']?.toString(),
        suggestedValue: json['suggestedValue']?.toString(),
        verdict: json['verdict']?.toString() ?? '',
        confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
        evidence: (json['evidence'] as List?)
                ?.whereType<Map<String, Object?>>()
                .map(QcAiReviewEvidence.fromJson)
                .toList() ??
            const [],
      );
}

/// What the engine saw on one page, and where.
class QcAiReviewEvidence {
  final int imageId;
  final String filename;
  final String observation;

  const QcAiReviewEvidence({
    required this.imageId,
    required this.filename,
    required this.observation,
  });

  factory QcAiReviewEvidence.fromJson(Map<String, Object?> json) =>
      QcAiReviewEvidence(
        imageId: (json['imageId'] as num?)?.toInt() ?? 0,
        filename: json['filename']?.toString() ?? '',
        observation: json['observation']?.toString() ?? '',
      );
}
