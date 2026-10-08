/// Per-machine sync configuration. Pure Dart — no Flutter/GetX imports,
/// matching the SharedAppSettings convention. Lives in its own file
/// (`lwcam_node_config.json`, see node_config_service.dart) — NOT the shared
/// users store, because site/connection details are per-MACHINE, not
/// per-site-NAS; and NOT SharedPreferences, because it must be
/// IT-provisionable (copy one file at install time) and readable before
/// login / when the NAS is unreachable.
///
/// The model is deliberately simple: sync ON means "push captured data to
/// the one configured PostgreSQL", sync OFF means "local SQLite only".
/// Whether that PostgreSQL is a LAN box or a cloud instance (Supabase/RDS
/// direct connection) makes no difference to the client — same host/port/
/// user/password/SSL. (The earlier role/cloud-forwarding tier was removed
/// 2026-07-18; legacy config files carrying `role`/`cloudUrl`/`cloudToken`
/// keys still load fine — the unknown keys are simply ignored.)
library;

class NodeConfig {
  // ── PostgreSQL connection (LAN or cloud — same direct connection) ───────
  final String? pgHost;
  final int pgPort;
  final String? pgDatabase;
  final String? pgUser;
  final String? pgPassword;
  final bool pgUseSsl;

  // ── Sync behaviour ───────────────────────────────────────────────────────
  /// Default true (2026-10-01): QC, LWIP and export only see a folder once
  /// LWCAM has sent it to PostgreSQL, so off silently stalls the pipeline.
  /// A config file that says false keeps it off.
  final bool syncEnabled;
  final int syncIntervalSeconds;

  /// Directory holding `lwcam_users.json`, or null for the default
  /// (`%USERPROFILE%\LWCAM_DBs`). Set by LWCam Admin's Station Setup — LWCAM
  /// only reads it (the local snapshot is read-only here). Overriding this
  /// is for the rare fully offline multi-station site with no PostgreSQL:
  /// several LWCAM installs point at one shared local/network folder instead
  /// of each keeping an independent snapshot.
  final String? usersStorePath;

  /// LWCam Admin's own on/off switch for its PostgreSQL reconcile (probe +
  /// push + pull) — distinct from [syncEnabled], which governs LWCAM's
  /// capture-data outbox drain. Default true: existing configured stations
  /// keep trying PG exactly as before. Lets an admin keep credentials saved
  /// but stop connection attempts without clearing them — e.g. a
  /// permanently-offline site, or simulating one for testing. LWCAM never
  /// reads this field.
  final bool pgConnectionEnabled;

  /// The image destination root LWCAM's transfers land in — station
  /// configuration, so it lives here (set only from LWCam Admin's Station
  /// Setup, like everything else in this file) rather than in LWCAM's own
  /// per-user prefs. Null/empty means not configured yet; LWCAM refuses to
  /// start a transfer until it is.
  final String? destinationPath;

  // ── Image-processing phase (LWIP) ─────────────────────────────────────────
  /// Round-trip only: LWIP now runs standalone on its own machine, configured
  /// by its own installer and config file, not by this one. The field remains
  /// only so an older `lwcam_node_config.json` survives a save.
  final bool processingEnabled;

  /// Round-trip only since 2026-09-28, like [processingEnabled]: rework used
  /// this and [processingOutputRoot] to find a recapture's original, and now
  /// finds it under [destinationPath] instead (`rework_service.dart`). Kept so
  /// an older `lwcam_node_config.json` survives a save.
  final String? processingInputRoot;

  /// Round-trip only - see [processingInputRoot].
  final String? processingOutputRoot;

  /// Round-trip only, like [processingEnabled]: LWIP's own config file now
  /// sets its worker count.
  final int processingWorkers;

  /// Round-trip only, like [processingEnabled]: LWIP's own config file now
  /// sets its crop padding.
  final int processingCropPadding;

  /// Round-trip only, like [processingEnabled]: LWIP reports every finished
  /// folder to PostgreSQL itself now (unconditionally — there is no longer a
  /// second, LWCAM-side reporter to make optional), so this switch decides
  /// nothing.
  final bool processingCloudReport;

  /// QC settings written by LWCam Admin and consumed by the QC backend.
  final String? qcInputRoot;
  final String? qcOutputRoot;

