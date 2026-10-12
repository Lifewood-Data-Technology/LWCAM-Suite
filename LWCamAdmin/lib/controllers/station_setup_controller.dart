// Logic behind LWCam Admin's Station Setup page (LWCam Admin manages users,
// projects and devices for the LWCAM suite; this controller sets up THIS PC).
// It edits lwcam_node_config.json: the PostgreSQL connection, the image
// destination folder and the capture sync switch. The same file is read by the
// capture app (LWCAM), so a fresh capture PC is provisioned from here.
// Things to know before editing: always re-read the file from disk before
// saving (LWCAM may have changed it), the database password is stored
// encrypted (DPAPI) and is kept as-is when it cannot be decrypted, and the
// database itself is created by LWCamDatabaseSetup, never from this app.

import 'dart:async';
import 'dart:io';

import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:postgres/postgres.dart' show Connection;

import '../models/node_config.dart';
import '../services/admin_bootstrap.dart';
import '../services/admin_login.dart';
import '../services/dpapi.dart';
import '../services/admin_pg_gateway.dart';
import '../services/folder_access.dart';
import '../services/node_config_service.dart';
import '../services/pg_client.dart';

/// Upgraded LW Suite installs keep `<install>\LWCam Capture`; new LWCam installs
/// use `<install>\LWCAM`, with `%ProgramFiles%\LWCam\LWCAM` as the fallback.
/// Source/portable builds can override the default through the saved field.
///
/// Only a fallback: Program Files is not writable by a normal user, and on a
/// multi-PC site the images usually belong on a share, so set the field
/// (Test folder access checks it).
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
/// ONE database login for every part (LWCamDatabaseSetup's user, default
/// `lwcam_user`): LWCAM and LWCam Admin both use it. Old files may still carry
/// a separate `adminPgUser`; [adminLoginFor] reads it, this form never writes it.
const String defaultPgUser = 'lwcam_user';

/// Why [host] cannot be a bare host name/IP, or null when it looks fine. The
/// usual slip on a multi-PC site is pasting `host:5432` or a URL.
String? pgHostProblem(String host) {
  final h = host.trim();
  if (h.contains('://') || h.contains('/') || h.contains(' ')) {
    return 'Enter only the host name or IP of the database PC, without '
        'postgres:// or a path.';
  }
  final colons = ':'.allMatches(h).length;
  if (colons == 1) {
    return 'Enter the port in the Port box, not after the host name.';
  }
  return null;
}

/// Signature of [openPgConnection]; injectable so tests need no server.
typedef PgOpener = Future<Connection> Function({
  required String host,
  required int port,
  required String database,
  required String user,
  required String password,
  required bool useSsl,
});

/// This machine's PostgreSQL connection + local snapshot path
/// (`lwcam_node_config.json`) — the file LWCAM's SyncBootstrap also reads,
/// so Station Setup here is how a fresh capture PC gets provisioned.
class StationSetupController extends GetxController {
  StationSetupController({PgOpener openConnection = openPgConnection})
    : _open = openConnection;

  final PgOpener _open;

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
  final lwcamSyncEnabled = true.obs;

  /// The image destination root LWCAM's transfers land in. Empty = not
  /// configured; LWCAM refuses to start a transfer until it is set.
  final destinationPath = ''.obs;

  /// What first-run provisioning did, for the page to show once. Empty when
  /// there was nothing to do - which is every launch after the first.
  final firstRunStatus = ''.obs;

  /// True when a saved DPAPI password could not be decrypted on this Windows
  /// account. The form then shows a visible error, and Save keeps the stored
  /// blob unless a NEW password is typed - it must not overwrite it with ''.
  final capturePasswordUnreadable = false.obs;

  NodeConfigService get _service => Get.find<NodeConfigService>();

  // --- Load and save the station config ------------------------------------

