import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../controllers/station_setup_controller.dart';
import '../services/snackbar_service.dart';

/// Section headers — larger + bold so the distinct phases in Station Setup
/// read as clearly separated blocks.
const TextStyle _sectionTitleStyle = TextStyle(
  fontSize: 18,
  fontWeight: FontWeight.bold,
);

/// This machine's PostgreSQL connection + local snapshot path. Saving here
/// (re)provisions `lwcam_node_config.json` and immediately re-registers
/// AdminStoreService against it — no restart needed, and this is exactly
/// what a portable copy of this app running on a fresh capture PC uses to
/// bootstrap it before LWCAM has ever logged in.
class StationSetupPage extends StatefulWidget {
  const StationSetupPage({super.key});

  @override
  State<StationSetupPage> createState() => _StationSetupPageState();
}

class _StationSetupPageState extends State<StationSetupPage> {
  late final StationSetupController _c;

  // Picker-paired fields need REAL controllers: a plain
  // initialValue field keeps its own internal text state, so a path set
  // programmatically by the folder picker after the first build would
  // update the Rx but never render. Created lazily on the first
  // post-load build (the form is gated behind isLoaded, so the Rx hold
  // the saved config by then).
  TextEditingController? _destCtl;
  TextEditingController? _storeCtl;
  TextEditingController? _procInputCtl;
  TextEditingController? _procOutputCtl;

  @override
  void initState() {
    super.initState();
    _c = Get.isRegistered<StationSetupController>()
        ? Get.find<StationSetupController>()
        : Get.put(StationSetupController());
    // force: every page open re-reads from disk (LWCAM may have rewritten
    // the shared file); mid-visit typing is safe — this only runs in
    // initState, never on rebuilds.
    _c.ensureLoaded(force: true);
  }

