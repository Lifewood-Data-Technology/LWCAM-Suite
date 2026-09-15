// ignore_for_file: avoid_print

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lwcam/controllers/box_session_controller.dart';
import 'package:lwcam/controllers/projects_controller.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/models/app_user.dart';
import 'package:lwcam/models/project.dart';
import 'package:lwcam/pages/change_password_dialog.dart';
import 'package:lwcam/pages/qc_home_page.dart';
import 'package:lwcam/services/qc_api_client.dart';
import 'package:lwcam/pages/settings_page.dart' show SettingsController;
import 'package:lwcam/services/audit_log_service.dart';
import 'package:lwcam/services/device_registry.dart';
import 'package:lwcam/services/node_config_service.dart';
import 'package:lwcam/services/scrcpy_service.dart';
import 'package:lwcam/services/snackbar_service.dart';
import 'package:lwcam/services/processing_bootstrap.dart';
import 'package:lwcam/services/sync_bootstrap.dart';
import 'package:lwcam/services/users_store_service.dart';
import 'package:lwcam/theme/app_colors.dart';

class AuthController extends GetxController {
  // Theme-resolved status colors for snackbars (no BuildContext here).
  ColorScheme get _cs => Get.theme.colorScheme;
  LifewoodColors get _lw => Get.theme.extension<LifewoodColors>()!;

  // Reactive state
  final username = ''.obs;
  final deviceId = ''.obs;
  final isLoading = false.obs;

  // ── User management (Phase 2) ────────────────────────────────────────────
  final TextEditingController passwordController = TextEditingController();

  /// The authenticated user for the session — the record from the local
  /// users snapshot. There is no SuperAdmin account in LWCAM; that role
  /// lives in the separate LWCam Admin app.
  final currentUser = Rxn<AppUser>();

  /// Where the users store was resolved from — drives login-page hints (e.g.
  /// "no store configured yet") and whether mutations are NAS-writable.
  final storeMode = UsersStoreSource.none.obs;

  /// The project selected for this capture session (set by [goToCapture] /
  /// [enterCaptureWithProject]). Lives here — not on BoxSessionController —
  /// because legacy keying-OFF capture (no BoxSessionController) is gated by
  /// project assignment too.
  final activeProject = Rxn<Project>();

  /// The password this session is actually authenticated WITH — the typed one
  /// normally, but the NEW one after a forced first-login change.
  ///
  /// It exists because the QC engine sign-in must not reuse
  /// `passwordController.text`. On a first login that box holds the temporary
  /// password; by the time the engine is signed into, the forced change has
  /// already written a different hash to PostgreSQL, which is what the engine
  /// authenticates against. The engine therefore rejected the login, and
  /// QcApiClient cached those wrong credentials, so every later retry in the
  /// session failed too and QC/Exports stayed unreachable until a full restart.
  String? _sessionPassword;

  /// Projects granted to the signed-in account for one specific [role].
  /// Role-scoped on purpose: `user_projects` is per-role, so a flattened
  /// lookup would hand a capture operator the admin/QC project set.
  List<Project> _projectsFor(UserRole role) {
    final store = usersStore?.lastLoaded;
    final u = currentUser.value;
    if (store == null || u == null) return const [];
    final keys = u.projectKeysFor(role);
    return store.projects.where((p) => keys.contains(p.key)).toList();
  }

  /// Projects the current user may capture into.
  List<Project> get assignedProjects => _projectsFor(UserRole.capture);

  /// Projects the current administrator may view in LWCAM.
  List<Project> get adminProjects => _projectsFor(UserRole.admin);

  /// Every project this account may open, in any role — the union of the
  /// per-role grants. Projects is the single way in for all roles now, so the
  /// list itself must not be role-specific; [assignedProjects] and
  /// [adminProjects] still gate what can be done once inside one.
  List<Project> get visibleProjects {
    final store = usersStore?.lastLoaded;
    final u = currentUser.value;
    if (store == null || u == null) return const [];
    final keys = u.allProjectKeys;
    return store.projects.where((p) => keys.contains(p.key)).toList();
  }

