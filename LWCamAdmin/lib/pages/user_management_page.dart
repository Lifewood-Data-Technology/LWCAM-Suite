import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:get/get.dart';

import '../auth/super_admin.dart';
import '../controllers/user_management_controller.dart';
import '../models/app_user.dart';
import '../services/snackbar_service.dart';
import '../theme/app_colors.dart';

/// Create, edit roles + Device ID, reset password, activate/deactivate,
/// delete. The default temporary password and the SuperAdmin password live
/// in App Settings, not here. Edits are always allowed — offline ones just
/// queue (AdminStoreService); a status strip on Home covers the rest.
class UserManagementPage extends StatelessWidget {
  const UserManagementPage({super.key});

  // The rule itself lives with the model (kDeviceIdPattern) and is enforced
  // again in AdminStoreService, which is what actually guards the store. This
  // check only exists so the operator gets the message inline instead of a
  // thrown error after pressing Save.

  @override
  Widget build(BuildContext context) {
    final c = Get.isRegistered<UserManagementController>()
        ? Get.find<UserManagementController>()
        : Get.put(UserManagementController());

    return Scaffold(
      appBar: AppBar(
        title: const Text('User Management'),
        actions: [
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: c.load),
        ],
      ),
      body: Stack(
        children: [
          Obx(() {
            final users = c.users;
            return ListView(
              padding: const EdgeInsets.only(top: 8, bottom: 96),
              children: [
                ...users.map((u) => _userTile(context, c, u)),
                if (users.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: Text('No users yet. Tap "Add user".')),
                  ),
              ],
            );
          }),
          Positioned(
            right: 16,
            bottom: 16,
            child: FloatingActionButton.extended(
              heroTag: 'usersFab',
              onPressed: () => _showUserDialog(context, c),
              icon: const Icon(Icons.person_add_alt_1),
              label: const Text('Add user'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _userTile(BuildContext context, UserManagementController c, AppUser u) {
    final roleText = u.roles.map(_roleLabel).join(', ');
    final subtitle = StringBuffer(roleText.isEmpty ? 'No roles' : roleText);
    if (u.requiresDeviceId) subtitle.write('  ·  ${u.deviceId ?? '—'}');
    if (u.mustChangePassword) subtitle.write('  ·  must change password');
    if (!u.active) subtitle.write('  ·  DEACTIVATED');
    subtitle.write('  ·  ${c.projectLabel(u)}');

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: u.active ? null : Theme.of(context).colorScheme.surfaceContainerHighest,
        child: Icon(u.isAdmin ? Icons.shield_outlined : Icons.person_outline),
      ),
      title: Text(u.username,
          style: TextStyle(
            fontWeight: FontWeight.w600,
            color: u.active ? null : Theme.of(context).colorScheme.outline,
          )),
      subtitle: Text(subtitle.toString()),
      trailing: PopupMenuButton<String>(
        onSelected: (value) => _onUserAction(context, c, u, value),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'edit', child: Text('Edit roles / Device ID')),
          const PopupMenuItem(value: 'reset', child: Text('Reset password')),
          PopupMenuItem(value: 'active', child: Text(u.active ? 'Deactivate' : 'Reactivate')),
          const PopupMenuItem(value: 'delete', child: Text('Delete…')),
        ],
      ),
    );
  }

  Future<void> _onUserAction(
      BuildContext context, UserManagementController c, AppUser u, String action) async {
    switch (action) {
      case 'edit':
        await _showUserDialog(context, c, existing: u);
        break;
      case 'reset':
        await _confirmAndRun(
          context,
          title: 'Reset password?',
          message: '"${u.username}" will be set back to the default temporary password '
              'and must change it on next login.',
          run: () => c.resetPassword(u.username),
          successMsg: 'Password reset to the temporary password.',
        );
        break;
      case 'active':
        await _confirmAndRun(
          context,
          title: u.active ? 'Deactivate user?' : 'Reactivate user?',
          message: u.active
              ? '"${u.username}" will no longer be able to sign in.'
              : '"${u.username}" will be able to sign in again.',
          run: () => c.setActive(u.username, !u.active),
          successMsg: u.active ? 'User deactivated.' : 'User reactivated.',
        );
        break;
      case 'delete':
        await _confirmDelete(context, c, u);
        break;
    }
  }

  // ── Add / edit dialog ─────────────────────────────────────────────────────

  Future<void> _showUserDialog(BuildContext context, UserManagementController c,
      {AppUser? existing}) async {
    final isEdit = existing != null;
    if (!isEdit && !c.hasDefaultTempPassword) {
      showAppSnackBar('Set a temporary password first',
          'Set the default temporary password in App Settings before creating users.',
          backgroundColor: Get.theme.extension<LifewoodColors>()!.warning,
          colorText: Get.theme.extension<LifewoodColors>()!.onWarning);
      return;
    }

    final usernameCtl = TextEditingController(text: existing?.username ?? '');
    final deviceCtl = TextEditingController(text: existing?.deviceId ?? '');
    final roles = {...(existing?.roles ?? <UserRole>{})};
    final projects = c.projects;
    final selectedProjectKeysByRole = <UserRole, Set<String>>{
      for (final role in roles) role: {...(existing?.projectKeysFor(role) ?? const <String>{})},
    };

    final saved = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setState) {
            final capturing = roles.contains(UserRole.capture);
            return AlertDialog(
              insetPadding: const EdgeInsets.all(24),
              title: Text(isEdit ? 'Edit ${existing.username}' : 'Add user',
                  style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
              content: SizedBox(
                width: 540,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      TextField(
                        controller: usernameCtl,
                        enabled: !isEdit,
                        style: const TextStyle(fontSize: 16),
                        decoration: const InputDecoration(labelText: 'Username (letters only)'),
                      ),
                      const SizedBox(height: 16),
                      const Text('Roles',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Admin (Project View + Dashboard)',
                            style: TextStyle(fontSize: 15)),
                        value: roles.contains(UserRole.admin),
                        onChanged: (v) => setState(() {
                          v == true ? roles.add(UserRole.admin) : roles.remove(UserRole.admin);
                          if (v == true) selectedProjectKeysByRole.putIfAbsent(UserRole.admin, () => {});
                          if (v != true) selectedProjectKeysByRole.remove(UserRole.admin);
                        }),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('Capture (Capture View)', style: TextStyle(fontSize: 15)),
                        value: roles.contains(UserRole.capture),
                        onChanged: (v) => setState(() {
                          v == true ? roles.add(UserRole.capture) : roles.remove(UserRole.capture);
                          if (v == true) selectedProjectKeysByRole.putIfAbsent(UserRole.capture, () => {});
                          if (v != true) selectedProjectKeysByRole.remove(UserRole.capture);
                        }),
                      ),
                      CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text('QC (Folder QC web platform)',
                            style: TextStyle(fontSize: 15)),
                        value: roles.contains(UserRole.qc),
                        onChanged: (v) => setState(() {
                          v == true ? roles.add(UserRole.qc) : roles.remove(UserRole.qc);
                          if (v == true) selectedProjectKeysByRole.putIfAbsent(UserRole.qc, () => {});
                          if (v != true) selectedProjectKeysByRole.remove(UserRole.qc);
                        }),
                      ),
                      if (capturing) ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: deviceCtl,
                          style: const TextStyle(fontSize: 16),
                          textCapitalization: TextCapitalization.characters,
                          // Upper-cased as it is typed, so what the operator
                          // sees is exactly what gets stored and stamped.
                          // toUpperCase never changes ASCII length, so the
                          // caret position stays valid.
                          inputFormatters: [
                            TextInputFormatter.withFunction(
                              (_, next) => next.copyWith(text: next.text.toUpperCase()),
                            ),
                          ],
                          decoration: const InputDecoration(
                            labelText: 'Device ID',
                            helperText: 'Required for Capture. Stamps their records; must be '
                                'unique across accounts. Letters, digits, "_" or "-".',
                            helperStyle: TextStyle(fontSize: 13),
                          ),
                        ),
                      ] else
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Text('Admin-only account — no Device ID.',
                              style: TextStyle(
                                  color: Get.theme.colorScheme.onSurfaceVariant, fontSize: 13)),
                        ),
                      const SizedBox(height: 16),
                      const Text('Projects',
                          style: TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
                      if (projects.isEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text('No projects yet — create one first.',
                              style: TextStyle(
                                  color: Get.theme.colorScheme.onSurfaceVariant, fontSize: 13)),
                        )
                      else
                        for (final role in UserRole.values.where(roles.contains)) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 8),
                            child: Text('${_roleLabel(role)} projects',
                                style: const TextStyle(fontWeight: FontWeight.w600)),
                          ),
                          ...projects.map((p) => CheckboxListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text('${p.name} (${p.projectId})',
                                    style: const TextStyle(fontSize: 15)),
                                value: selectedProjectKeysByRole[role]?.contains(p.key) ?? false,
                                onChanged: (v) => setState(() => v == true
                                    ? selectedProjectKeysByRole[role]!.add(p.key)
                                    : selectedProjectKeysByRole[role]!.remove(p.key)),
                              )),
                        ],
                      if (!isEdit) ...[
                        const SizedBox(height: 8),
                        Text(
                          'New users start on the default temporary password (App '
                          'Settings) and must change it on first login.',
                          style: TextStyle(
                              color: Get.theme.colorScheme.onSurfaceVariant, fontSize: 13),
                        ),
                      ],
                      if (error != null) ...[
                        const SizedBox(height: 8),
                        Text(error!,
                            style: TextStyle(color: Get.theme.colorScheme.error, fontSize: 14)),
                      ],
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                    onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
                ElevatedButton(
                  onPressed: () {
                    final name = usernameCtl.text.trim();
                    if (!isEdit && !RegExp(r'^[A-Za-z]+$').hasMatch(name)) {
                      setState(() => error = 'Username must contain only letters.');
                      return;
                    }
                    if (!isEdit && isSuperAdminName(name)) {
                      setState(() => error = 'This username is reserved.');
                      return;
                    }
                    if (roles.isEmpty) {
                      setState(() => error = 'Select at least one role.');
                      return;
                    }
                    final needsDevice = roles.contains(UserRole.capture);
                    if (needsDevice &&
                        !kDeviceIdPattern.hasMatch(normalizeDeviceId(deviceCtl.text))) {
                      setState(() => error = 'Device ID required: 2-32 letters, digits, '
                          '"_" or "-", starting with a letter or digit.');
                      return;
                    }
                    if (needsDevice && (selectedProjectKeysByRole[UserRole.capture]?.isEmpty ?? true)) {
                      setState(() => error = 'Assign at least one project — capture users '
                          'without a project cannot sign in to capture.');
                      return;
                    }
                    // The QC platform scopes its task queue to the reviewer's
                    // projects, so a project-less QC account sees an empty queue
                    // with no indication why.
                    if (roles.contains(UserRole.qc) &&
                        (selectedProjectKeysByRole[UserRole.qc]?.isEmpty ?? true)) {
                      setState(() => error = 'Assign at least one project — QC reviewers '
                          'only see folders from their assigned projects.');
                      return;
                    }
                    if (roles.contains(UserRole.admin) &&
                        (selectedProjectKeysByRole[UserRole.admin]?.isEmpty ?? true)) {
                      setState(() => error = 'Assign at least one project — admins only see their assigned projects.');
                      return;
                    }
                    Navigator.of(ctx).pop(true);
                  },
                  child: Text(isEdit ? 'Save' : 'Create'),
                ),
              ],
            );
          },
        );
      },
    );

    if (saved != true) return;
    final deviceId = deviceCtl.text.trim().isEmpty ? null : deviceCtl.text.trim();
    try {
      if (isEdit) {
        await c.updateRoles(
          username: existing.username,
          roles: roles,
          deviceId: deviceId,
          roleProjectKeys: selectedProjectKeysByRole,
        );
        showAppSnackBar('Saved', 'Updated ${existing.username}.',
            backgroundColor: Get.theme.extension<LifewoodColors>()!.success,
            colorText: Get.theme.extension<LifewoodColors>()!.onSuccess);
      } else {
        await c.createUser(
          username: usernameCtl.text.trim(),
          roles: roles,
          deviceId: deviceId,
          roleProjectKeys: selectedProjectKeysByRole,
        );
        showAppSnackBar('User created', 'Give them the temporary password to sign in.',
            backgroundColor: Get.theme.extension<LifewoodColors>()!.success,
            colorText: Get.theme.extension<LifewoodColors>()!.onSuccess);
      }
    } catch (e) {
      showAppSnackBar('Error', '$e',
          backgroundColor: Get.theme.colorScheme.error, colorText: Get.theme.colorScheme.onError);
    }
  }

  Future<void> _confirmDelete(BuildContext context, UserManagementController c, AppUser u) async {
    final ctl = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('Delete user'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('This permanently deletes "${u.username}". Type the username to confirm.'),
                const SizedBox(height: 12),
                TextField(controller: ctl, decoration: const InputDecoration(labelText: 'Username')),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: TextStyle(color: Get.theme.colorScheme.error)),
                ],
              ],
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
              ElevatedButton(
                style: ElevatedButton.styleFrom(
                    backgroundColor: Theme.of(ctx).colorScheme.error,
                    foregroundColor: Theme.of(ctx).colorScheme.onError),
                onPressed: () {
                  if (ctl.text.trim().toLowerCase() != u.username.toLowerCase()) {
                    setState(() => error = 'Username does not match.');
                    return;
                  }
                  Navigator.of(ctx).pop(true);
                },
                child: const Text('Delete'),
              ),
            ],
          ),
        );
      },
    );
    if (confirmed != true) return;
    try {
      await c.deleteUser(u.username);
      showAppSnackBar('Deleted', '"${u.username}" removed.',
          backgroundColor: Get.theme.extension<LifewoodColors>()!.success,
          colorText: Get.theme.extension<LifewoodColors>()!.onSuccess);
    } catch (e) {
      showAppSnackBar('Error', '$e',
          backgroundColor: Get.theme.colorScheme.error, colorText: Get.theme.colorScheme.onError);
    }
  }

  Future<void> _confirmAndRun(
    BuildContext context, {
    required String title,
    required String message,
    required Future<void> Function() run,
    required String successMsg,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
          ElevatedButton(onPressed: () => Navigator.of(ctx).pop(true), child: const Text('Confirm')),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await run();
      showAppSnackBar('Done', successMsg,
          backgroundColor: Get.theme.extension<LifewoodColors>()!.success,
          colorText: Get.theme.extension<LifewoodColors>()!.onSuccess);
    } catch (e) {
      showAppSnackBar('Error', '$e',
          backgroundColor: Get.theme.colorScheme.error, colorText: Get.theme.colorScheme.onError);
    }
  }

  String _roleLabel(UserRole r) {
    switch (r) {
      case UserRole.admin:
        return 'Admin';
      case UserRole.capture:
        return 'Capture';
      case UserRole.qc:
        return 'QC';
    }
  }
}
