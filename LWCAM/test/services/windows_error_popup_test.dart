import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/windows_error_popup.dart';

void main() {
  group('buildErrorPopupCommand', () {
    const nasty = 'it\'s \u2018curly\u2019 \u201Cquotes\u201D \$(calc) `x` "end"';

    test('the message travels only in the environment, never in the command', () {
      final c = buildErrorPopupCommand(nasty, platformEnv: {'SystemRoot': r'D:\Win'});
      expect(c.environment, {'LWCAM_ERROR_TEXT': nasty});
      final joined = c.arguments.join(' ');
      expect(joined, contains(r'$env:LWCAM_ERROR_TEXT'));
      for (final piece in ['curly', 'quotes', 'calc', 'end"', "it's", '\u2018']) {
        expect(joined, isNot(contains(piece)));
      }
    });

    test('uses the full PowerShell path from SystemRoot, falling back to C:\\Windows', () {
      expect(buildErrorPopupCommand('x', platformEnv: {'SystemRoot': r'D:\Win'}).executable,
          r'D:\Win\System32\WindowsPowerShell\v1.0\powershell.exe');
      expect(buildErrorPopupCommand('x', platformEnv: {}).executable,
          r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe');
    });
  });
}