  /// The roles this account holds ON [project] — what decides which tabs its
  /// screen shows. Both layers must agree: the GLOBAL role (`users.roles`,
  /// which survives having no project at all) and a `user_projects` grant for
  /// that same role. Either one alone is not a grant — a stale row for a role
  /// the account no longer holds must not open a tab.
  Set<UserRole> rolesForProject(Project project) =>
      currentUser.value?.rolesForProjectKey(project.key) ?? const {};

  UsersStoreService? usersStore;

  AuditLogService? get _auditOrNull =>
      Get.isRegistered<AuditLogService>() ? Get.find<AuditLogService>() : null;

  // Text controllers for the fields
  final TextEditingController usernameController = TextEditingController();

  // Keys for SharedPreferences
  static const _keyLastUsername = 'last_username';
  static const _keyCurrentUsername = 'current_username';
  static const _keyCurrentDeviceId = 'current_deviceId';
  /// The last real capture device id used to log into THIS machine — unlike
  /// [_keyCurrentDeviceId], deliberately never cleared on logout. Sync is a
  /// per-machine setting but the outbox it drains is keyed by operator
  /// device id, and an admin-only session (no capture role) never has one of
  /// its own (see [resolveSyncDeviceId]).
  static const _keySyncDeviceId = 'sync_bound_device_id';

  @override
  void onInit() {
    super.onInit();
    _restoreLastSession();
    _initUsersStore();
  }

  /// Resolves the local snapshot's path and loads it (best-effort). Reads
  /// the directory from NodeConfig (LWCam Admin's Station Setup sets
  /// `usersStorePath` for the rare shared-folder override; null means the
  /// default `%USERPROFILE%\LWCAM_DBs`) rather than any per-PC prefs — the
  /// snapshot's location is a sync-machine setting now, not a NAS path.
  Future<void> _initUsersStore() async {
    try {
      String? storeDir;
      if (Get.isRegistered<NodeConfigService>()) {
        final config = await Get.find<NodeConfigService>().load();
        storeDir = config.usersStorePath;
      }
      final path = p.join(
        (storeDir == null || storeDir.trim().isEmpty)
            ? await UploadStatsDB().getBaseFolder()
            : storeDir.trim(),
        UsersStoreService.usersFileName,
      );
      usersStore = UsersStoreService(getStorePath: () => path);
      final res = await usersStore!.load();
      storeMode.value = res.source;
      print('🔐 Users store: ${res.source.name}');
    } catch (e) {
      print('⚠️ Users store init failed: $e');
      storeMode.value = UsersStoreSource.none;
    }
  }

  /// Re-resolves the snapshot path from NodeConfig and reloads it. Called by
  /// ProjectsController before it loads, and by the sync tick's
  /// applySnapshot path indirectly via [usersStore].
  Future<void> reloadUsersStore() => _initUsersStore();

  /// Restore last logged-in username (optional prefill).
  Future<void> _restoreLastSession() async {
    final prefs = await SharedPreferences.getInstance();
    final lastUser = prefs.getString(_keyLastUsername) ?? '';

    if (lastUser.isNotEmpty) {
      username.value = lastUser;
      usernameController.text = lastUser;
    }
  }

  /// Login entry point — always password-based (see [_loginWithPassword]).
  Future<void> login() => _loginWithPassword();

  /// Password login. The Device ID is NOT typed here — it comes from the
  /// account. After authentication, route by role: a single permitted area
  /// goes straight there, more than one lands on the Home chooser.
  Future<void> _loginWithPassword() async {
    final user = usernameController.text.trim();
    username.value = user;
    if (user.isEmpty) {
      showAppSnackBar('Error', 'Username is required.',
          backgroundColor: _cs.error, colorText: _cs.onError);
      return;
    }

    // Opportunistic retry of any password change queued locally during a
    // prior offline session — best-effort, never blocks or slows login.
    unawaited(usersStore?.flushPendingPasswordChanges() ?? Future.value());

    // Pick up a destination path LWCam Admin's Station Setup may have
    // (re)written since launch — best-effort, cheap local file read.
    if (Get.isRegistered<SettingsController>()) {
      unawaited(Get.find<SettingsController>().reloadDestination());
    }

    final ok = await _authenticate(user); // sets currentUser on success
    if (!ok) return;
    final u = currentUser.value!;

    // Device ID is the one assigned to the account (empty for admin-only).
    final devId = u.deviceId ?? '';
    deviceId.value = devId;

    if (devId.isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keySyncDeviceId, devId);
    }

