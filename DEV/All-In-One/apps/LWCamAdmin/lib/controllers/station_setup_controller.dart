import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../models/node_config.dart';
import '../services/admin_bootstrap.dart';
import '../services/admin_pg_gateway.dart';
import '../services/qc_path_advice.dart';
import '../services/lwip_autostart_service.dart';
import '../services/lwip_config_writer.dart';
import '../services/qc_backend_autostart_service.dart';
import '../services/station_seed.dart';
import '../services/node_config_service.dart';
import '../services/pg_client.dart';

/// Returns the installed QC folder, or null when QC is not on this PC.
///
/// Two layouts are recognised. The installer lays Admin and QC beside each
/// other (`<install>\LWCamAdmin\`, `<install>\QC\`), which is what a
/// deployed station looks like. A source or portable tree instead keeps the
/// platform as `LWCam_QC_Platform`, and there the Admin exe can sit several
/// folders below the suite root (`bin\LWCamAdmin\`, or Flutter's own
/// `build\...\Release\`), so every ancestor is checked as well - the same
/// walk LWCAM uses to find its bundled `LWIP\`. Without the second layout
/// Station Setup greys out its QC fields on a machine that plainly has QC.
String? qcInstallRoot({
  String? executablePath,
  Map<String, String>? environment,
}) {
  final roots = <String>[];
  var dir = p.dirname(executablePath ?? Platform.resolvedExecutable);
  for (var level = 0; level < 8; level++) {
    roots.add(dir);
    final parent = p.dirname(dir);
    if (parent == dir) break; // reached the drive root
    dir = parent;
  }
  final programFiles = (environment ?? Platform.environment)['ProgramFiles'];
  if (programFiles != null && programFiles.isNotEmpty) {
    roots.add(p.join(programFiles, 'LW Suite'));
  }
  for (final root in roots) {
    // Installed layout: the launcher the installer writes.
    final installed = p.join(root, 'QC');
    if (File(p.join(installed, 'START_QC_BACKEND.bat')).existsSync()) {
      return installed;
    }
    // Source layout, with or without the `apps` level in between. The backend
    // entry point is the marker, since a source tree has no launcher .bat.
    for (final relative in const [
      ['LWCam_QC_Platform'],
      ['apps', 'LWCam_QC_Platform'],
    ]) {
      final source = p.joinAll([root, ...relative]);
      if (File(p.join(source, 'backend', 'app', 'main.py')).existsSync()) {
        return source;
      }
    }
  }
  return null;
}

/// The installed launcher that provisions the QC database, or null when there
/// is none to run.
///
/// [qcInstallRoot] deliberately answers for two different layouts, and only one
/// of them has .bat launchers: SETUP_QC_DB.bat is written by the installer and
/// exists nowhere else, so a source or portable tree resolves to a folder that
/// has never contained it. A caller that needs the launcher specifically has to
/// ask for it rather than assume the root it was handed has one - inferring it
/// is what made Station Setup run a path that does not exist in a source tree.
///
/// Absence is treated as "source tree", not "damaged install", because the
/// installer ships this launcher and START_QC_BACKEND.bat in the same [Files]
/// group, and the installed layout is only recognised when the latter is
/// present. One without the other means someone deleted it by hand.
String? qcSetupDbScript({
  String? executablePath,
  Map<String, String>? environment,
}) {
  final root = qcInstallRoot(
    executablePath: executablePath,
    environment: environment,
  );
  if (root == null) return null;
  final script = p.join(root, 'SETUP_QC_DB.bat');
  return File(script).existsSync() ? script : null;
}

bool isQcAppInstalled({
  String? executablePath,
  Map<String, String>? environment,
}) =>
    qcInstallRoot(executablePath: executablePath, environment: environment) !=
    null;

/// The suite's pipeline root, `<install>\LWCam Capture`. Same derivation as
/// [qcInstallRoot]: the installer always lays Admin down as
/// `<install>\LWCamAdmin\lwcam_admin.exe`, so an exe whose own folder is named
/// `LWCamAdmin` is an installed one and the install folder is one level up —
/// which keeps working when the operator installs somewhere other than
/// `%ProgramFiles%\LW Suite`. A dev/portable build (its folder is `Release`)
/// has no install folder to speak of and gets the installer's own default.
///
/// The installer creates these three folders with users-modify rights
/// (LWSuite.iss `[Dirs]`), because everything that writes into them — LWCAM,
/// LWIP, the QC servers — runs as a normal user, and Program Files is
/// admin-only by default.
String defaultCaptureRoot({
  String? executablePath,
  Map<String, String>? environment,
}) {
  final exeDir = p.dirname(executablePath ?? Platform.resolvedExecutable);
  final root = p.basename(exeDir) == 'LWCamAdmin'
      ? p.dirname(exeDir)
      : p.join(
          (environment ?? Platform.environment)['ProgramFiles'] ??
              r'C:\Program Files',
          'LW Suite',
        );
  return p.join(root, 'LWCam Capture');
}

