// ignore_for_file: avoid_print

// Sign-in and session state for the capture app (LWCAM).
// Checks the user against the local users snapshot (pulled from PostgreSQL),
// forces a password change when required, and decides where the account
// goes next: project choice, then capture. Also binds the capture device to
// its project (see device_registry.dart) and restarts sync once a device id is known.
// Logout tears down the box session and the phone mirror.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lwcam/auth/offline_temp_password.dart';
import 'package:lwcam/controllers/box_session_controller.dart';
import 'package:lwcam/controllers/projects_controller.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/models/app_user.dart';
import 'package:lwcam/models/project.dart';
import 'package:lwcam/pages/change_password_dialog.dart';
import 'package:lwcam/pages/settings_page.dart' show SettingsController;
import 'package:lwcam/services/audit_log_service.dart';
import 'package:lwcam/services/device_registry.dart';
import 'package:lwcam/services/node_config_service.dart';
import 'package:lwcam/services/scrcpy_service.dart';
import 'package:lwcam/services/snackbar_service.dart';
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


  /// Projects granted to the signed-in account for one specific [role].
  /// Role-scoped on purpose: `user_projects` is per-role, so a flattened
  /// lookup would hand a capture operator the admin project set.
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
    // this is purely additive to the existing login flow.
    if (devId.isNotEmpty && Get.isRegistered<NodeConfigService>()) {
      try {
        final config = await Get.find<NodeConfigService>().load();
        await SyncBootstrap.apply(config, deviceId: devId);
      } catch (e) {
        print('⚠️ Sync bootstrap skipped: $e');
      }
    }

    // A reviewer-only account lands here now that the QC screens have gone
    // (Phase 8): it holds a role this app grants nothing for, so it has no
    // access to LWCAM and is told so, once, before any session is persisted.
    if (!u.canNormalMode && !u.isAdmin) {
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
    final permitted = [u.canNormalMode, u.isAdmin].where((b) => b).length;
    final captureOnly = permitted == 1 && u.canNormalMode;
    if (captureOnly && assignedProjects.isEmpty) {
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
  /// passes false, so Back returns to the cards; Capture replacing the page
  /// instead made that Back skip a level to the projects list. It stays true
  /// everywhere the caller IS the
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
            'before it can capture into "${project.name}".'
            '${gate.fromCache ? ' (This PC could not reach the database; '
                'this is the last known assignment.)' : ''}'),
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
        // A forced password change is done in PostgreSQL (it IS the account
        // record; the function needs the typed password as the OLD one).
        // Offline, nothing is changed or stored: the operator is let in for
        // this session with the temporary password and is asked again at the
        // next login (see _forcePasswordChange).
        //
        // CANONICAL username, not the typed one: local lookup is
        // case-insensitive but PG matches user_id exactly — a typed
        // 'ALICE' for record 'alice' would make the PG UPDATE a silent
        // 0-row no-op (and mark a queued change delivered when it wasn't).
        final canonical = outcome.user!.username;
        final changed = await _forcePasswordChange(canonical,
            currentHash: outcome.user!.passwordHash, oldPassword: password);
        if (!changed) return false;
        currentUser.value = usersStore!.lastLoaded?.findUser(canonical);
        return currentUser.value != null;
      case AuthStatus.ok:
        currentUser.value = outcome.user;
        return true;
    }
  }

  Future<bool> _forcePasswordChange(String user,
      {required String currentHash, required String oldPassword}) async {
    final newPassword = await Get.dialog<String>(
      ChangePasswordDialog(currentPasswordHash: currentHash),
      barrierDismissible: false,
    );
    if (newPassword == null || newPassword.isEmpty) return false; // cancelled
    try {
      final result = await usersStore!.changeOwnPassword(user, oldPassword, newPassword);
      switch (result) {
        case PasswordChangeResult.wrongCurrent:
          showAppSnackBar('Password not changed',
              'The database did not accept your current password. Nothing was changed.',
              backgroundColor: _cs.error, colorText: _cs.onError);
          return false;
        case PasswordChangeResult.offline:
        case PasswordChangeResult.needsDbUpdate:
          // Keep the operator able to capture offline, but only for a few
          // sign-ins / days: no plaintext on disk, so the change waits for a
          // login with the database reachable.
          if (!await OfflineTempPassword.tryConsume(user)) {
            showAppSnackBar('Password change required',
                'Your temporary password can no longer be used offline. '
                'Connect this PC to the database and sign in again to choose '
                'a new password.',
                backgroundColor: _cs.error, colorText: _cs.onError);
            return false;
          }
          showAppSnackBar(
              'Password not changed',
              result == PasswordChangeResult.needsDbUpdate
                  ? 'The database needs updating (run LWCamDatabaseSetup) - '
                      'you can continue for now.'
                  : 'Connect to the database to change your password. You can '
                      'continue with your temporary password for now.',
              backgroundColor: _lw.warning, colorText: _lw.onWarning);
          return true;
        case PasswordChangeResult.changed:
          await OfflineTempPassword.clear(user);
          await _auditOrNull?.log(AuditActions.passwordChanged, details: {'username': user});
          return true;
      }
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
