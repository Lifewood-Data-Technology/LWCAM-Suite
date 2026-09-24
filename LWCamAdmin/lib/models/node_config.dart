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
  /// (`%USERPROFILE%\LWCAM_DBs`). Overriding this is for the rare fully
  /// offline multi-station site with no PostgreSQL: several LWCAM installs
  /// (and this app) point at one shared local/network folder instead of
  /// each keeping an independent snapshot. Read-only consumption on the
  /// LWCAM side; this app is the only writer either way.
  final String? usersStorePath;

  /// This app's own on/off switch for its PostgreSQL reconcile (probe +
  /// push + pull) — distinct from [syncEnabled], which governs LWCAM's
  /// capture-data outbox drain and means nothing here. Default true:
  /// existing configured stations keep trying PG exactly as before. Lets an
  /// admin keep credentials saved but stop connection attempts without
  /// clearing them — e.g. a permanently-offline site, or simulating one for
  /// testing.
  final bool pgConnectionEnabled;

  /// The image destination root LWCAM's transfers land in — station
  /// configuration, so it lives here (set only from this app's Station
  /// Setup) rather than in LWCAM's own per-user prefs. Null/empty means
  /// not configured yet; LWCAM refuses to start a transfer until it is.
  final String? destinationPath;

  // ── Image-processing phase (LWIP) ─────────────────────────────────────────
  /// Whether the LWCAM on this machine runs the deskew/crop/thumbnail phase
  /// (supervises LWIP + reports results). Default false. Set here in Station
  /// Setup; LWCAM reads it.
  final bool processingEnabled;

  /// Folder LWIP watches. Null ⇒ use [destinationPath]. Split-PC deployments
  /// point this at the shared destination via a UNC path.
  final String? processingInputRoot;

  /// Where LWIP writes processed output. Null ⇒ sibling `<input>_processed`.
  /// Must not be inside the input root.
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

  /// Fields for QC/export/upload/AI settings remain for backward compatibility
  /// — older files still round-trip. The QC server now owns its own `config.txt`
  /// and does not read this file; these fields exist only so Admin can preserve
  /// them on load.
  final String? qcInputRoot;
  final String? qcOutputRoot;

  /// Whether a finished export is published as one ZIP or as a plain folder.
  ///
  /// Which one is right belongs to the downstream ingest team, and differs
  /// between projects, so it is station configuration rather than a code branch.
  /// True (a ZIP) is the long-standing behaviour and stays the default.
  final bool exportZipOutput;

  /// Whether the QC review screen offered Luminance Correction - a tone rewrite,
  /// i.e. image enhancement, which FamilySearch forbids; default false.
  ///
  /// Round-trip only, like the fields above: the QC server's own `config.txt`
  /// (`luminanceEnabled`, edited in the QC console) is what decides it now, and
  /// Station Setup no longer shows the switch.
  final bool luminanceEnabled;

  /// The old capture-path prefix remap the QC engine used to read from here.
  /// Round-trip only: the QC server replaced the pair with `qcImagesRoot` in
  /// its own `config.txt`. `captureImageHostPath` was the prefix as RECORDED,
  /// `captureImageContainerPath` the one the QC PC could open.
  ///
  /// Both null/blank on a single-PC station, where the recorded path already
  /// resolves. They matter on a split site: the capture PC records its own
  /// local path, and a QC/export station maps that prefix onto the capture PC's
  /// UNC share. Remapping here rather than recording UNC paths keeps the
  /// capture PC writing at local speed - and the column is LWCAM's, so
  /// rewriting it would break LWCAM and LWIP, which read the same values.
  final String? captureImageHostPath;
  final String? captureImageContainerPath;

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

  /// Upload phase: the QC engine on this PC pushes published export packages
  /// to S3. Runs only where the export output folder lives, so it is a
  /// per-station toggle like processing and QC.
  final bool uploadEnabled;

  /// `s3://bucket/optional/prefix`. Parsed by the engine; kept verbatim here.
  final String? uploadS3Path;
  final String? uploadS3Region;
  final String? uploadS3AccessKey;

  /// Plaintext in the per-machine file, like pgPassword and the OpenRouter
  /// key - and for the same reason this never goes near app_settings, which
  /// every capture PC copies.
  final String? uploadS3SecretKey;

  /// Where a package is moved once it is in the bucket, so the QC output
  /// folder holds only what has not gone up yet. Never inside that folder.
  final String? uploadDoneRoot;

  /// Folder holding Upload_Summary.db3, the one-row-per-upload SQLite file
  /// people open in DB Browser. The file name is fixed; only the folder moves.
  final String? uploadSummaryRoot;

  /// AI metadata review settings the QC engine used to read from here.
  ///
  /// Round-trip only: the QC server keeps them in its own `config.txt`
  /// (aiReviewEnabled, aiPreanalysisEnabled, openrouterApiKey and the two model
  /// names), edited in the QC console. They stay nullable so an older file that
  /// never set them still reads back as "not configured" rather than off.
  ///
  /// The reasoning that put the API key in this per-machine file still holds for
  /// its new home: never in `app_settings`, which LWCAM copies in plaintext to
  /// every capture PC's lwcam_users.json.
  final bool? aiReviewEnabled;
  final bool? aiPreanalysisEnabled;
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
    this.captureImageHostPath,
    this.captureImageContainerPath,
    this.qcJwtSecret,
    this.qcJwtExpireMinutes = 480,
    this.exportCsvEncoding = 'utf-8',
    this.exportCsvLineEnding = 'CRLF',
    this.exportTempRetentionHours = 24,
    this.uploadEnabled = false,
    this.uploadS3Path,
    this.uploadS3Region,
    this.uploadS3AccessKey,
    this.uploadS3SecretKey,
    this.uploadDoneRoot,
    this.uploadSummaryRoot,
    this.aiReviewEnabled,
    this.aiPreanalysisEnabled,
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
    String? captureImageHostPath,
    String? captureImageContainerPath,
    String? qcJwtSecret,
    int? qcJwtExpireMinutes,
    String? exportCsvEncoding,
    String? exportCsvLineEnding,
    int? exportTempRetentionHours,
    bool? uploadEnabled,
    String? uploadS3Path,
    String? uploadS3Region,
    String? uploadS3AccessKey,
    String? uploadS3SecretKey,
    String? uploadDoneRoot,
    String? uploadSummaryRoot,
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
      processingCropPadding:
          processingCropPadding ?? this.processingCropPadding,
      processingCloudReport:
          processingCloudReport ?? this.processingCloudReport,
      qcInputRoot: qcInputRoot ?? this.qcInputRoot,
      qcOutputRoot: qcOutputRoot ?? this.qcOutputRoot,
      exportWorkerCount: exportWorkerCount ?? this.exportWorkerCount,
      exportZipOutput: exportZipOutput ?? this.exportZipOutput,
      luminanceEnabled: luminanceEnabled ?? this.luminanceEnabled,
      captureImageHostPath: captureImageHostPath ?? this.captureImageHostPath,
      captureImageContainerPath:
          captureImageContainerPath ?? this.captureImageContainerPath,
      qcJwtSecret: qcJwtSecret ?? this.qcJwtSecret,
      qcJwtExpireMinutes: qcJwtExpireMinutes ?? this.qcJwtExpireMinutes,
      exportCsvEncoding: exportCsvEncoding ?? this.exportCsvEncoding,
      exportCsvLineEnding: exportCsvLineEnding ?? this.exportCsvLineEnding,
      exportTempRetentionHours:
          exportTempRetentionHours ?? this.exportTempRetentionHours,
      uploadEnabled: uploadEnabled ?? this.uploadEnabled,
      uploadS3Path: uploadS3Path ?? this.uploadS3Path,
      uploadS3Region: uploadS3Region ?? this.uploadS3Region,
      uploadS3AccessKey: uploadS3AccessKey ?? this.uploadS3AccessKey,
      uploadS3SecretKey: uploadS3SecretKey ?? this.uploadS3SecretKey,
      uploadDoneRoot: uploadDoneRoot ?? this.uploadDoneRoot,
      uploadSummaryRoot: uploadSummaryRoot ?? this.uploadSummaryRoot,
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
    'captureImageHostPath': captureImageHostPath,
    'captureImageContainerPath': captureImageContainerPath,
    'qcJwtSecret': qcJwtSecret,
    'qcJwtExpireMinutes': qcJwtExpireMinutes,
    'exportCsvEncoding': exportCsvEncoding,
    'exportCsvLineEnding': exportCsvLineEnding,
    'exportTempRetentionHours': exportTempRetentionHours,
    'uploadEnabled': uploadEnabled,
    'uploadS3Path': uploadS3Path,
    'uploadS3Region': uploadS3Region,
    'uploadS3AccessKey': uploadS3AccessKey,
    'uploadS3SecretKey': uploadS3SecretKey,
    'uploadDoneRoot': uploadDoneRoot,
    'uploadSummaryRoot': uploadSummaryRoot,
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
      processingCloudReport: json['processingCloudReport'] as bool? ?? true,
      qcInputRoot: json['qcInputRoot']?.toString(),
      qcOutputRoot: json['qcOutputRoot']?.toString(),
      exportWorkerCount: (json['exportWorkerCount'] as num?)?.toInt() ?? 0,
      exportZipOutput: json['exportZipOutput'] as bool? ?? true,
      luminanceEnabled: json['luminanceEnabled'] as bool? ?? false,
      captureImageHostPath: json['captureImageHostPath'] as String?,
      captureImageContainerPath: json['captureImageContainerPath'] as String?,
      qcJwtSecret: json['qcJwtSecret']?.toString(),
      qcJwtExpireMinutes: (json['qcJwtExpireMinutes'] as num?)?.toInt() ?? 480,
      exportCsvEncoding: json['exportCsvEncoding']?.toString() ?? 'utf-8',
      exportCsvLineEnding: json['exportCsvLineEnding']?.toString() ?? 'CRLF',
      exportTempRetentionHours:
          (json['exportTempRetentionHours'] as num?)?.toInt() ?? 24,
      uploadEnabled: json['uploadEnabled'] as bool? ?? false,
      uploadS3Path: json['uploadS3Path']?.toString(),
      uploadS3Region: json['uploadS3Region']?.toString(),
      uploadS3AccessKey: json['uploadS3AccessKey']?.toString(),
      uploadS3SecretKey: json['uploadS3SecretKey']?.toString(),
      uploadDoneRoot: json['uploadDoneRoot']?.toString(),
      uploadSummaryRoot: json['uploadSummaryRoot']?.toString(),
      // No `?? false`: a missing key is unset, and collapsing it to false here
      // is exactly what would overwrite the engine's own setting on first Save.
      aiReviewEnabled: json['aiReviewEnabled'] as bool?,
      aiPreanalysisEnabled: json['aiPreanalysisEnabled'] as bool?,
      openrouterApiKey: json['openrouterApiKey']?.toString(),
      openrouterExtractModel: json['openrouterExtractModel']?.toString(),
      openrouterCompareModel: json['openrouterCompareModel']?.toString(),
    );
  }
}