/// Stage folders of the capture pipeline, numbered so their order is obvious
/// in Explorer: LWCAM lands images in 1, LWIP writes batches to 2, QC exports
/// to 3. QC reads 2 as its input/work folder — the same folder LWIP fills.
const String captureImagesFolder = '1.Images';
const String captureBatchesFolder = '2.Batches';
const String captureExportFolder = '3.Export';
const String captureUploadedFolder = '4.Uploaded';

/// Sibling of the capture root (`<install root>\\Upload Reports`), holding
/// Upload_Summary.db3.
const String uploadReportsFolder = 'Upload Reports';

/// PostgreSQL connection defaults, kept identical to the QC backend's own
/// (`backend/app/core/config.py`): a fresh PostgreSQL install has only the
/// `postgres` superuser, and the suite ships no server, so these are the only
/// values that can already be correct before an operator creates anything.
/// Pre-filled for the same reason the folder fields default below - a fresh
/// station should be one Save away from working, leaving a non-technical
/// operator just the password to type. A value already in the config file
/// always wins. No password default: that would be a credential in source,
/// and one that silently "works" is worse than a connection error saying so.
const String defaultPgHost = 'localhost';
const String defaultPgDatabase = 'lwcam';
const String defaultPgUser = 'postgres';

String _newJwtSecret() {
  final random = Random.secure();
  return base64Url
      .encode(List<int>.generate(32, (_) => random.nextInt(256)))
      .replaceAll('=', '');
}

/// This machine's PostgreSQL connection + local snapshot path
/// (`lwcam_node_config.json`) — the file LWCAM's SyncBootstrap also reads,
/// so Station Setup here is how a fresh capture PC gets provisioned.
class StationSetupController extends GetxController {
  final pgHost = ''.obs;
  final pgPort = 5432.obs;
  final pgDatabase = ''.obs;
  final pgUser = ''.obs;
  final pgPassword = ''.obs;
  final pgUseSsl = false.obs;
  final syncIntervalSeconds = 30.obs;
  final usersStorePath = ''.obs;

  /// This app's own on/off switch for its PostgreSQL reconcile — lets an
  /// admin keep credentials saved but stop connection attempts (e.g. a
  /// permanently-offline site, or simulating one for testing) without
  /// clearing them. Does not affect LWCAM's own outbox toggle below.
  final pgConnectionEnabled = true.obs;

  /// True once the saved config has actually been read into the Rx fields.
  /// The page gates its form on this: its TextFormFields use initialValue +
  /// stable keys, so values set AFTER the first build would never render —
  /// an admin would see blank fields over a fully configured station.
  final isLoaded = false.obs;
  bool _loaded = false;

  // ── LWCAM capture-station settings (this app is their ONLY editor —
  // LWCAM's own Settings page was removed; only SuperAdmin configures a
  // station) ────────────────────────────────────────────────────────────

  /// LWCAM's capture-data outbox drain on/off — a DIFFERENT concern from
  /// this app's users/projects reconcile (AdminStoreService always tries
  /// PG when a host is configured and [pgConnectionEnabled] is on,
  /// regardless of this flag).
  final lwcamSyncEnabled = false.obs;

  /// The image destination root LWCAM's transfers land in. Empty = not
  /// configured; LWCAM refuses to start a transfer until it is set.
  final destinationPath = ''.obs;

  // ── Image-processing phase (LWIP) ─────────────────────────────────────────
  final processingEnabled = false.obs;
  final processingInputRoot = ''.obs;
  final processingOutputRoot = ''.obs;
  final processingWorkers = 0.obs;
  final processingCropPadding = 200.obs;
  final processingCloudReport = true.obs;

  /// Non-empty when the last save could not register LWIP to start at logon.
  /// Surfaced on the page: processing silently not running is the failure mode
  /// nobody notices until a day of captures has piled up unprocessed.
  final lwipAutostartWarning = ''.obs;

  /// Same channel as [lwipAutostartWarning], for the QC backend: a station that
  /// saved fine but cannot bring its server up at logon has to say so, because
  /// nothing else will until someone opens QC review and finds it dead.
  final qcBackendAutostartWarning = ''.obs;

  /// What first-run provisioning did, for the page to show once. Empty when
  /// there was nothing to do - which is every launch after the first.
  final firstRunStatus = ''.obs;

  /// Set while provisioning runs, so the page can say so instead of looking
  /// frozen: creating the database and loading the schema takes a few seconds.
  final isProvisioning = false.obs;

  /// Guard: provisioning is a one-shot, and the page calls ensureLoaded(force:
  /// true) every time it is opened.
  bool _seedChecked = false;

  // ── QC backend ─────────────────────────────────────────────────────────────
  final qcInstalled = false.obs;
  final qcInputRoot = ''.obs;
  final qcOutputRoot = ''.obs;

  /// 0 = size it from the hardware, like LWIP's own worker setting.
  final exportWorkerCount = 0.obs;

  /// True publishes one ZIP per group; false publishes a plain folder.
  final exportZipOutput = true.obs;
  final luminanceEnabled = false.obs;