  @override
  void dispose() {
    _destCtl?.dispose();
    _storeCtl?.dispose();
    _procInputCtl?.dispose();
    _procOutputCtl?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Station Setup')),
      body: Obx(() {
        // The form's TextFormFields use initialValue with stable keys, so
        // they must not build until the saved config is in the Rx fields —
        // building early would permanently show blank/default values.
        if (!_c.isLoaded.value) {
          return const Center(child: CircularProgressIndicator());
        }
        _destCtl ??= TextEditingController(text: _c.destinationPath.value);
        _storeCtl ??= TextEditingController(text: _c.usersStorePath.value);
        _procInputCtl ??= TextEditingController(
          text: _c.processingInputRoot.value,
        );
        _procOutputCtl ??= TextEditingController(
          text: _c.processingOutputRoot.value,
        );
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text('PostgreSQL connection', style: _sectionTitleStyle),
            const SizedBox(height: 4),
            Text(
              'Configures PostgreSQL for THIS machine only. LWCAM installed on '
              'the same PC reads this same file.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Enable connection'),
              subtitle: const Text(
                'Off keeps the credentials below but stops connection attempts '
                '— edits queue locally, same as if PG were unreachable. For a '
                'permanently-offline site, or to test offline behavior.',
              ),
              value: _c.pgConnectionEnabled.value,
              onChanged: (v) => _c.pgConnectionEnabled.value = v,
            ),
            _textField('Host', _c.pgHost.value, (v) => _c.pgHost.value = v),
            Row(
              children: [
                Expanded(
                  child: _textField(
                    'Port',
                    _c.pgPort.value.toString(),
                    (v) => _c.pgPort.value = int.tryParse(v) ?? _c.pgPort.value,
                    keyboardType: TextInputType.number,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _textField(
                    'Database',
                    _c.pgDatabase.value,
                    (v) => _c.pgDatabase.value = v,
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: _textField(
                    'User',
                    _c.pgUser.value,
                    (v) => _c.pgUser.value = v,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _textField(
                    'Password',
                    _c.pgPassword.value,
                    (v) => _c.pgPassword.value = v,
                    obscure: true,
                  ),
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Use SSL'),
              value: _c.pgUseSsl.value,
              onChanged: (v) => _c.pgUseSsl.value = v,
            ),
            const SizedBox(height: 16),
            _textField(
              'Sync interval (seconds)',
              _c.syncIntervalSeconds.value.toString(),
              (v) => _c.syncIntervalSeconds.value =
                  int.tryParse(v) ?? _c.syncIntervalSeconds.value,
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 12),
            // Belongs with the PostgreSQL setup above — a one-off reachability
            // check against whatever is typed in (doesn't require saving).
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () async {
                  try {
                    await _c.testConnection();
                    showAppSnackBar(
                      'Connected',
                      'Successfully reached the PostgreSQL host.',
                      duration: const Duration(seconds: 2),
                    );
                  } catch (e) {
                    showAppSnackBar(
                      'Connection failed',
                      '$e',
                      backgroundColor: Get.theme.colorScheme.error,
                      colorText: Get.theme.colorScheme.onError,
                    );
                  }
                },
                icon: const Icon(Icons.wifi_tethering, size: 18),
                label: const Text('Test connection'),
              ),
            ),
            const SizedBox(height: 8),
            // Changes the password on the SERVER. The Password box above only
            // holds the credential this app connects with, so editing it alone
            // breaks the connection instead of rotating anything.
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => _rotatePgPasswordDialog(context),
                icon: const Icon(Icons.key, size: 18),
                label: const Text('Change password on server'),
              ),
            ),
            const SizedBox(height: 24),
            const Text('Local snapshot path', style: _sectionTitleStyle),
            const SizedBox(height: 4),
            Text(
              'Where lwcam_users.json lives on this machine. Leave blank for the '
              'default (%USERPROFILE%\\LWCAM_DBs). Only override this for a fully '
              'offline multi-station site sharing one local/network folder — '
              'several LWCAM installs may read the same file, but only this app '
              'should ever write to it.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _controllerField(
                    'Snapshot directory (optional)',
                    _storeCtl!,
                    (v) => _c.usersStorePath.value = v,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Choose folder',
                  icon: const Icon(Icons.folder_open),
                  onPressed: () async {
                    final path = await FilePicker.platform.getDirectoryPath(
                      dialogTitle: 'Select the local snapshot folder',
                    );
                    if (path != null) {
                      _storeCtl!.text = path;
                      _c.usersStorePath.value = path;
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text('LWCAM capture station', style: _sectionTitleStyle),
            const SizedBox(height: 4),
            Text(
              'Settings for the LWCAM app on this PC — configured only here '
              '(LWCAM itself has no Settings screen).',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: _controllerField(
                    'Image destination folder',
                    _destCtl!,
                    (v) => _c.destinationPath.value = v,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Choose folder',
                  icon: const Icon(Icons.folder_open),
                  onPressed: () async {
                    final path = await FilePicker.platform.getDirectoryPath(
                      dialogTitle: 'Select the image destination folder',
                    );
                    if (path != null) {
                      _destCtl!.text = path;
                      _c.destinationPath.value = path;
                    }
                  },
                ),
              ],
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Capture-data sync (LWCAM outbox)'),
              subtitle: const Text(
                'Whether LWCAM drains its captured groups/folders/images to '
                'PostgreSQL. Separate from this app\'s own connection above.',
              ),
              value: _c.lwcamSyncEnabled.value,
              onChanged: (v) => _c.lwcamSyncEnabled.value = v,
            ),
            const SizedBox(height: 24),
            const Text('Image processing (LWIP)', style: _sectionTitleStyle),
            const SizedBox(height: 4),
            Text(
              'When on, the deskew/crop/thumbnail watcher runs in the background '
              'on this PC and starts again at every logon — it no longer needs '
              'LWCAM to be open. Saving starts it immediately. Leave the folders '
              'blank on a same-PC station (input defaults to the destination '
              'above, output to a sibling "…_processed"). For a separate '
              'processing PC, point the input at the shared destination using a '
              'UNC path (\\\\PC\\share) and enable Capture-data sync so results '
              'reach the cloud.',
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Run image processing on this PC'),
              value: _c.processingEnabled.value,
              onChanged: (v) => _c.processingEnabled.value = v,
            ),
            // Processing that silently is not running is the failure nobody
            // notices until a day of captures has piled up unprocessed.
            if (_c.lwipAutostartWarning.value.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _c.lwipAutostartWarning.value,
                        style: TextStyle(
                          fontSize: 12,
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Expanded(
                  child: _controllerField(
                    'Processing input folder (blank = destination)',
                    _procInputCtl!,
                    (v) => _c.processingInputRoot.value = v,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Choose folder',
                  icon: const Icon(Icons.folder_open),
                  onPressed: () async {
                    final path = await FilePicker.platform.getDirectoryPath(
                      dialogTitle: 'Select the processing input folder',
                    );
                    if (path != null) {
                      _procInputCtl!.text = path;
                      _c.processingInputRoot.value = path;
                    }
                  },
                ),
              ],
            ),
            Row(
              children: [
                Expanded(
                  child: _controllerField(
                    'Processing output folder (blank = <input>_processed)',
                    _procOutputCtl!,
                    (v) => _c.processingOutputRoot.value = v,
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: 'Choose folder',
                  icon: const Icon(Icons.folder_open),
                  onPressed: () async {
                    final path = await FilePicker.platform.getDirectoryPath(
                      dialogTitle: 'Select the processing output folder',
                    );
                    if (path != null) {
                      _procOutputCtl!.text = path;
                      _c.processingOutputRoot.value = path;
                    }
                  },
                ),
              ],
            ),
            _textField(
              'Processing workers (0 = auto)',
              _c.processingWorkers.value.toString(),
              (v) => _c.processingWorkers.value =
                  int.tryParse(v) ?? _c.processingWorkers.value,
              keyboardType: TextInputType.number,
            ),
            _textField(
              'Crop padding (pixels kept on each side, 0 = crop tight)',
              _c.processingCropPadding.value.toString(),
              (v) => _c.processingCropPadding.value =
                  int.tryParse(v) ?? _c.processingCropPadding.value,
              keyboardType: TextInputType.number,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: const Text('Report finished folders to the database'),
              subtitle: const Text(
                'Makes finished folders available to the database while LWCAM '
                'is closed. Leave this on when the station has a database connection.',
              ),
              value: _c.processingCloudReport.value,
              onChanged: (v) => _c.processingCloudReport.value = v,
            ),
            const SizedBox(height: 24),
            // First run: setup left a connection behind and this screen used it to
            // provision the station. Only failures are reported - success needs no
            // banner, since the filled-in settings above are the proof.
            if (_c.isProvisioning.value)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: const [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Setting this station up automatically...',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
            if (_c.firstRunStatus.value.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Theme.of(
                      context,
                    ).colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.warning_amber_rounded,
                        size: 16,
                        color: Theme.of(context).colorScheme.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _c.firstRunStatus.value,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 24),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FilledButton(
                  onPressed: () async {
                    try {
                      final databaseReady = await _c.save();
                      showAppSnackBar(
                        'Saved',
                        databaseReady
                            ? 'Station settings updated and the database is ready.'
                            : 'Station settings updated.',
                        duration: const Duration(seconds: 2),
                      );
                    } catch (e) {
                      showAppSnackBar(
                        'Error',
                        '$e',
                        backgroundColor: Get.theme.colorScheme.error,
                        colorText: Get.theme.colorScheme.onError,
                      );
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        );
      }),
    );
  }

  /// Rotates the PostgreSQL password on the server and saves it here, which
  /// is the only way to change it that leaves this station able to connect.
  /// The installer generates a random password for a freshly installed server,
  /// so this is how an operator replaces it with one of their own.
  Future<void> _rotatePgPasswordDialog(BuildContext context) async {
    final passCtl = TextEditingController();
    final confirmCtl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        String? error;
        return StatefulBuilder(
          builder: (ctx, setState) => AlertDialog(
            title: const Text('Change password on server'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Changes the password of the "${_c.pgUser.value}" account in '
                  'PostgreSQL itself, then saves it here. The current password '
                  'above is used to authenticate the change.',
                  style: TextStyle(
                    color: Get.theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: passCtl,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'New password'),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: confirmCtl,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Confirm new password',
                  ),
                ),
                if (error != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    error!,
                    style: TextStyle(color: Get.theme.colorScheme.error),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () {
                  if (passCtl.text.length < 8) {
                    setState(() => error = 'Must be at least 8 characters.');
                    return;
                  }
                  if (passCtl.text != confirmCtl.text) {
                    setState(() => error = 'The two passwords do not match.');
                    return;
                  }
                  Navigator.of(ctx).pop(true);
                },
                child: const Text('Change'),
              ),
            ],
          ),
        );
      },
    );
    if (ok != true) return;
    try {
      await _c.rotatePgPassword(passCtl.text);
      showAppSnackBar(
        'Password changed',
        'PostgreSQL and this station now use the new password.',
      );
    } catch (e) {
      showAppSnackBar(
        'Change failed',
        '$e',
        backgroundColor: Get.theme.colorScheme.error,
        colorText: Get.theme.colorScheme.onError,
      );
    }
  }

  /// A controller-backed path field lets a folder picker update the displayed
  /// value after the initial build.
  Widget _controllerField(
    String label,
    TextEditingController controller,
    ValueChanged<String> onChanged, {
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextFormField(
        key: ValueKey('station-$label'),
        controller: controller,
        enabled: enabled,
        decoration: InputDecoration(labelText: label, isDense: true),
        onChanged: onChanged,
      ),
    );
  }

  /// A per-build TextEditingController is intentional — these fields live
  /// inside an Obx that only rebuilds on the specific Rx values read in its
  /// builder, so a persistent controller would fight the rebuilt
  /// initialValue.
  Widget _textField(
    String label,
    String value,
    ValueChanged<String> onChanged, {
    bool obscure = false,
    TextInputType? keyboardType,
    bool enabled = true,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextFormField(
        key: ValueKey('station-$label'),
        initialValue: value,
        enabled: enabled,
        obscureText: obscure,
        keyboardType: keyboardType,
        decoration: InputDecoration(labelText: label, isDense: true),
        onChanged: onChanged,
      ),
    );
  }
}