  /// Whether a finished export is published as one ZIP or as a plain folder.
  ///
  /// Which one is right belongs to the downstream ingest team, and differs
  /// between projects, so it is station configuration rather than a code branch.
  /// True (a ZIP) is the long-standing behaviour and stays the default.
  final bool exportZipOutput;

  /// Whether the QC review screen offers Luminance Correction.
  ///
  /// The tool rewrites a page's tones - a curve, an even-exposure pass, a warm
  /// cast correction. That is image enhancement in the plain sense, and clients
  /// working to archival standards forbid it: FamilySearch rejects deliveries
  /// that show any. It was never used on the Taiping batches, but the batch
  /// endpoint is one click away, so the guard belongs in configuration rather
  /// than in a reviewer's memory.
  ///
  /// False is the default since 2026-09-10: FamilySearch's standard is no
  /// manipulation, and a station that has never been configured must not
  /// offer the one tool in the chain that is enhancement by definition. A
  /// project that wants it turns it on in Station Setup.
  final bool luminanceEnabled;

  /// Worker processes the QC export uses to convert and hash images.
  ///
  /// 0 sizes it from the hardware the same way [processingWorkers] does for
  /// LWIP - every core but one. Both pools run on the same station, so setting
  /// this explicitly is how an operator stops them competing for the same cores.
  final int exportWorkerCount;
  final String? qcJwtSecret;
  final int qcJwtExpireMinutes;
  final String exportCsvEncoding;
  final String exportCsvLineEnding;
  final int exportTempRetentionHours;

  /// Placeholder toggle for the future Upload phase.
  final bool uploadEnabled;

  /// AI metadata review, used by the QC platform.
  ///
  /// Two stages: [aiReviewEnabled] is the master switch — off means no image ever
  /// leaves this machine for OpenRouter, by either the automatic scanner or the
  /// reviewer button. [aiPreanalysisEnabled] only decides whether the check runs
  /// automatically as tasks arrive, and means nothing while stage 1 is off.
  ///
  /// The API key lives HERE and never in `app_settings`: LWCAM pulls app_settings
  /// onto every capture PC and writes it to lwcam_users.json, so a key stored
  /// there would be copied in plaintext to every station. This file is per-machine,
  /// so the key stays on the PC that actually calls OpenRouter.
  final bool aiReviewEnabled;
  final bool aiPreanalysisEnabled;
  final String? openrouterApiKey;
  final String? openrouterExtractModel;
  final String? openrouterCompareModel;

  /// Keys in the file this build does not know — LWCam Admin's `adminPgUser` /
  /// `adminPgPasswordProtected`, legacy `role`/`cloudUrl`, anything a newer
  /// build adds. Carried untouched so a save from LWCAM never drops another
  /// app's settings.
  final Map<String, Object?> extras;

  const NodeConfig({
    this.pgHost,
    this.pgPort = 5432,
    this.pgDatabase,
    this.pgUser,
    this.pgPassword,
    this.pgUseSsl = false,
    this.syncEnabled = true,
    this.syncIntervalSeconds = 30,
    this.usersStorePath,
    this.pgConnectionEnabled = true,
    this.destinationPath,
    this.processingEnabled = false,
    this.processingInputRoot,
    this.processingOutputRoot,
    this.processingWorkers = 0,
    this.processingCropPadding = 200,
    this.processingCloudReport = true,
    this.qcInputRoot,
    this.qcOutputRoot,
    this.exportWorkerCount = 0,
    this.exportZipOutput = true,
    this.luminanceEnabled = false,
    this.qcJwtSecret,
    this.qcJwtExpireMinutes = 480,
    this.exportCsvEncoding = 'utf-8',
    this.exportCsvLineEnding = 'CRLF',
    this.exportTempRetentionHours = 24,
    this.uploadEnabled = false,
    this.aiReviewEnabled = false,
    this.aiPreanalysisEnabled = false,
    this.openrouterApiKey,
    this.openrouterExtractModel,
    this.openrouterCompareModel,
    this.extras = const {},
  });