  /// Prefix remap for images captured on ANOTHER PC — see NodeConfig.
  /// Blank on a single-PC station.
  final captureImageHostPath = ''.obs;
  final captureImageContainerPath = ''.obs;

  /// Set when the QC work and output folders are on different drives.
  ///
  /// This used to REFUSE the save. Nothing in the engine requires one drive:
  /// every rename it performs targets a sibling built from the destination's own
  /// name, and the export's only cross-root step copies before it renames, so
  /// the three capture roots may sit on three separate disks - which is a
  /// deliberate layout on a station with a fast scratch disk, not a mistake.
  /// It stays a warning rather than nothing because a SPLIT that was not
  /// intended costs a full cross-volume copy of every package.
  final qcDriveWarning = ''.obs;
  String _qcJwtSecret = '';
  int _qcJwtExpireMinutes = 480;
  String _exportCsvEncoding = 'utf-8';
  String _exportCsvLineEnding = 'CRLF';
  int _exportTempRetentionHours = 24;

  // ── Upload phase (S3, run by the QC engine on this PC) ────────────────────
  final uploadEnabled = false.obs;
  final uploadS3Path = ''.obs;
  final uploadS3Region = ''.obs;
  final uploadS3AccessKey = ''.obs;
  final uploadS3SecretKey = ''.obs;
  final uploadDoneRoot = ''.obs;
  final uploadSummaryRoot = ''.obs;

  // AI metadata review (consumed by the QC platform, configured here because
  // Admin is the only configuration tool in the suite).
  // Nullable on purpose: null is "never configured on this station" and must
  // stay out of the written config. See NodeConfig.aiReviewEnabled.
  final aiReviewEnabled = Rxn<bool>();
  final aiPreanalysisEnabled = Rxn<bool>();
  final openrouterApiKey = ''.obs;
  final openrouterExtractModel = ''.obs;
  final openrouterCompareModel = ''.obs;

  NodeConfigService get _service => Get.find<NodeConfigService>();

  Future<void> ensureLoaded({bool force = false}) async {
    if (_loaded && !force) return;
    _loaded = true;
    isLoaded.value = false; // page shows a spinner while (re)reading
    // Always from DISK, never the in-memory cache: LWCAM shares this file
    // and may have rewritten it (its own Sync section) since this app
    // first loaded it — editing a stale copy would save the stale values
    // back over LWCAM's.
    final config = await _service.reload();
    pgHost.value = config.pgHost ?? defaultPgHost;
    pgPort.value = config.pgPort;
    pgDatabase.value = config.pgDatabase ?? defaultPgDatabase;
    pgUser.value = config.pgUser ?? defaultPgUser;
    pgPassword.value = config.pgPassword ?? '';
    pgUseSsl.value = config.pgUseSsl;
    syncIntervalSeconds.value = config.syncIntervalSeconds;
    usersStorePath.value = config.usersStorePath ?? '';
    pgConnectionEnabled.value = config.pgConnectionEnabled;
    lwcamSyncEnabled.value = config.syncEnabled;
    // Unset folders start on the suite's own pipeline layout rather than
    // blank, so a fresh station is one Save away from working. An admin can
    // still point any of them anywhere (a NAS, another drive, a UNC share);
    // a value already in the file always wins.
    final root = defaultCaptureRoot();
    final images = p.join(root, captureImagesFolder);
    final batches = p.join(root, captureBatchesFolder);
    destinationPath.value = config.destinationPath ?? images;
    processingEnabled.value = config.processingEnabled;
    processingInputRoot.value = config.processingInputRoot ?? images;
    processingOutputRoot.value = config.processingOutputRoot ?? batches;
    processingWorkers.value = config.processingWorkers;
    processingCropPadding.value = config.processingCropPadding;
    processingCloudReport.value = config.processingCloudReport;
    qcInstalled.value = isQcAppInstalled();
    qcInputRoot.value = config.qcInputRoot ?? batches;
    qcOutputRoot.value =
        config.qcOutputRoot ?? p.join(root, captureExportFolder);
    exportWorkerCount.value = config.exportWorkerCount;
    exportZipOutput.value = config.exportZipOutput;
    luminanceEnabled.value = config.luminanceEnabled;
    captureImageHostPath.value = config.captureImageHostPath ?? '';
    captureImageContainerPath.value = config.captureImageContainerPath ?? '';
    _qcJwtSecret = (config.qcJwtSecret?.trim().isNotEmpty ?? false)
        ? config.qcJwtSecret!.trim()
        : _newJwtSecret();
    _qcJwtExpireMinutes = config.qcJwtExpireMinutes;
    _exportCsvEncoding = config.exportCsvEncoding;
    _exportCsvLineEnding = config.exportCsvLineEnding;
    _exportTempRetentionHours = config.exportTempRetentionHours;
    uploadEnabled.value = config.uploadEnabled;
    uploadS3Path.value = config.uploadS3Path ?? '';
    uploadS3Region.value = config.uploadS3Region ?? '';
    uploadS3AccessKey.value = config.uploadS3AccessKey ?? '';
    uploadS3SecretKey.value = config.uploadS3SecretKey ?? '';
    uploadDoneRoot.value =
        config.uploadDoneRoot ?? p.join(root, captureUploadedFolder);
    uploadSummaryRoot.value =
        config.uploadSummaryRoot ??
        p.join(p.dirname(root), uploadReportsFolder);
    aiReviewEnabled.value = config.aiReviewEnabled;
    aiPreanalysisEnabled.value = config.aiPreanalysisEnabled;
    openrouterApiKey.value = config.openrouterApiKey ?? '';
    openrouterExtractModel.value = config.openrouterExtractModel ?? '';
    openrouterCompareModel.value = config.openrouterCompareModel ?? '';
    isLoaded.value = true;
    await _provisionFromSeedIfUnconfigured();
  }