  /// Reads the saved config into the form fields (once, or again with [force]).
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
    capturePasswordUnreadable.value = false;
    try {
      pgPassword.value = capturePasswordOf(config);
    } catch (_) {
      pgPassword.value = ''; // other Windows user/PC: re-enter it
      capturePasswordUnreadable.value = true;
    }
    pgUseSsl.value = config.pgUseSsl;
    syncIntervalSeconds.value = config.syncIntervalSeconds;
    usersStorePath.value = config.usersStorePath ?? '';
    pgConnectionEnabled.value = config.pgConnectionEnabled;
    lwcamSyncEnabled.value = config.syncEnabled;
    // Unset folders start on the suite's own pipeline layout rather than
    // blank, so a fresh station is one Save away from working. An admin can
    // still point any of them anywhere (a NAS, another drive, a UNC share);
    // a value already in the file always wins.
    destinationPath.value =
        config.destinationPath ?? p.join(defaultCaptureRoot(), captureImagesFolder);
    isLoaded.value = true;
  }

  // Applied to [base] - the config freshly re-read from disk - so QC, upload,
  // AI and other unedited fields, and every key this build does not know
  // (extras), keep whatever is on disk NOW, not what was there when the page
  // opened.
  NodeConfig _applyForm(NodeConfig base) {
    // A password that could not be decrypted and was not retyped keeps its
    // stored blob: saving '' over it would destroy a secret that another
    // Windows account (or a restored profile) can still read.
    final keepCapture = pgPassword.value.isEmpty &&
        capturePasswordUnreadable.value;
    return base.copyWith(
      pgHost: pgHost.value.trim(),
      pgPort: pgPort.value,
      pgDatabase: pgDatabase.value.trim(),
      pgUser: pgUser.value.trim(),
      // Capture password: DPAPI (entropy "LWCam"), plain field blanked.
      pgPasswordProtected: keepCapture
          ? base.pgPasswordProtected
          : pgPassword.value.isEmpty
              ? ''
              : dpapiProtect(pgPassword.value, entropy: captureDpapiEntropy),
      pgPassword: keepCapture ? base.pgPassword : '',
      // One shared login since 2026-09-30: an older station's separate
      // LWCam Admin login would otherwise keep winning in adminLoginFor, so a
      // Station Setup save retires it and Admin uses the login saved here.
      adminPgUser: '',
      adminPgPasswordProtected: '',
      pgUseSsl: pgUseSsl.value,
      syncEnabled: lwcamSyncEnabled.value,
      syncIntervalSeconds: syncIntervalSeconds.value,
      usersStorePath: usersStorePath.value.trim().isEmpty
          ? defaultLwcamDbsDir()
          : usersStorePath.value.trim(),
      pgConnectionEnabled: pgConnectionEnabled.value,
      destinationPath: destinationPath.value.trim(),
    );
  }

  /// Persists the form and immediately re-registers [AdminStoreService]
  /// against the new config (mirrors LWCAM's SyncBootstrap.apply).
  Future<bool> save() async {
    final preview = _applyForm(await _service.reload());
    await _ensureFolders(preview);
    // Reload again inside update(): the folder check above can take a while
    // (a share that is down), and LWCAM may have rewritten the file meanwhile.
    final config = await _service.update(_applyForm);
    // Saved: whatever was typed is now the stored value.
    if (pgPassword.value.isNotEmpty) capturePasswordUnreadable.value = false;
    // Database creation/upgrade is LWCamDatabaseSetup's job now, on the
    // database PC — this app only connects. A complete connection that still
    // does not answer is worth telling the admin about; an empty one is just
    // a station not pointed anywhere yet, which the blank fields already show.
    final complete = _hasCompletePgConnection(config);
    final status = complete ? await _testDatabaseConnection(config) : null;
    final databaseReady = status == GatewayStatus.reachable;
    if (status == GatewayStatus.unreachable) {
      firstRunStatus.value =
          'Database not reachable — install LWCamDatabaseSetup on the '
          'database PC first.';
    } else if (status == GatewayStatus.schemaOutdated) {
      firstRunStatus.value =
          'The database answers but its tables are out of date — run the '
          'newest LWCamDatabaseSetup on the database PC.';
    } else if (databaseReady) {
      firstRunStatus.value = '';
    }
    await AdminBootstrap.apply(config);
    return databaseReady;
  }

  /// Creates the image destination folder, so LWCAM never fails on a missing
  /// path. Runs BEFORE the config is written: a path that cannot be created is
  /// not worth saving, and the admin sees which one it was instead of a
  /// capture failing later.
  Future<void> _ensureFolders(NodeConfig config) async {
    final path = config.destinationPath?.trim();
    if (path == null || path.isEmpty) return;
    try {
      // A UNC path can hang on a dead PC: bound it.
      await Directory(path).create(recursive: true).timeout(
        const Duration(seconds: 20),
      );
    } catch (e) {
      throw StateError(
        'Could not create the folder $path: $e\n'
        'Pick a folder this account can write to, or create it and grant '
        'access first.',
      );
    }
  }

  /// One-shot reachability test against [config]'s own connection — the
  /// database-provisioning replacement now that provisioning itself lives in
  /// LWCamDatabaseSetup. Reuses the same gateway [testConnection] does.
  Future<GatewayStatus> _testDatabaseConnection(NodeConfig config) async {
    final login = adminLoginFor(config);
    final gateway = AdminPgGateway(
      host: config.pgHost!.trim(),
      port: config.pgPort,
      database: config.pgDatabase!.trim(),
      user: login.user.trim(),
      password: login.password,
      useSsl: config.pgUseSsl,
    );
    try {
      return (await gateway.probe()).status;
    } finally {
      await gateway.close();
    }
  }

  bool _hasCompletePgConnection(NodeConfig config) =>
      (config.pgHost?.trim().isNotEmpty ?? false) &&
      (config.pgDatabase?.trim().isNotEmpty ?? false) &&
      (config.pgUser?.trim().isNotEmpty ?? false) &&
      pgPassword.value.trim().isNotEmpty;

  // --- Password rotation and connection / folder tests ---------------------

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
  ///
  /// It rotates THE database login (a member of lwcam_app may ALTER ROLE
  /// itself). Every other part keeps the old password until it is re-entered
  /// there, so the dialog says so.
  String get rotateTargetUser => pgUser.value.trim();

  Future<void> rotatePgPassword(String newPassword) async {
    // No trim: a space can legitimately be part of a password, and silently
    // saving something different from what the server was given would lock this
    // station out.
    if (newPassword.isEmpty) throw StateError('Enter a new password.');
    final current = pgPassword.value;
    if (newPassword == current) {
      throw StateError('That is already the current password.');
    }
    final host = pgHost.value.trim();
    final user = rotateTargetUser;
    if (host.isEmpty) throw StateError('Enter a PostgreSQL host first.');
    if (user.isEmpty) throw StateError('Enter a PostgreSQL user first.');
    if (current.isEmpty) {
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
      password: current,
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
    capturePasswordUnreadable.value = false;
    // Deliberately NOT the full save(): the folder check and the reachability
    // test do not carry this credential, and running them as a side effect of
    // a password change would surprise the operator. The config file and the
    // live gateway are the two things that must not miss it.
    try {
      final config = await _service.update(_applyForm);
      await AdminBootstrap.apply(config);
    } catch (e) {
      throw StateError(
        'The server password was changed to "$newPassword", but saving it here '
        'failed: $e. Write that password down and enter it in Station Setup, or '
        'this station cannot reach its database.',
      );
    }
  }

  /// One-off test of the database login against whatever is currently typed in
  /// (no save needed), against the configured database - LAN access only
  /// admits the app login to it, never to `postgres`.
  ///
  /// Works against a remote database PC by name, IP or Tailscale name: TLS is
  /// required for every non-local host ([pgSslMode]) and every attempt is
  /// time-limited, so a database PC that is off fails in seconds instead of
  /// hanging the form. Connects directly rather than through the gateway: the
  /// gateway flattens every failure into "unreachable", and "could not reach
  /// the host" sent operators hunting firewalls when the password, the
  /// pg_hba rule or TLS was the problem. Errors name the login and the
  /// host:port that was tried.
  Future<void> testConnection() async {
    final host = pgHost.value.trim();
    if (host.isEmpty) throw StateError('Enter a PostgreSQL host first.');
    final hostProblem = pgHostProblem(host);
    if (hostProblem != null) throw StateError(hostProblem);
    final logins = <(String, String, String)>[
      ('Database login', pgUser.value.trim(), pgPassword.value),
    ];
    for (final (label, user, password) in logins) {
      try {
        final conn = await _open(
          host: host,
          port: pgPort.value,
          database: pgDatabase.value.trim(),
          user: user,
          password: password,
          useSsl: pgUseSsl.value,
        );
        await conn.close();
      } on SyncConnectException catch (e) {
        throw SyncConnectException(
          '$label ($host:${pgPort.value}): ${describePgFailure(e.failure)}',
          failure: e.failure,
        );
      } on TimeoutException {
        throw SyncConnectException(
          '$label ($host:${pgPort.value}): '
          '${describePgFailure(PgFailure.timeout)}',
          failure: PgFailure.timeout,
        );
      }
    }
  }

  /// Checks, as typed (no save needed), the one folder LWCAM on this PC uses:
  /// capture writes the destination, and a rework recapture overwrites its
  /// original there too (LWCAM's `ReworkService.inputFileFor`).
  Future<List<FolderAccessResult>> testFolderAccess() async {
    final destination = destinationPath.value.trim();
    if (destination.isEmpty) {
      throw StateError('Enter an image destination folder first.');
    }
    return [
      FolderAccessResult(
        'Image destination folder',
        destination,
        await checkFolderAccess(destination, FolderNeed.write),
      ),
    ];
  }
}

class FolderAccessResult {
  const FolderAccessResult(this.label, this.path, this.error);

  final String label;
  final String path;

  /// Null when the folder works.
  final String? error;
}