  NodeConfig copyWith({
    String? pgHost,
    int? pgPort,
    String? pgDatabase,
    String? pgUser,
    String? pgPassword,
    bool? pgUseSsl,
    bool? syncEnabled,
    int? syncIntervalSeconds,
    String? usersStorePath,
    bool? pgConnectionEnabled,
    String? destinationPath,
    bool? processingEnabled,
    String? processingInputRoot,
    String? processingOutputRoot,
    int? processingWorkers,
    int? processingCropPadding,
    bool? processingCloudReport,
    String? qcInputRoot,
    String? qcOutputRoot,
    int? exportWorkerCount,
    bool? exportZipOutput,
    bool? luminanceEnabled,
    String? qcJwtSecret,
    int? qcJwtExpireMinutes,
    String? exportCsvEncoding,
    String? exportCsvLineEnding,
    int? exportTempRetentionHours,
    bool? uploadEnabled,
    bool? aiReviewEnabled,
    bool? aiPreanalysisEnabled,
    String? openrouterApiKey,
    String? openrouterExtractModel,
    String? openrouterCompareModel,
    Map<String, Object?>? extras,
  }) {
    return NodeConfig(
      pgHost: pgHost ?? this.pgHost,
      pgPort: pgPort ?? this.pgPort,
      pgDatabase: pgDatabase ?? this.pgDatabase,
      pgUser: pgUser ?? this.pgUser,
      pgPassword: pgPassword ?? this.pgPassword,
      pgUseSsl: pgUseSsl ?? this.pgUseSsl,
      syncEnabled: syncEnabled ?? this.syncEnabled,
      syncIntervalSeconds: syncIntervalSeconds ?? this.syncIntervalSeconds,
      usersStorePath: usersStorePath ?? this.usersStorePath,
      pgConnectionEnabled: pgConnectionEnabled ?? this.pgConnectionEnabled,
      destinationPath: destinationPath ?? this.destinationPath,
      processingEnabled: processingEnabled ?? this.processingEnabled,
      processingInputRoot: processingInputRoot ?? this.processingInputRoot,
      processingOutputRoot: processingOutputRoot ?? this.processingOutputRoot,
      processingWorkers: processingWorkers ?? this.processingWorkers,
      processingCropPadding: processingCropPadding ?? this.processingCropPadding,
      processingCloudReport: processingCloudReport ?? this.processingCloudReport,
      qcInputRoot: qcInputRoot ?? this.qcInputRoot,
      qcOutputRoot: qcOutputRoot ?? this.qcOutputRoot,
      exportWorkerCount: exportWorkerCount ?? this.exportWorkerCount,
      exportZipOutput: exportZipOutput ?? this.exportZipOutput,
      luminanceEnabled: luminanceEnabled ?? this.luminanceEnabled,
      qcJwtSecret: qcJwtSecret ?? this.qcJwtSecret,
      qcJwtExpireMinutes: qcJwtExpireMinutes ?? this.qcJwtExpireMinutes,
      exportCsvEncoding: exportCsvEncoding ?? this.exportCsvEncoding,
      exportCsvLineEnding: exportCsvLineEnding ?? this.exportCsvLineEnding,
      exportTempRetentionHours:
          exportTempRetentionHours ?? this.exportTempRetentionHours,
      uploadEnabled: uploadEnabled ?? this.uploadEnabled,
      aiReviewEnabled: aiReviewEnabled ?? this.aiReviewEnabled,
      aiPreanalysisEnabled: aiPreanalysisEnabled ?? this.aiPreanalysisEnabled,
      openrouterApiKey: openrouterApiKey ?? this.openrouterApiKey,
      openrouterExtractModel:
          openrouterExtractModel ?? this.openrouterExtractModel,
      openrouterCompareModel:
          openrouterCompareModel ?? this.openrouterCompareModel,
      extras: extras ?? this.extras,
    );
  }