  /// Turns the connection LW Suite setup left behind into a working station,
  /// the first time Admin opens.
  ///
  /// This is what makes the install a two-step job for the operator - run the
  /// installer, open Admin - instead of asking them to copy a 32-character
  /// password out of a dialog, invent a database name, and then find a .bat
  /// file in Program Files. Everything it does was already possible from this
  /// screen; the only thing missing was the password, and setup knows it.
  ///
  /// Deliberately conditional on there being no password saved yet. A station
  /// that has been configured, or pointed at a shared database somewhere else,
  /// must never be dragged back to a local one by a seed file that outlived its
  /// purpose.
  Future<void> _provisionFromSeedIfUnconfigured() async {
    if (_seedChecked) return;
    _seedChecked = true;
    final seed = readStationSeed();
    if (seed == null) return;

    // "A password is saved" is NOT the same as "this station works", and
    // treating them as equal cost a whole test cycle.
    //
    // What happened: PostgreSQL was reinstalled, so setup generated a new
    // password and seeded it, but an lwcam_node_config.json from the previous
    // install was still sitting in the user profile. Its password had been
    // valid once and was now meaningless. Provisioning saw a non-empty password,
    // declared the station configured, ignored the seed, and every connection
    // failed with an authentication error nobody could explain from the UI.
    //
    // So the test is whether the saved credentials actually authenticate. A
    // station deliberately pointed at a shared database elsewhere still wins -
    // its password works, so the seed is simply consumed and discarded. Only
    // credentials that no longer open a connection are replaced.
    if (pgPassword.value.isNotEmpty) {
      if (await _savedCredentialsWork()) {
        // Configured and working. The seed has nothing to add and should not be
        // left lying around with a superuser password in it.
        deleteStationSeed();
        return;
      }
      print(
        'Saved PostgreSQL credentials do not authenticate; '
        'adopting the connection left by setup.',
      );
    }

    pgHost.value = seed.host;
    pgPort.value = seed.port;
    pgDatabase.value = seed.database;
    pgUser.value = seed.user;
    pgPassword.value = seed.password;

    // First run is also the moment to decide whether this station processes
    // images, and it is the ONLY safe moment: past here a stored `false` is an
    // admin's decision, not an absence.
    //
    // Gated on the interpreter actually being present, the same way the QC
    // fields gate on isQcAppInstalled(). Registering an autostart for a runtime
    // that failed to build would replace a station that quietly does not
    // process with one that noisily cannot.
    //
    // The paths were already defaulted to 1.Images -> 2.Batches by
    // ensureLoaded(), so nothing else is needed to make this a working config.
    if (!processingEnabled.value && isLwipInstalled()) {
      processingEnabled.value = true;
      print('LWIP found: enabling image processing on this station.');
    }

    // And LWCAM's own sync, for the same reason and at the same moment.
    //
    // syncEnabled does not merely pause a drain: with it off, every outbox
    // write in upload_stats_db is a no-op (`if (!syncEnabled) return;`), so
    // captures are never even QUEUED for PostgreSQL. A station provisioned
    // without it captures and transfers perfectly, LWIP processes the images,
    // and QC shows an empty task list forever - which is exactly what happened.
    //
    // Safe to switch on here: provisioning only reaches this point after the
    // credentials have been proven against the server.
    if (!lwcamSyncEnabled.value) {
      lwcamSyncEnabled.value = true;
      print('Enabling LWCAM sync so captures reach PostgreSQL.');
    }

    isProvisioning.value = true;
    try {
      // Wait for the server to actually accept these credentials before doing
      // anything with them.
      //
      // EnterpriseDB's unattended installer starts the service and applies the
      // superuser password near the END of its run, so there is a window where
      // PostgreSQL is up, listening, and rejecting the very password setup just
      // generated. Admin is launched by the installer and lands squarely in it:
      // the first real clean install failed here, with a log full of
      // "password authentication failed" for a password that was correct barely
      // a minute later. Retrying is the difference between a station that sets
      // itself up and one that shows a wall of red text on first launch.
      if (!await _waitForCredentials(seed)) {
        throw StateError(
          'PostgreSQL did not accept the connection within '
          '${_provisionWaitLimit.inSeconds} seconds. It may still be starting '
          'up - press Save to try again.',
        );
      }
      // The ordinary save path: it writes the config, creates the pipeline
      // folders, applies the QC schema and registers the servers. Reusing it
      // means first run cannot drift from what a manual save does.
      await save();
      deleteStationSeed();
      // No success message on purpose. Provisioning working is the expected
      // case, the screen already shows the filled-in settings as proof, and a
      // banner explaining that nothing needs doing is itself something to read.
    } catch (e) {
      // The seed is deliberately NOT deleted here: whatever failed is worth
      // retrying on the next launch, and the password is the one thing that
      // cannot be recovered from anywhere else the operator can reach.
      firstRunStatus.value =
          'Automatic setup did not finish: $e\n\n'
          'The connection details are filled in above - press Save to try '
          'again.';
    } finally {
      isProvisioning.value = false;
    }
  }

