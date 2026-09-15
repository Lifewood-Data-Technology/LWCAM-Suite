import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/app_settings_controller.dart';
import '../models/app_user.dart';
import '../services/snackbar_service.dart';
import '../theme/app_colors.dart';

/// Metadata keying toggle, remote shutter config, default temp password
/// (set-only — no decrypted "Current: …" display; that feature retired
/// with admin-viewable passwords), and the SuperAdmin password override.
class AppSettingsPage extends StatelessWidget {
  const AppSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = Get.isRegistered<AppSettingsController>()
        ? Get.find<AppSettingsController>()
        : Get.put(AppSettingsController());

    return Scaffold(
      appBar: AppBar(title: const Text('App Settings')),
      body: Obx(() {
        final s = c.settings;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('Metadata Keying', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: SwitchListTile(
                contentPadding: const EdgeInsets.all(16),
                secondary: const CircleAvatar(child: Icon(Icons.edit_note)),
                title: const Text('Require metadata keying'),
                subtitle: Text(s.metadataKeyingEnabled
                    ? 'ON — Group Mode keying is active for capture PCs.'
                    : 'OFF — capture behaves like legacy Normal Mode.'),
                value: s.metadataKeyingEnabled,
                onChanged: (v) => _run(() => c.setMetadataKeyingEnabled(v), 'Metadata keying updated.'),
              ),
            ),
            const SizedBox(height: 24),
            const Text('Camera Shutter', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'The phone shutter is hidden in the cropped mirror — operators '
                      'press this key to fire it.',
                      style: TextStyle(
                          fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        const SizedBox(width: 130, child: Text('Trigger key')),
                        Expanded(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: s.shutterKeybind,
                            onChanged: (v) => _run(() => c.setShutterConfig(keybind: v),
                                'Shutter settings updated.'),
                            items: kShutterKeybinds
                                .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                                .toList(),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const SizedBox(width: 130, child: Text('Phone action')),
                        Expanded(
                          child: DropdownButton<String>(
                            isExpanded: true,
                            value: s.shutterMethod,
                            onChanged: (v) => _run(
                                () => c.setShutterConfig(method: v), 'Shutter settings updated.'),
                            items: const [
                              DropdownMenuItem(value: 'tap', child: Text('Tap shutter (recommended)')),
                              DropdownMenuItem(value: 'camera', child: Text('Camera key')),
                              DropdownMenuItem(value: 'volumeDown', child: Text('Volume Down')),
                              DropdownMenuItem(value: 'volumeUp', child: Text('Volume Up')),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (s.shutterMethod == 'tap') ...[
                      const SizedBox(height: 8),
                      Text(
                        'Tap position (% of phone screen — bottom-centre is typical):',
                        style: TextStyle(
                            fontSize: 12, color: Theme.of(context).colorScheme.onSurfaceVariant),
                      ),
                      Row(
                        children: [
                          Expanded(
                              child: _percentField(context, 'X %', s.shutterTapXPercent,
                                  (v) => c.setShutterConfig(tapXPercent: v))),
                          const SizedBox(width: 12),
                          Expanded(
                              child: _percentField(context, 'Y %', s.shutterTapYPercent,
                                  (v) => c.setShutterConfig(tapYPercent: v))),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            const Text('Passwords', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.vpn_key_outlined),
                    title: const Text('Default temporary password'),
                    subtitle: Text(s.defaultTempPasswordHash == null
                        ? 'Not set — required before creating users.'
                        : 'Set (not viewable — reset a user to hand out a fresh one).'),
                    trailing: TextButton(
                      onPressed: () => _setDefaultTempDialog(context, c),
                      child: const Text('Change'),
                    ),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: const Icon(Icons.lock_outline),
                    title: const Text('SuperAdmin password'),
                    subtitle: Text(s.superAdminPasswordHash == null
                        ? 'Using the factory password.'
                        : 'Overridden for this installation.'),
                    trailing: TextButton(
                      onPressed: () => _setSuperAdminPasswordDialog(context, c),
                      child: const Text('Change'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _percentField(
      BuildContext context, String label, double value, Future<void> Function(double) onSet) {
    return TextFormField(
      key: ValueKey('$label-${value.toStringAsFixed(0)}'),
      initialValue: value.toStringAsFixed(0),
      keyboardType: TextInputType.number,
      decoration: InputDecoration(labelText: label, isDense: true),
      onFieldSubmitted: (raw) {
        final v = double.tryParse(raw.trim());
        if (v == null || v < 0 || v > 100) {
          showAppSnackBar('Invalid', 'Enter a percentage 0–100.',
              backgroundColor: Get.theme.colorScheme.error, colorText: Get.theme.colorScheme.onError);
          return;
        }
        _run(() => onSet(v), 'Shutter settings updated.');
      },
    );
  }

  void _run(Future<void> Function() action, String successMsg) {
    action().then((_) {
      showAppSnackBar('Saved', successMsg, duration: const Duration(seconds: 2));
    }).catchError((e) {
      showAppSnackBar('Error', '$e',
          backgroundColor: Get.theme.colorScheme.error, colorText: Get.theme.colorScheme.onError);
    });
  }

  Future<void> _setDefaultTempDialog(BuildContext context, AppSettingsController c) async {
    final ctl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('Default temporary password'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('New and reset accounts start with this password.',
                    style: TextStyle(color: Get.theme.colorScheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                TextField(controller: ctl, decoration: const InputDecoration(labelText: 'Temporary password')),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: TextStyle(color: Get.theme.colorScheme.error)),
                ],
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  if (ctl.text.length < 8) {
                    setState(() => error = 'Must be at least 8 characters.');
                    return;
                  }
                  Navigator.of(ctx).pop(true);
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
    if (ok != true) return;
    try {
      await c.setDefaultTempPassword(ctl.text);
      showAppSnackBar('Saved', 'Default temporary password updated.',
          backgroundColor: Get.theme.extension<LifewoodColors>()!.success,
          colorText: Get.theme.extension<LifewoodColors>()!.onSuccess);
    } catch (e) {
      showAppSnackBar('Error', '$e',
          backgroundColor: Get.theme.colorScheme.error, colorText: Get.theme.colorScheme.onError);
    }
  }

  Future<void> _setSuperAdminPasswordDialog(BuildContext context, AppSettingsController c) async {
    final passCtl = TextEditingController();
    final confirmCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('Change SuperAdmin password'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This overrides the factory password for this installation. A '
                  'PostgreSQL outage that also wipes the local snapshot reverts to the '
                  'factory password.',
                  style: TextStyle(color: Get.theme.colorScheme.onSurfaceVariant, fontSize: 12),
                ),
                const SizedBox(height: 12),
                TextField(
                    controller: passCtl,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'New password')),
                const SizedBox(height: 8),
                TextField(
                    controller: confirmCtl,
                    obscureText: true,
                    decoration: const InputDecoration(labelText: 'Confirm new password')),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(error!, style: TextStyle(color: Get.theme.colorScheme.error)),
                ],
              ],
            ),
            actions: [
              TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
              ElevatedButton(
                onPressed: () {
                  if (passCtl.text.length < 8) {
                    setState(() => error = 'Must be at least 8 characters.');
                    return;
                  }
                  if (passCtl.text != confirmCtl.text) {
                    setState(() => error = 'Passwords do not match.');
                    return;
                  }
                  Navigator.of(ctx).pop(true);
                },
                child: const Text('Save'),
              ),
            ],
          ),
        );
      },
    );
    if (ok != true) return;
    try {
      await c.setSuperAdminPassword(passCtl.text);
      showAppSnackBar('Saved', 'SuperAdmin password updated.',
          backgroundColor: Get.theme.extension<LifewoodColors>()!.success,
          colorText: Get.theme.extension<LifewoodColors>()!.onSuccess);
    } catch (e) {
      showAppSnackBar('Error', '$e',
          backgroundColor: Get.theme.colorScheme.error, colorText: Get.theme.colorScheme.onError);
    }
  }
}