    // Best-effort: (re)start the background sync drain now that the
    // per-device SQLite file's key is known. Never blocks or fails login —
    // sync is opt-in (NodeConfig.syncEnabled defaults false) and this is
    // purely additive to the existing login flow.
    if (devId.isNotEmpty && Get.isRegistered<NodeConfigService>()) {
      try {
        final config = await Get.find<NodeConfigService>().load();
        await SyncBootstrap.apply(config, deviceId: devId);
        // Re-bind the processing report agent to the SAME device id the sync
        // drain now uses. Startup bound it to the PERSISTED id; when this
        // login switches devices, reports enqueued under the old binding
        // would land in an outbox nobody drains (handover §7.8). The apply
        // also migrates any rows already stranded under the old id.
        await ProcessingBootstrap.apply(config);
      } catch (e) {
        print('⚠️ Sync bootstrap skipped: $e');
      }
    }

    if (!u.canNormalMode && !u.isAdmin && !u.canQc) {
      showAppSnackBar('No access',
          'This account has no access to LWCAM. Contact an administrator.',
          backgroundColor: _cs.error, colorText: _cs.onError);
      currentUser.value = null;
      deviceId.value = '';
      return;
    }

    // Capture-only accounts need at least one assigned project or they have
    // nowhere to land. Gate here — BEFORE persisting the session or showing
    // "Login Successful" — so a blocked user sees ONLY the explanatory modal,
    // never a success message.
    final permitted =
        [u.canNormalMode, u.isAdmin, u.canQc].where((b) => b).length;
    final captureOnly = permitted == 1 && u.canNormalMode;
    final qcOnly = permitted == 1 && u.canQc;
    // QC is reached only through a project now (the unscoped "all projects"
    // queue is gone), so a QC-only account with no grant has nowhere to land
    // either - same block, same modal, before the session is persisted.
    final qcProjects = _projectsFor(UserRole.qc);
    if ((captureOnly && assignedProjects.isEmpty) ||
        (qcOnly && qcProjects.isEmpty)) {
      currentUser.value = null;
      deviceId.value = '';
      await _showNoProjectDialog();
      return;
    }