  NodeConfig _buildFromForm() => NodeConfig(
    pgHost: pgHost.value.trim().isEmpty ? null : pgHost.value.trim(),
    pgPort: pgPort.value,
    pgDatabase: pgDatabase.value.trim().isEmpty
        ? null
        : pgDatabase.value.trim(),
    pgUser: pgUser.value.trim().isEmpty ? null : pgUser.value.trim(),
    pgPassword: pgPassword.value.isEmpty ? null : pgPassword.value,
    pgUseSsl: pgUseSsl.value,
    syncEnabled: lwcamSyncEnabled.value,
    syncIntervalSeconds: syncIntervalSeconds.value,
    usersStorePath: usersStorePath.value.trim().isEmpty
        ? null
        : usersStorePath.value.trim(),
    pgConnectionEnabled: pgConnectionEnabled.value,
    destinationPath: destinationPath.value.trim().isEmpty
        ? null
        : destinationPath.value.trim(),
    processingEnabled: processingEnabled.value,
    processingInputRoot: processingInputRoot.value.trim().isEmpty
        ? null
        : processingInputRoot.value.trim(),
    processingOutputRoot: processingOutputRoot.value.trim().isEmpty
        ? null
        : processingOutputRoot.value.trim(),
    processingWorkers: processingWorkers.value,
    processingCropPadding: processingCropPadding.value,
    processingCloudReport: processingCloudReport.value,
    qcInputRoot: qcInputRoot.value.trim().isEmpty
        ? null
        : qcInputRoot.value.trim(),
    exportWorkerCount: exportWorkerCount.value,
    exportZipOutput: exportZipOutput.value,
    luminanceEnabled: luminanceEnabled.value,
    // Blank means "no remap": paths.to_local is then an identity mapping, so an
    // empty box has to reach the file as null rather than "".
    captureImageHostPath: captureImageHostPath.value.trim().isEmpty
        ? null
        : captureImageHostPath.value.trim(),
    captureImageContainerPath: captureImageContainerPath.value.trim().isEmpty
        ? null
        : captureImageContainerPath.value.trim(),
    qcOutputRoot: qcOutputRoot.value.trim().isEmpty
        ? null
        : qcOutputRoot.value.trim(),
    qcJwtSecret: _qcJwtSecret,
    qcJwtExpireMinutes: _qcJwtExpireMinutes,
    exportCsvEncoding: _exportCsvEncoding,
    exportCsvLineEnding: _exportCsvLineEnding,
    exportTempRetentionHours: _exportTempRetentionHours,
    uploadEnabled: uploadEnabled.value,
    uploadS3Path: _orNull(uploadS3Path.value),
    uploadS3Region: _orNull(uploadS3Region.value),
    uploadS3AccessKey: _orNull(uploadS3AccessKey.value),
    // Not trimmed: a secret is whatever was pasted.
    uploadS3SecretKey: uploadS3SecretKey.value.isEmpty
        ? null
        : uploadS3SecretKey.value,
    uploadDoneRoot: _orNull(uploadDoneRoot.value),
    uploadSummaryRoot: _orNull(uploadSummaryRoot.value),
    aiReviewEnabled: aiReviewEnabled.value,
    aiPreanalysisEnabled: aiPreanalysisEnabled.value,
    // Empty means "not set": the QC backend then falls back to its own defaults
    // rather than being handed a blank model name.
    openrouterApiKey: _orNull(openrouterApiKey.value),
    openrouterExtractModel: _orNull(openrouterExtractModel.value),
    openrouterCompareModel: _orNull(openrouterCompareModel.value),
  );

  static String? _orNull(String value) =>
      value.trim().isEmpty ? null : value.trim();

