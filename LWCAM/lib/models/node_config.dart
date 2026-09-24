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
  /// Default false: existing installs get zero behavior change until an
  /// admin deliberately opts in from Settings.
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
  /// Whether THIS machine runs the deskew/crop/thumbnail phase: LWCAM
  /// supervises the bundled LWIP watcher and reports results to the DB.
  /// Default false — a capture-only station is unaffected. Set from LWCam
  /// Admin's Station Setup, like every field here.
  final bool processingEnabled;

  /// Folder LWIP watches for transferred image folders. Null ⇒ use
  /// [destinationPath] (the common same-PC case). Split-PC deployments point
  /// this at the shared destination via a UNC path.
  final String? processingInputRoot;

  /// Where LWIP writes processed output (mirrors `YYYYMMDD/<folder>`). Null ⇒
  /// a sibling `<input>_processed`. Must not be inside the input root.
  final String? processingOutputRoot;

  /// LWIP worker process count; 0 ⇒ LWIP auto-sizes (CPU-1).
  final int processingWorkers;

  /// Pixels added on EACH side of the detected content rect before LWIP crops,
  /// clamped to the image edge. Higher keeps more margin; 0 crops tight to the
  /// detected edge. Station Setup owns it and writes it into LWIP's generated
  /// `deskew_crop_config.json`, which is the single source every consumer reads
  /// — nothing hardcodes a crop padding any more.
  ///
  /// The default must stay in step with `DEFAULT_CROP_PADDING` in LWIP's
  /// `backend/deskew_crop_tool/config.py`: two languages cannot share a
  /// literal, and that constant is the fallback when the key is absent. Same
  /// change-one-change-the-other convention as `kProcessingMarkerName`.
  final int processingCropPadding;

  /// Whether LWIP reports finished folders to PostgreSQL itself.
  ///
  /// A folder only reaches a QC operator once `capture_folders.qc_status` is
  /// 'PENDING'. That used to be written only by LWCAM's 15s report agent, so an
  /// operator who transferred a box, closed LWCAM and went on leave left the
  /// batch processed on disk and invisible to QC until someone reopened the app.
  /// LWIP runs headless from logon, so it can report when nothing else is there.
  ///
  /// Both writers stay: the write is idempotent, and LWCAM's outbox still covers
  /// the offline case this path cannot. Defaults ON, because the stations most
  /// at risk are the ones nobody revisits to configure.
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

  const NodeConfig({
    this.pgHost,
    this.pgPort = 5432,
    this.pgDatabase,
    this.pgUser,
    this.pgPassword,
    this.pgUseSsl = false,
    this.syncEnabled = false,
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
    );
  }

  Map<String, Object?> toJson() => {
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
    return NodeConfig(
      pgHost: json['pgHost']?.toString(),
      pgPort: (json['pgPort'] as num?)?.toInt() ?? 5432,
      pgDatabase: json['pgDatabase']?.toString(),
      pgUser: json['pgUser']?.toString(),
      pgPassword: json['pgPassword']?.toString(),
      pgUseSsl: json['pgUseSsl'] as bool? ?? false,
      syncEnabled: json['syncEnabled'] as bool? ?? false,
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
