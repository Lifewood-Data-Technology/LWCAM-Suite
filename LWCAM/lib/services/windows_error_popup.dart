// ignore_for_file: avoid_print

import 'dart:io';

/// The PowerShell invocation for the fatal-error pop-up. The message travels in
/// an environment variable and is never spliced into the command text, so
/// quotes of any kind (PowerShell also ends strings at curly quotes) cannot
/// break out of it.
({String executable, List<String> arguments, Map<String, String> environment})
    buildErrorPopupCommand(String message, {Map<String, String>? platformEnv}) {
  final env = platformEnv ?? Platform.environment;
  final root = env['SystemRoot'] ?? env['SYSTEMROOT'] ?? r'C:\Windows';
  return (
    executable: root + r'\System32\WindowsPowerShell\v1.0\powershell.exe',
    arguments: const [
      '-NoProfile',
      '-Command',
      'Add-Type -AssemblyName PresentationFramework; '
          r"[System.Windows.MessageBox]::Show($env:LWCAM_ERROR_TEXT, "
          "'LWCAM Error', 'OK', 'Error')",
    ],
    environment: {'LWCAM_ERROR_TEXT': message},
  );
}

Future<void> showWindowsErrorPopup(String message) async {
  try {
    final c = buildErrorPopupCommand(message);
    await Process.run(c.executable, c.arguments, environment: c.environment);
  } catch (e) {
    print('Failed to show Windows popup: $e');
  }
}