  /// Why an upload-enabled config cannot work, or null when it can. Mirrors
  /// the engine's own rule (`s3://bucket[/prefix]`, both keys present).
  static String? uploadConfigProblem(NodeConfig config) {
    if (!config.uploadEnabled) return null;
    final path = config.uploadS3Path?.trim() ?? '';
    if (!path.toLowerCase().startsWith('s3://') || path.length <= 5) {
      return 'Upload needs an S3 path like s3://bucket/prefix, or turn it off.';
    }
    if ((config.uploadS3AccessKey ?? '').isEmpty ||
        (config.uploadS3SecretKey ?? '').isEmpty) {
      return 'Upload needs the S3 access key and secret key, or turn it off.';
    }
    final done = config.uploadDoneRoot?.trim() ?? '';
    if (done.isEmpty) return 'Upload needs an Uploaded folder to move into.';
    final out = config.qcOutputRoot?.trim() ?? '';
    if (out.isNotEmpty && _sameOrInside(done, out)) {
      // The engine lists everything in the output folder as a package, so an
      // Uploaded folder in there would be uploaded itself, forever.
      return 'The Uploaded folder must be outside the QC output folder.';
    }
    if ((config.uploadSummaryRoot?.trim() ?? '').isEmpty) {
      return 'Upload needs an Upload Summary folder for Upload_Summary.db3.';
    }
    return null;
  }

