import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../models/node_config.dart';
import '../services/admin_bootstrap.dart';
import '../services/admin_pg_gateway.dart';
import '../services/lwip_autostart_service.dart';
import '../services/lwip_config_writer.dart';
import '../services/station_seed.dart';
import '../services/node_config_service.dart';
import '../services/pg_client.dart';

/// Searches for the database setup script and its SQL directory.
/// Returns (script path, database dir path) or null if not found.
/// Searches source/install layouts beside the executable, then `%ProgramFiles%`.
(String, String)? dbSetupScript({
  String? executablePath,
  Map<String, String>? environment,
}) {
  var dir = p.dirname(executablePath ?? Platform.resolvedExecutable);
  for (var level = 0; level < 8; level++) {
    // Installed layout: <root>\Database\setup_qc_db.py and database\.
    final installedScript = p.join(dir, 'Database', 'setup_qc_db.py');
    final installedDbDir = p.join(dir, 'Database', 'database');
    if (File(installedScript).existsSync() &&
        Directory(installedDbDir).existsSync()) {
      return (installedScript, installedDbDir);
    }
    // Source layout: <root>\LWCam_QC_Platform\scripts\setup_qc_db.py and database\.
    final sourceScript =
        p.join(dir, 'LWCam_QC_Platform', 'scripts', 'setup_qc_db.py');
    final sourceDbDir = p.join(dir, 'LWCam_QC_Platform', 'database');
    if (File(sourceScript).existsSync() && Directory(sourceDbDir).existsSync()) {
      return (sourceScript, sourceDbDir);
    }
    final parent = p.dirname(dir);
    if (parent == dir) break;
    dir = parent;
  }
  // %ProgramFiles% fallbacks: LWCam and the legacy LW Suite layout.
  final programFiles =
      (environment ?? Platform.environment)['ProgramFiles'] ??
      r'C:\Program Files';
  for (final installDir in [
    p.join(programFiles, 'LWCam'),
    p.join(programFiles, 'LW Suite'),
  ]) {
    final script = p.join(installDir, 'Database', 'setup_qc_db.py');
    final dbDir = p.join(installDir, 'Database', 'database');
    if (File(script).existsSync() && Directory(dbDir).existsSync()) {
      return (script, dbDir);
    }
  }
  return null;
}

/// Upgraded LW Suite installs keep `<install>\LWCam Capture`; new LWCam installs
/// use `<install>\LWCAM`, with `%ProgramFiles%\LWCam\LWCAM` as the fallback.
/// Source/portable builds can override the default through the saved field.
///
/// The installer creates these folders with users-modify rights because LWCAM
/// and LWIP write to them as a normal user, while Program Files is admin-only.
String defaultCaptureRoot({
  String? executablePath,
  Map<String, String>? environment,
}) {
  final exeDir = p.dirname(executablePath ?? Platform.resolvedExecutable);
  if (p.basename(exeDir) == 'LWCamAdmin') {
    final installDir = p.dirname(exeDir);
    return p.join(
      installDir,
      p.basename(installDir).toLowerCase() == 'lwcam'
          ? 'LWCAM'
          : 'LWCam Capture',
    );
  }
  return p.join(
    (environment ?? Platform.environment)['ProgramFiles'] ??
        r'C:\Program Files',
    'LWCam',
    'LWCAM',
  );
}