    isLoading.value = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLastUsername, user);
    await prefs.setString(_keyCurrentUsername, user);
    await prefs.setString(_keyCurrentDeviceId, devId);
    isLoading.value = false;

    // Best-effort last-login stamp — never blocks login. Canonical
    // username (the store record's), not the typed one: PG matches
    // user_id exactly, so a case-differing typed name would stamp nothing.
    await usersStore?.recordLogin(u.username);

    // Sign in to the local QC engine too, for accounts that can reach QC. Same
    // credentials, same bcrypt hash in users.password - the engine pins prefix
    // 2a / cost 10 / 72-byte truncation precisely so both sides accept one
    // password. The client keeps the credentials in memory for the session (see
    // QcApiClient._credentials) so this one attempt is no longer the only one:
    // if the engine is still booting here, the first QC screen that needs a
    // session signs in again by itself.
    // Best-effort and unawaited - the engine takes seconds to boot and capture
    // must never wait on it; the QC screens re-check and report if it failed.
    // Admins too, not just QC: the export screens are admin-gated on the
    // engine, and an admin with no qc role was never signed in - so every
    // export call failed with "Not signed in to the QC engine" for exactly the
    // role that owns exporting. The engine's own login accepts admin.
    if (u.canQc || u.isAdmin) {
      unawaited(
        QcApiClient.instance
            .signIn(u.username, _sessionPassword ?? passwordController.text)
            .catchError((Object e) {
          print('⚠️ QC engine sign-in failed: $e');
          // Say so HERE, not only when the operator later opens a QC or Exports
          // screen and meets a bare "Not signed in". A print is invisible in an
          // installed build, so this failure used to be discoverable only by
          // reading the source.
          //
          // A warning, not an error: capture does not need the engine at all,
          // and the engine may still be booting - the client keeps the reason
          // either way, so the screens that do need it can name it.
          showAppSnackBar(
            'QC engine unavailable',
            'Signed in to LWCAM, but not to the QC engine: '
                '${e is QcApiException ? e.message : e}',
            backgroundColor: _lw.warning,
            colorText: _lw.onWarning,
          );
        }),
      );
    }

    _auditOrNull?.setContext(deviceId: devId, operator: user);
    await _auditOrNull?.log(AuditActions.loginSuccess,
        details: {'roles': u.roles.map((r) => r.name).join(',')});

    showAppSnackBar('Login Successful', 'Welcome, $user!',
        backgroundColor: _lw.success, colorText: _lw.onSuccess);

    // Auto-route when one project and one job leave nothing to choose;
    // otherwise the shell, whose Projects list is the chooser for every role.
    if (captureOnly) {
      // Awaited: the only way this returns false here is the device-registry
      // block (≥1 project is guaranteed by the gate above), and that resolves
      // asynchronously. Unawaited, the operator was left on the login page
      // with a live session and no route — the worst of both states.
      final entered = await goToCapture();
      if (!entered) {
        // enterCaptureWithProject already explained why in a modal. Drop the
        // half-authenticated session so it matches what the user can see,
        // same as the no-project gate above.
        currentUser.value = null;
        deviceId.value = '';
      }
    } else if (qcOnly && qcProjects.length == 1) {
      // One project, one job: skip the chooser exactly as capture-only does.
      // No device-registry gate - QC reviews other people's captures and has
      // no Device ID of its own.
      Get.off(() => QcHomePage(project: qcProjects.single));
    } else {
      // Everything else - admin, any multi-role account, or a single-role
      // account holding several projects - starts on the shell's Projects list.
      Get.offNamed('/home');
    }
  }

  /// Persistent modal shown when a capture user has no assigned project — it
  /// blocks (barrierDismissible: false) until the user taps OK. Used both by
  /// the login gate and by [goToCapture] (Home "Capture" tile for a dual-role
  /// admin who hasn't been assigned a project).
  Future<void> _showNoProjectDialog() {
    return Get.dialog<void>(
      AlertDialog(
        title: const Text('No Project Assigned'),
        content: const Text('Please contact an administrator.'),
        actions: [
          TextButton(onPressed: () => Get.back(), child: const Text('OK')),
        ],
      ),
      barrierDismissible: false,
    );
  }

  /// Entry point into capture — the project gate. Used by password login's
  /// auto-route and by the Home "Capture" tile, so it covers both legacy
  /// (keying OFF → gallery) and Box Mode (keying ON → boxes) uniformly.
  /// Returns false when the user could NOT be routed into capture — no project
  /// assigned, or the device registry blocked this project — so callers can
  /// react (e.g. undo an auto-login that has nowhere else to land).
  ///
  /// Must be awaited: the device-registry gate inside [enterCaptureWithProject]
  /// is async. Firing it unawaited returned `true` before the gate resolved, so
  /// a blocked capture-only operator was left sitting on the login page with a
  /// live session, having already been told "Login Successful".
  Future<bool> goToCapture() async {
    final projects = assignedProjects;
    if (projects.isEmpty) {
      // Persistent modal (not a transient snackbar) — the user can't proceed.
      await _showNoProjectDialog();
      return false;
    }
    if (projects.length == 1) {
      return enterCaptureWithProject(projects.single);
    }
    // The shell's Projects list is the chooser now; picking a project there
    // routes through its Capture tab back into enterCaptureWithProject.
    Get.offNamed('/home');
    return true;
  }

  /// Sets the active project and routes into capture. Called by
  /// [goToCapture] (single-project auto-select) and by ProjectAreaPage's
  /// Capture tab (user picked a project from the list). With metadata
  /// keying ON, lands on the Box list (Box→Folders workflow); OFF keeps the
  /// direct-to-gallery flow.
  ///
  /// Gate: the cloud device registry binds each capture device to
  /// one project via its location code — entering a DIFFERENT project is
  /// blocked until an admin reassigns the device (Devices screen). The gate
  /// silently allows whenever the registry can't participate (sync off, PG
  /// unreachable, an admin-only account's empty device id, code-less
  /// project).
  /// Returns false when the registry blocked entry (no route was taken).
  /// [replaceRoute] false PUSHES capture instead of replacing the current
  /// route, so Back returns to whatever opened it. The multi-card project area
  /// passes false: QC Check there is a plain push and Back returns to the
  /// cards, and Capture replacing the page instead made the same Back skip a
  /// level to the projects list. It stays true everywhere the caller IS the
  /// thing being replaced - the login auto-route, and the single-card handoff,
  /// which stands in for the area page so Back should reach the projects list.
  Future<bool> enterCaptureWithProject(Project project,
      {bool replaceRoute = true}) async {
    final gate = await DeviceRegistry().registerOrCheck(
      deviceId: deviceId.value,
      username: currentUser.value?.username ?? username.value,
      project: project,
    );
    if (gate.gate == DeviceGate.blocked) {
      final bound = gate.boundProjectName != null
          ? '"${gate.boundProjectName}" (${gate.boundLocationCode})'
          : 'location code "${gate.boundLocationCode}"';
      await Get.dialog(AlertDialog(
        title: const Text('Device assigned to another project'),
        content: Text(
            'This device (${deviceId.value}) is assigned to project $bound. '
            'An administrator must reassign it from the Devices screen '
            'before it can capture into "${project.name}".'),
        actions: [
          TextButton(onPressed: () => Get.back(), child: const Text('OK')),
        ],
      ));
      return false; // activeProject untouched — no route into capture
    }
    activeProject.value = project;
    final keyingOn = usersStore?.metadataKeyingEnabled ?? false;
    final route = keyingOn ? '/boxes' : '/gallery';
    if (replaceRoute) {
      Get.offNamed(route);
    } else {
      Get.toNamed(route);
    }
    return true;
  }

  /// Verifies the password and handles a forced first-login/reset change.
  /// Sets [currentUser] on success. Shows the appropriate message and
  /// returns false on any failure.
  Future<bool> _authenticate(String user) async {
    final password = passwordController.text;
    if (password.isEmpty) {
      showAppSnackBar('Error', 'Password is required.',
          backgroundColor: _cs.error, colorText: _cs.onError);
      return false;
    }

    // The typed password is what this session holds unless a forced change
    // below replaces it.
    _sessionPassword = password;

    final outcome = await usersStore!.authenticate(user, password);
    switch (outcome.status) {
      case AuthStatus.unknownUser:
      case AuthStatus.wrongPassword:
        // Deliberately vague — don't reveal which usernames exist.
        showAppSnackBar('Login failed', 'Invalid username or password.',
            backgroundColor: _cs.error, colorText: _cs.onError);
        await _auditOrNull?.log(AuditActions.loginFailed,
            details: {'username': user, 'reason': outcome.status.name});
        return false;
      case AuthStatus.inactive:
        showAppSnackBar('Account disabled',
            'This account has been deactivated. Contact an administrator.',
            backgroundColor: _cs.error, colorText: _cs.onError);
        await _auditOrNull?.log(AuditActions.loginFailed,
            details: {'username': user, 'reason': 'inactive'});
        return false;
      case AuthStatus.noStore:
        showAppSnackBar('Unavailable',
            'No users snapshot on this PC yet — run LWCam Admin station setup.',
            backgroundColor: _cs.error, colorText: _cs.onError);
        return false;
      case AuthStatus.mustChangePassword:
        // A forced password change tries PostgreSQL first (it IS the
        // account record) but no longer blocks offline — some sites are
        // permanently offline, so an unreachable PG just queues the change
        // locally (see UsersStoreService.changeOwnPassword) and lets the
        // operator in immediately with their new password.
        //
        // CANONICAL username, not the typed one: local lookup is
        // case-insensitive but PG matches user_id exactly — a typed
        // 'ALICE' for record 'alice' would make the PG UPDATE a silent
        // 0-row no-op (and mark a queued change delivered when it wasn't).
        final canonical = outcome.user!.username;
        final changed = await _forcePasswordChange(canonical, currentHash: outcome.user!.passwordHash);
        if (!changed) return false;
        currentUser.value = usersStore!.lastLoaded?.findUser(canonical);
        return currentUser.value != null;
      case AuthStatus.ok:
        currentUser.value = outcome.user;
        return true;
    }
  }

  Future<bool> _forcePasswordChange(String user, {required String currentHash}) async {
    final newPassword = await Get.dialog<String>(
      ChangePasswordDialog(currentPasswordHash: currentHash),
      barrierDismissible: false,
    );
    if (newPassword == null || newPassword.isEmpty) return false; // cancelled
    try {
      final queuedOffline = await usersStore!.changeOwnPassword(user, newPassword);
      // From here on this is the account's password — but ONLY if PostgreSQL
      // actually took it. The QC engine authenticates against PostgreSQL, so
      // the session must present whatever PG currently holds.
      //
      // queuedOffline means the PG write failed and the hash was queued
      // locally (changeOwnPassword queues on ANY failure, not just an
      // unreachable host), so PG still holds the OLD hash. Assigning the new
      // password here would then get the engine sign-in rejected and cached
      // wrong for the session — precisely the bug this field was added to fix,
      // inverted. Leaving it as the typed password keeps it matching PG.
      if (!queuedOffline) _sessionPassword = newPassword;
      await _auditOrNull?.log(AuditActions.passwordChanged, details: {'username': user});
      if (queuedOffline) {
        showAppSnackBar('Password changed',
            'Saved on this device — it will sync to the server once reconnected.',
            backgroundColor: _lw.warning, colorText: _lw.onWarning);
      }
      return true;
    } catch (e) {
      showAppSnackBar('Error', 'Could not update your password: $e',
          backgroundColor: _cs.error, colorText: _cs.onError);
      return false;
    }
  }

  /// The device id `SyncBootstrap` should drain for this machine: the live
  /// session's device id if one exists (a real capture/dual-role account),
  /// else the last real capture device id ever used to log in here. Needed
  /// because the Settings "Sync / Node" section is Admin-gated, and an
  /// admin-only account (no capture role) is never tied to a physical device
  /// — without this fallback, saving sync settings from that account would
  /// always silently have nothing to start against.
  Future<String> resolveSyncDeviceId() async {
    if (deviceId.value.isNotEmpty) return deviceId.value;
    return readPersistedSyncDeviceId();
  }

  /// Static variant for callers with no live `AuthController` instance yet —
  /// main.dart's startup bootstrap runs before login, so it resumes sync for
  /// whichever device last logged in here rather than waiting for a fresh
  /// login every app launch.
  static Future<String> readPersistedSyncDeviceId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_keySyncDeviceId) ?? '';
  }

  /// Logout and clear current-session keys (but keep per-user mapping).
  Future<void> logout() async {
    // Logged before the context is cleared below, so the line still carries
    // the outgoing operator/device identity.
    await _auditOrNull?.log(AuditActions.logout);
    _auditOrNull?.setContext();

    // The engine token and the held credentials outlive this app's session
    // otherwise, and the next operator at this PC would inherit the last one's
    // QC access - or have it silently re-created.
    QcApiClient.instance.signOut();
    // Same reason: this is one operator's password, not the app's.
    _sessionPassword = null;

    // Close the integrated phone mirror; the login screen gets full screen.
    await ScrcpyService.instance.stop();

    final prefs = await SharedPreferences.getInstance();

    await prefs.remove(_keyCurrentUsername);
    await prefs.remove(_keyCurrentDeviceId);

    username.value = '';
    deviceId.value = '';
    currentUser.value = null;
    activeProject.value = null;

    usernameController.clear();
    passwordController.clear();

    // Box session (Box→Folders workflow) is per-operator/device — drop it.
    if (Get.isRegistered<BoxSessionController>()) {
      Get.delete<BoxSessionController>(force: true);
    }
    // Admin Projects page state must not leak to the next operator.
    if (Get.isRegistered<ProjectsController>()) {
      Get.delete<ProjectsController>(force: true);
    }

    // Re-evaluate the users store for the next login (e.g. an admin may have
    // created it, or roles/passwords changed, during this session).
    await _initUsersStore();

    Get.offAllNamed('/');
    showAppSnackBar(
      'Logged Out',
      'You have been logged out.',
      backgroundColor: _lw.info,
      colorText: _lw.onInfo,
    );
  }

  @override
  void onClose() {
    usernameController.dispose();
    passwordController.dispose();
    super.onClose();
  }
}