  static bool _sameOrInside(String candidate, String root) {
    String norm(String s) =>
        p.normalize(p.absolute(s)).toLowerCase().replaceAll('/', r'\');
    final a = norm(candidate);
    final b = norm(root);
    return a == b || a.startsWith(b.endsWith(r'\') ? b : '$b\\');
  }

  /// The processing input root actually in effect: the explicit field, else
  /// the destination path (the common same-PC case).
  String get _effectiveProcessingInput =>
      processingInputRoot.value.trim().isEmpty
      ? destinationPath.value.trim()
      : processingInputRoot.value.trim();

  /// Persists the form and immediately re-registers [AdminStoreService]
  /// against the new config (mirrors LWCAM's SyncBootstrap.apply).
  Future<void> save() async {
    if (processingEnabled.value) {
      // Same check the config writer runs, so validation and generation can never
      // disagree: it mirrors LWIP's own _validate_roots, failing here at the admin
      // instead of as a crash-looping python watcher on the capture PC.
      final problem = lwipConfigProblem(_buildFromForm());
      if (problem != null) throw StateError(problem);
    }
    if (aiReviewEnabled.value == true &&
        openrouterApiKey.value.trim().isEmpty) {
      throw StateError(
        'AI metadata review needs an OpenRouter API key, or turn it off.',
      );
    }
    if (uploadEnabled.value) {
      // Same check the engine runs (parse_s3_path / upload_runtime_config),
      // so a bad value fails here with the field named rather than as a
      // warning in a server log nobody reads.
      final problem = uploadConfigProblem(_buildFromForm());
      if (problem != null) throw StateError(problem);
    }
    if (qcInstalled.value) {
      final missing = <String>[
        if (pgHost.value.trim().isEmpty) 'PostgreSQL host',
        if (pgDatabase.value.trim().isEmpty) 'PostgreSQL database',
        if (pgUser.value.trim().isEmpty) 'PostgreSQL user',
        if (pgPassword.value.isEmpty) 'PostgreSQL password',
        if (qcInputRoot.value.trim().isEmpty) 'QC input/work folder',
        if (qcOutputRoot.value.trim().isEmpty) 'QC output folder',
      ];
      if (missing.isNotEmpty) {
        throw StateError('Complete the QC settings: ${missing.join(', ')}.');
      }
      qcDriveWarning.value =
          qcSplitDriveWarning(
            qcInputRoot.value.trim(),
            qcOutputRoot.value.trim(),
          ) ??
          '';
    }
    final config = _buildFromForm();
    await _ensureFolders(config);
    await _service.save(config);
    // LWIP now starts as a background service, before any app has run, so its
    // config must already be on disk. Station Setup owns every path in it, so it
    // writes it. LWCAM used to generate this immediately before spawning python,
    // which only worked while LWCAM was the thing that started LWIP.
    await writeLwipConfig(config);
    // LWIP runs on its own now, not as a child of LWCAM, so enabling processing
    // means registering it to start at logon AND starting it immediately — an
    // operator who just switched it on should not have to reboot.
    lwipAutostartWarning.value = '';
    // Stop first, ALWAYS. LWIP reads its config once at import, so a live
    // instance keeps the previous settings until it is replaced - exactly as
    // the QC engine did before 2026-09-04. Unconditional because turning
    // processing OFF has to stop it too, not just unregister the autostart.
    final stopped = await stopLwipNow();
    if (config.processingEnabled) {
      lwipAutostartWarning.value = await enableLwipAutostart() ?? '';
      if (lwipAutostartWarning.value.isEmpty) {
        // Started even when the old one has not gone yet: since 2026-09-10 a
        // starting LWIP waits on the instance lock (up to 15 min) instead of
        // exiting on it, and reads its config again once it holds the lock.
        // The old one finishes the folder it is publishing, exits, and this
        // one takes over. Before that, a timed-out stop here left image
        // processing dead until the next logon.
        await startLwipNow();
        if (!stopped) {
          lwipAutostartWarning.value =
              'Image processing is still finishing a folder. The new settings '
              'take effect automatically when it does.';
        }
      }
    } else {
      await disableLwipAutostart();
    }
    if (qcInstalled.value) await _prepareQcDatabase();
    // The QC backend is a server, not a child of any app: registering it at
    // logon means QC review never depends on someone having run
    // START_QC_BACKEND.bat first. Mirrors the LWIP block above, including
    // starting it immediately so enabling QC does not wait for a reboot.
    qcBackendAutostartWarning.value = '';
    if (qcInstalled.value) {
      qcBackendAutostartWarning.value = await enableQcBackendAutostart() ?? '';
      if (qcBackendAutostartWarning.value.isEmpty) await startQcBackendNow();
    } else {
      await disableQcBackendAutostart();
    }
    await AdminBootstrap.apply(config);
  }

  /// Creates the configured folders, so an operator never has to make them by
  /// hand and LWCAM/LWIP/QC never fail on a missing path. Runs BEFORE the
  /// config is written: a path that cannot be created is not worth saving, and
  /// the admin sees which one it was instead of a capture failing later.
  Future<void> _ensureFolders(NodeConfig config) async {
    final wanted = <String>{
      if (config.destinationPath != null) config.destinationPath!,
      if (config.processingEnabled) _effectiveProcessingInput,
      if (config.processingEnabled)
        config.processingOutputRoot ?? '${_effectiveProcessingInput}_processed',
      if (qcInstalled.value && config.qcInputRoot != null) config.qcInputRoot!,
      if (qcInstalled.value && config.qcOutputRoot != null)
        config.qcOutputRoot!,
      if (qcInstalled.value &&
          config.uploadEnabled &&
          config.uploadDoneRoot != null)
        config.uploadDoneRoot!,
      if (qcInstalled.value &&
          config.uploadEnabled &&
          config.uploadSummaryRoot != null)
        config.uploadSummaryRoot!,
    }..removeWhere((path) => path.trim().isEmpty);
    for (final path in wanted) {
      try {
        await Directory(path).create(recursive: true);
      } catch (e) {
        throw StateError(
          'Could not create the folder $path: $e\n'
          'Pick a folder this account can write to, or create it and grant '
          'access first.',
        );
      }
    }
  }

  Future<void> _prepareQcDatabase() async {
    // Null in a source tree, which has no launcher to run. Saving Station Setup
    // there used to shell out to a .bat that was never written, so every save
    // failed with cmd's "cannot find the path" rather than doing nothing.
    // Applying the schema from source is the developer's job (the repository
    // has scripts\setup_qc_db.py for it); a deployed station is what this step
    // exists to provision.
    final script = qcSetupDbScript();
    if (script == null) return;
    final root = p.dirname(script);
    final result = await Process.run(
      Platform.environment['ComSpec'] ?? 'cmd.exe',
      ['/D', '/C', script],
      workingDirectory: root,
    );
    if (result.exitCode != 0) {
      final detail = '${result.stderr}\n${result.stdout}'.trim();
      throw StateError(
        detail.isEmpty
            ? 'QC database setup failed (exit ${result.exitCode}).'
            : 'QC database setup failed: $detail',
      );
    }
  }

  /// Whether the credentials already in the config can still open a connection.
  ///
  /// Checked against the `postgres` maintenance database, not the configured
  /// one: the target database legitimately may not exist yet, and that is not a
  /// credential problem. One attempt only - this runs on the way into the
  /// screen, and a station that is merely offline must not be mistaken for one
  /// with bad credentials, which is why only [PgFailure.badPassword] counts as
  /// failure here.
  Future<bool> _savedCredentialsWork() async {
    try {
      final conn = await openPgConnection(
        host: pgHost.value.trim(),
        port: pgPort.value,
        database: 'postgres',
        user: pgUser.value.trim(),
        password: pgPassword.value,
        useSsl: pgUseSsl.value,
      );
      await conn.close();
      return true;
    } on SyncConnectException catch (e) {
      return e.failure != PgFailure.badPassword;
    } catch (_) {
      return true; // unreachable for some other reason - not a credential fault
    }
  }

  /// How long first-run provisioning waits for a just-installed PostgreSQL.
  ///
  /// Generous on purpose: the cost of waiting is a progress line, while the cost
  /// of giving up early is an operator staring at an authentication error on a
  /// brand-new machine. Observed window on a clean install was well under a
  /// minute; this allows for a slower disk.
  static const Duration _provisionWaitLimit = Duration(minutes: 3);

  /// Polls until [seed]'s credentials authenticate, or the limit runs out.
  ///
  /// Connects to the `postgres` maintenance database, NOT the one being
  /// provisioned: that one does not exist yet, and a "database does not exist"
  /// reply is itself proof the credentials were accepted.
  Future<bool> _waitForCredentials(StationSeed seed) async {
    final deadline = DateTime.now().add(_provisionWaitLimit);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final conn = await openPgConnection(
          host: seed.host,
          port: seed.port,
          database: 'postgres',
          user: seed.user,
          password: seed.password,
          useSsl: false,
        );
        await conn.close();
        return true;
      } on SyncConnectException catch (e) {
        // Authenticated, just pointed at a database that is not there yet.
        if (e.failure == PgFailure.missingDatabase) return true;
      } catch (_) {
        // Fall through and retry: still starting, or still applying the password.
      }
      await Future<void>.delayed(const Duration(seconds: 3));
    }
    return false;
  }

  /// Asks the server what is actually wrong, for a message worth reading.
  ///
  /// Opens a raw connection rather than reusing the gateway, because the gateway
  /// deliberately reports only reachable/outdated/unreachable - it exists to
  /// decide whether to sync, not to explain a failure to a person.
  Future<PgFailure> _diagnose() async {
    try {
      final conn = await openPgConnection(
        host: pgHost.value.trim(),
        port: pgPort.value,
        database: pgDatabase.value.trim(),
        user: pgUser.value.trim(),
        password: pgPassword.value,
        useSsl: pgUseSsl.value,
      );
      await conn.close();
      return PgFailure.unreachable; // connected on retry; nothing to explain
    } on SyncConnectException catch (e) {
      return e.failure;
    } catch (_) {
      return PgFailure.unreachable;
    }
  }

  /// Rotates the PostgreSQL password: changes it on the SERVER, then saves it
  /// here. Both halves or neither.
  ///
  /// This exists because the Password box alone is only the credential this app
  /// connects *with* - editing and saving it does not touch the server, so a new
  /// value there simply breaks the connection. An operator who has just been
  /// handed a generated password by the installer and wants their own needs the
  /// server changed too, and doing that by hand means finding psql.
  ///
  /// Order matters and is not symmetrical. The server changes first, because a
  /// config saved ahead of a failed ALTER ROLE would leave this station holding
  /// a password the server never accepted. Once the server HAS changed, the
  /// config write is no longer optional - it is the only remaining record of the
  /// new password - so its failure is reported with the password in the message
  /// rather than swallowed.
  Future<void> rotatePgPassword(String newPassword) async {
    // No trim: a space can legitimately be part of a password, and silently
    // saving something different from what the server was given would lock this
    // station out.
    if (newPassword.isEmpty) throw StateError('Enter a new password.');
    if (newPassword == pgPassword.value) {
      throw StateError('That is already the current password.');
    }
    final host = pgHost.value.trim();
    final user = pgUser.value.trim();
    if (host.isEmpty) throw StateError('Enter a PostgreSQL host first.');
    if (user.isEmpty) throw StateError('Enter a PostgreSQL user first.');
    if (pgPassword.value.isEmpty) {
      throw StateError(
        'Enter the current password first - it is needed to authenticate the '
        'change.',
      );
    }

    final gateway = AdminPgGateway(
      host: host,
      port: pgPort.value,
      database: pgDatabase.value.trim(),
      user: user,
      password: pgPassword.value,
      useSsl: pgUseSsl.value,
    );
    try {
      // Probe first so a wrong current password reads as "could not connect"
      // rather than surfacing as a failed ALTER ROLE. schemaOutdated is fine:
      // changing a password does not need the schema to be current.
      if ((await gateway.probe()).status == GatewayStatus.unreachable) {
        throw const SyncConnectException(
          'could not connect with the current password',
        );
      }
      await gateway.rotatePassword(newPassword);
    } finally {
      await gateway.close();
    }

    pgPassword.value = newPassword;
    // Deliberately NOT the full save(): folders, the LWIP config and autostart
    // do not carry this credential, and running the QC database setup as a
    // side effect of a password change would surprise the operator. The config
    // file and the live gateway are the two things that must not miss it.
    try {
      final config = _buildFromForm();
      await _service.save(config);
      await AdminBootstrap.apply(config);
    } catch (e) {
      throw StateError(
        'The server password was changed to "$newPassword", but saving it here '
        'failed: $e. Write that password down and enter it in Station Setup, or '
        'this station cannot reach its database.',
      );
    }
  }

  /// One-off reachability test against whatever is currently typed in —
  /// does not require saving first.
  Future<void> testConnection() async {
    final host = pgHost.value.trim();
    if (host.isEmpty) throw StateError('Enter a PostgreSQL host first.');
    final gateway = AdminPgGateway(
      host: host,
      port: pgPort.value,
      database: pgDatabase.value.trim(),
      user: pgUser.value.trim(),
      password: pgPassword.value,
      useSsl: pgUseSsl.value,
    );
    try {
      final result = await gateway.probe();
      switch (result.status) {
        case GatewayStatus.reachable:
          return;
        case GatewayStatus.schemaOutdated:
          return; // Save runs the idempotent schema preparation automatically.
        case GatewayStatus.unreachable:
          // probe() flattens every failure into one status, so ask the server
          // directly for a sentence worth showing: "could not reach the host"
          // sent operators hunting firewalls when the database simply did not
          // exist yet.
          throw SyncConnectException(describePgFailure(await _diagnose()));
      }
    } finally {
      await gateway.close();
    }
  }
}