/// Stage folders of the capture pipeline: LWCAM lands images in 1, LWIP writes
/// batches to 2, and the exporter publishes packages to 3. The exporter also
/// uses 2 as its default local scratch folder.
const String captureImagesFolder = '1.Images';
const String captureBatchesFolder = '2.Batches';
const String captureExportFolder = '3.Export';
/// PostgreSQL connection defaults, kept in sync with the platform defaults
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
  late NodeConfig _loadedConfig;

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

  /// What first-run provisioning did, for the page to show once. Empty when
  /// there was nothing to do - which is every launch after the first.
  final firstRunStatus = ''.obs;

  /// Set while provisioning runs, so the page can say so instead of looking
  /// frozen: creating the database and loading the schema takes a few seconds.
  final isProvisioning = false.obs;

  /// Guard: provisioning is a one-shot, and the page calls ensureLoaded(force:
  /// true) every time it is opened.
  bool _seedChecked = false;

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
    _loadedConfig = config;
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
    isLoaded.value = true;
    await _provisionFromSeedIfUnconfigured();
  }

  /// Turns the connection Setup left behind into a working station,
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
    // Gated on the interpreter actually being present. Registering an autostart
    // for a runtime that failed to build would replace a station that quietly
    // does not process with one that noisily cannot.
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
    // without it captures and transfers perfectly and LWIP processes the images,
    // but downstream review sees an empty task list forever.
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
      // folders, writes the LWIP config, sets up the database when credentials
      // are complete, and registers the app services. Reusing it
      // means first run cannot drift from what a manual save does.
      await save();
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

  // Omitted QC, upload, AI, and other unedited fields keep their loaded values.
  NodeConfig _buildFromForm() => _loadedConfig.copyWith(
    pgHost: pgHost.value.trim(),
    pgPort: pgPort.value,
    pgDatabase: pgDatabase.value.trim(),
    pgUser: pgUser.value.trim(),
    pgPassword: pgPassword.value,
    pgUseSsl: pgUseSsl.value,
    syncEnabled: lwcamSyncEnabled.value,
    syncIntervalSeconds: syncIntervalSeconds.value,
    usersStorePath: usersStorePath.value.trim().isEmpty
        ? defaultLwcamDbsDir()
        : usersStorePath.value.trim(),
    pgConnectionEnabled: pgConnectionEnabled.value,
    destinationPath: destinationPath.value.trim(),
    processingEnabled: processingEnabled.value,
    processingInputRoot: processingInputRoot.value.trim(),
    processingOutputRoot: processingOutputRoot.value.trim(),
    processingWorkers: processingWorkers.value,
    processingCropPadding: processingCropPadding.value,
    processingCloudReport: processingCloudReport.value,
  );

  /// The processing input root actually in effect: the explicit field, else
  /// the destination path (the common same-PC case).
  String get _effectiveProcessingInput =>
      processingInputRoot.value.trim().isEmpty
      ? destinationPath.value.trim()
      : processingInputRoot.value.trim();

  /// Persists the form and immediately re-registers [AdminStoreService]
  /// against the new config (mirrors LWCAM's SyncBootstrap.apply).
  Future<bool> save() async {
    if (processingEnabled.value) {
      // Same check the config writer runs, so validation and generation can never
      // disagree: it mirrors LWIP's own _validate_roots, failing here at the admin
      // instead of as a crash-looping python watcher on the capture PC.
      final problem = lwipConfigProblem(_buildFromForm());
      if (problem != null) throw StateError(problem);
    }
    final config = _buildFromForm();
    await _ensureFolders(config);
    await _service.save(config);
    _loadedConfig = config;
    // LWIP now starts as a background service, before any app has run, so its
    // config must already be on disk. Station Setup owns every path in it, so it
    // writes it. LWCAM used to generate this immediately before spawning python,
    // which only worked while LWCAM was the thing that started LWIP.
    await writeLwipConfig(config);
    final databaseSetupRan = await _prepareDatabase(config);
    if (!databaseSetupRan) {
      firstRunStatus.value =
          'Database provisioning was skipped. '
          'Populate the PostgreSQL connection in Station Setup and save again.';
    } else {
      // The seed is no longer needed after successful database setup.
      deleteStationSeed();
      firstRunStatus.value = '';
    }
    // LWIP runs on its own now, not as a child of LWCAM, so enabling processing
    // means registering it to start at logon AND starting it immediately — an
    // operator who just switched it on should not have to reboot.
    lwipAutostartWarning.value = '';
    // Stop first, ALWAYS. LWIP reads its config once at import, so a live
    // instance keeps the previous settings until it is replaced. This is also
    // needed when processing is turned off, not just to apply new settings.
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
    await AdminBootstrap.apply(config);
    return databaseSetupRan;
  }

  /// Creates the configured folders, so an operator never has to make them by
  /// hand and LWCAM/LWIP never fail on a missing path. Runs BEFORE the
  /// config is written: a path that cannot be created is not worth saving, and
  /// the admin sees which one it was instead of a capture failing later.
  Future<void> _ensureFolders(NodeConfig config) async {
    final wanted = <String>{
      if (config.destinationPath != null) config.destinationPath!,
      if (config.processingEnabled) _effectiveProcessingInput,
      if (config.processingEnabled)
        config.processingOutputRoot ?? '${_effectiveProcessingInput}_processed',
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

  Future<bool> _prepareDatabase(NodeConfig config) async {
    if (!_hasCompletePgConnection(config)) return false;

    final setup = dbSetupScript();
    if (setup == null) {
      throw StateError(
        'PostgreSQL connection configured but database setup script not found. '
        'Cannot provision database.',
      );
    }
    final (scriptPath, dbDirPath) = setup;
    final sourceLayout =
        p.basename(p.dirname(p.dirname(scriptPath))) == 'LWCam_QC_Platform';
    final lwipRoot = resolveLwipRoot();
    if (lwipRoot == null) {
      if (sourceLayout) {
        debugPrint('Skipping DB setup in source tree without LWIP runtime');
        return false;
      }
      throw StateError(
        'Found database setup script but LWIP runtime not found. '
        'Cannot provision database.',
      );
    }

    final pythonExePath = p.join(lwipRoot, 'runtime', 'python', 'python.exe');
    if (!File(pythonExePath).existsSync()) {
      throw StateError(
        'LWIP Python interpreter was not found at $pythonExePath. '
        'Cannot provision database.',
      );
    }
    final result = await Process.run(pythonExePath, [
      scriptPath,
      '--config',
      _service.getConfigPath(),
      '--database-dir',
      dbDirPath,
    ]);
    if (result.exitCode != 0) {
      throw StateError(
        'Database setup failed (exit ${result.exitCode}).\n'
        'stdout: ${result.stdout}\n'
        'stderr: ${result.stderr}',
      );
    }
    return true;
  }

  bool _hasCompletePgConnection(NodeConfig config) =>
      (config.pgHost?.trim().isNotEmpty ?? false) &&
      (config.pgDatabase?.trim().isNotEmpty ?? false) &&
      (config.pgUser?.trim().isNotEmpty ?? false) &&
      (config.pgPassword?.trim().isNotEmpty ?? false);

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
    // do not carry this credential, and provisioning as a side effect of a
    // password change would surprise the operator. The config
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
          return; // Provisioning runs on save when database connection is filled.
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
