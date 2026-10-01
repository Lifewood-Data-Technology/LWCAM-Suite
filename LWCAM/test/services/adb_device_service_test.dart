import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/adb_device_service.dart';

void main() {
  test('isSafeDeviceName accepts plain camera file names', () {
    for (final n in ['IMG_0001.jpg', 'PXL_20260930_101010.MP.jpg', 'a b.jpg']) {
      expect(AdbDeviceService.isSafeDeviceName(n), isTrue, reason: n);
    }
  });

  test('isSafeDeviceName refuses separators, .., drives and control chars', () {
    for (final n in [
      '',
      '..',
      '../x.jpg',
      r'..\x.jpg',
      'sub/x.jpg',
      r'sub\x.jpg',
      'C:x.jpg',
      'x.jpg:s',
      'a\u0000b.jpg',
      'a\nb.jpg',
      'a..b.jpg',
    ]) {
      expect(AdbDeviceService.isSafeDeviceName(n), isFalse, reason: n);
    }
  });

  test('resolveAdbPath never falls back to PATH, cwd or the Android folder', () {
    final path = AdbDeviceService.resolveAdbPath();
    expect(path.toLowerCase(), endsWith('adb.exe'));
    expect(path, isNot('adb'));
    expect(path.toLowerCase(), isNot(contains(r'c:\android')));
  });
}
