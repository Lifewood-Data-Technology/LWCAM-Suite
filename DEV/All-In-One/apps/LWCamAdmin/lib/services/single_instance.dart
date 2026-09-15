// ignore_for_file: avoid_print

import 'dart:io';

/// One instance of this app per Windows account. A second launch is the
/// operator's way of saying "give me a working window", so the NEW process
/// wins: every other process running this same executable under the same
/// user is terminated before the window opens. Processes of other users on
/// the machine are left alone.
///
/// Identical copy in LWCAM (`lib/services/single_instance.dart`); keep them
/// the same.
Future<void> killOtherInstances() async {
  if (!Platform.isWindows) return;
  final exeName = Platform.resolvedExecutable.split(RegExp(r'[\\/]')).last;
  // WMI filters on the name; GetOwner scopes to this account. Stop-Process is
  // per PID, so the current process is excluded before anything is killed.
  final script = "\$me = $pid; "
      "Get-CimInstance Win32_Process -Filter \"Name = '$exeName'\" | ForEach-Object { "
      "if (\$_.ProcessId -ne \$me) { "
      "\$owner = Invoke-CimMethod -InputObject \$_ -MethodName GetOwner; "
      "if (\$owner.User -eq \$env:USERNAME) { "
      "Stop-Process -Id \$_.ProcessId -Force -ErrorAction SilentlyContinue; "
      "Write-Output \$_.ProcessId } } }";
  try {
    final result = await Process.run(
      'powershell',
      ['-NoProfile', '-NonInteractive', '-Command', script],
    ).timeout(const Duration(seconds: 10));
    final killed = result.stdout.toString().trim();
    if (killed.isNotEmpty) {
      print('ℹ️ Closed earlier $exeName instance(s): ${killed.replaceAll('\n', ', ')}');
    }
  } catch (e) {
    print('⚠️ Could not check for other instances: $e');
  }
}