  Map<String, Object?> toJson() => {
    ...extras,
    'pgHost': pgHost,
    'pgPort': pgPort,
    'pgDatabase': pgDatabase,
    'pgUser': pgUser,
    'pgPassword': pgPassword,
    'pgUseSsl': pgUseSsl,
    'syncEnabled': syncEnabled,
    'syncIntervalSeconds': syncIntervalSeconds,
    'usersStorePath': usersStorePath,
    'pgConnectionEnabled': pgConnectionEnabled,
    'destinationPath': destinationPath,
    'processingEnabled': processingEnabled,
    'processingInputRoot': processingInputRoot,
    'processingOutputRoot': processingOutputRoot,
    'processingWorkers': processingWorkers,
    'processingCropPadding': processingCropPadding,
    'processingCloudReport': processingCloudReport,
    'qcInputRoot': qcInputRoot,
    'qcOutputRoot': qcOutputRoot,
    'exportWorkerCount': exportWorkerCount,
    'exportZipOutput': exportZipOutput,
    'luminanceEnabled': luminanceEnabled,
    'qcJwtSecret': qcJwtSecret,
    'qcJwtExpireMinutes': qcJwtExpireMinutes,
    'exportCsvEncoding': exportCsvEncoding,
    'exportCsvLineEnding': exportCsvLineEnding,
    'exportTempRetentionHours': exportTempRetentionHours,
    'uploadEnabled': uploadEnabled,
    'aiReviewEnabled': aiReviewEnabled,
    'aiPreanalysisEnabled': aiPreanalysisEnabled,
    'openrouterApiKey': openrouterApiKey,
    'openrouterExtractModel': openrouterExtractModel,
    'openrouterCompareModel': openrouterCompareModel,
  };

  factory NodeConfig.fromJson(Map<String, Object?> json) {
    final known = const NodeConfig().toJson().keys.toSet();
    return NodeConfig(
      extras: {
        for (final e in json.entries)
          if (!known.contains(e.key)) e.key: e.value,
      },
      pgHost: json['pgHost']?.toString(),
      pgPort: (json['pgPort'] as num?)?.toInt() ?? 5432,
      pgDatabase: json['pgDatabase']?.toString(),
      pgUser: json['pgUser']?.toString(),
      pgPassword: json['pgPassword']?.toString(),
      pgUseSsl: json['pgUseSsl'] as bool? ?? false,
      syncEnabled: json['syncEnabled'] as bool? ?? true,
      syncIntervalSeconds: (json['syncIntervalSeconds'] as num?)?.toInt() ?? 30,
      usersStorePath: json['usersStorePath']?.toString(),
      pgConnectionEnabled: json['pgConnectionEnabled'] as bool? ?? true,
      destinationPath: json['destinationPath']?.toString(),
      processingEnabled: json['processingEnabled'] as bool? ?? false,
      processingInputRoot: json['processingInputRoot']?.toString(),
      processingOutputRoot: json['processingOutputRoot']?.toString(),
      processingWorkers: (json['processingWorkers'] as num?)?.toInt() ?? 0,
      processingCropPadding:
          (json['processingCropPadding'] as num?)?.toInt() ?? 200,
      processingCloudReport:
          json['processingCloudReport'] as bool? ?? true,
      qcInputRoot: json['qcInputRoot']?.toString(),
      qcOutputRoot: json['qcOutputRoot']?.toString(),
      exportWorkerCount: (json['exportWorkerCount'] as num?)?.toInt() ?? 0,
      exportZipOutput: json['exportZipOutput'] as bool? ?? true,
      luminanceEnabled: json['luminanceEnabled'] as bool? ?? false,
      qcJwtSecret: json['qcJwtSecret']?.toString(),
      qcJwtExpireMinutes: (json['qcJwtExpireMinutes'] as num?)?.toInt() ?? 480,
      exportCsvEncoding: json['exportCsvEncoding']?.toString() ?? 'utf-8',
      exportCsvLineEnding: json['exportCsvLineEnding']?.toString() ?? 'CRLF',
      exportTempRetentionHours:
          (json['exportTempRetentionHours'] as num?)?.toInt() ?? 24,
      uploadEnabled: json['uploadEnabled'] as bool? ?? false,
      aiReviewEnabled: json['aiReviewEnabled'] as bool? ?? false,
      aiPreanalysisEnabled: json['aiPreanalysisEnabled'] as bool? ?? false,
      openrouterApiKey: json['openrouterApiKey']?.toString(),
      openrouterExtractModel: json['openrouterExtractModel']?.toString(),
      openrouterCompareModel: json['openrouterCompareModel']?.toString(),
    );
  }
}
