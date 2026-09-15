import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../services/admin_store_service.dart';
import '../services/device_registry.dart';
import '../services/snackbar_service.dart';
import '../theme/app_colors.dart';

/// Which project each capture device is bound to, who last used it,
/// and a Reassign action — the only way to move a device to another project
/// (LWCAM's login gate blocks cross-project entry). Reads/writes PostgreSQL
/// directly, so it requires sync to be configured and reachable.
class DevicesPage extends StatefulWidget {
  const DevicesPage({super.key});

  @override
  State<DevicesPage> createState() => _DevicesPageState();
}

class _DevicesPageState extends State<DevicesPage> {
  final _registry = DeviceRegistry();
  late Future<List<DeviceRow>> _future;

  @override
  void initState() {
    super.initState();
    _future = _registry.listDevices();
  }

  void _reload() => setState(() => _future = _registry.listDevices());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Devices'),
        actions: [
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _reload),
        ],
      ),
      body: FutureBuilder<List<DeviceRow>>(
        future: _future,
        builder: (context, snap) {
          if (snap.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text('${snap.error}', textAlign: TextAlign.center),
              ),
            );
          }
          final rows = snap.data ?? const <DeviceRow>[];
          if (rows.isEmpty) {
            return const Center(
              child: Text('No devices registered yet — a device appears here '
                  'the first time a capture user enters a project.'),
            );
          }
          return ListView(
            padding: const EdgeInsets.only(top: 8, bottom: 24),
            children: [for (final d in rows) _deviceTile(context, d)],
          );
        },
      ),
    );
  }

  Widget _deviceTile(BuildContext context, DeviceRow d) {
    final loginText = d.loginAt == null ? 'never' : '${d.loginAt!.toLocal()}'.split('.').first;
    final project =
        d.projectName == null ? d.countryLocationCode : '${d.projectName} (${d.countryLocationCode})';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: const CircleAvatar(child: Icon(Icons.devices_other)),
        title: Text(d.deviceId, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('Project: $project\n'
              'Last user: ${d.lastUser ?? '—'}  ·  Last login: $loginText'),
        ),
        isThreeLine: true,
        trailing: TextButton.icon(
          icon: const Icon(Icons.swap_horiz),
          label: const Text('Reassign'),
          onPressed: () => _reassign(context, d),
        ),
      ),
    );
  }

  Future<void> _reassign(BuildContext context, DeviceRow d) async {
    final projects = Get.isRegistered<AdminStoreService>()
        ? Get.find<AdminStoreService>().store.value?.projects ?? const []
        : const [];
    final candidates =
        projects.where((p) => (p.countryLocationCode ?? '').trim().isNotEmpty).toList();
    if (candidates.isEmpty) {
      showAppSnackBar('No projects', 'No project has a location code yet.',
          backgroundColor: Get.theme.colorScheme.error,
          colorText: Get.theme.colorScheme.onError,
          width: kCompactSnackBarWidth);
      return;
    }

    String? selectedCode = candidates
        .firstWhereOrNull((p) => p.countryLocationCode == d.countryLocationCode)
        ?.countryLocationCode;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          title: Text('Reassign ${d.deviceId}'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Bind this device to:'),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: selectedCode,
                items: [
                  for (final p in candidates)
                    DropdownMenuItem(
                      value: p.countryLocationCode,
                      child: Text('${p.name} (${p.countryLocationCode})'),
                    ),
                ],
                onChanged: (v) => setState(() => selectedCode = v),
                decoration: const InputDecoration(labelText: 'Project'),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.of(ctx).pop(false), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: selectedCode == null ? null : () => Navigator.of(ctx).pop(true),
              child: const Text('Reassign'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || selectedCode == null) return;

    try {
      await _registry.reassign(deviceId: d.deviceId, countryLocationCode: selectedCode!);
      showAppSnackBar('Reassigned', '${d.deviceId} moved to $selectedCode.',
          backgroundColor: Get.theme.extension<LifewoodColors>()!.success,
          colorText: Get.theme.extension<LifewoodColors>()!.onSuccess,
          width: kCompactSnackBarWidth);
      _reload();
    } catch (e) {
      showAppSnackBar('Error', '$e',
          backgroundColor: Get.theme.colorScheme.error,
          colorText: Get.theme.colorScheme.onError,
          width: kCompactSnackBarWidth);
    }
  }
}
