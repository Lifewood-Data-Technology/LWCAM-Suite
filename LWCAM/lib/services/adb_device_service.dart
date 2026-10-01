// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// How the PC-side trigger fires the phone camera shutter over ADB. Built
/// from SharedAppSettings (admin-configured).
class ShutterConfig {
  /// One of: 'tap' | 'camera' | 'volumeDown' | 'volumeUp'.
  final String method;

  /// For 'tap': shutter position as a percentage of the phone screen (0–100).
  final double tapXPercent;
  final double tapYPercent;

  const ShutterConfig({
    this.method = 'tap',
    this.tapXPercent = 50,
    this.tapYPercent = 90,
  });
}

/// ADB device plumbing for Box Mode (`box_session_controller.dart`,
/// `box_transfer_flow.dart`), extracted-by-copy from `gallery_page.dart`
/// (`_resolveAdbPath`, `_listDeviceImageNames`, `_pullSingleFile`).
/// Deliberately a separate copy rather than a shared extraction:
/// gallery_page.dart is the app's highest-risk file for Normal Mode
/// regressions, so it is never modified for this feature.
///
/// Each instance tracks its own resolved DCIM working path, mirroring the
/// per-GalleryPage-instance state in gallery_page.dart — safe because
/// Normal Mode's GalleryPage and Box Mode's capture screen are never
/// mounted at the same time.
class AdbDeviceService {
  final String adbPath;
  String? _workingPath;

  AdbDeviceService({String? adbPath}) : adbPath = adbPath ?? resolveAdbPath();

  /// Only the adb the installer ships: beside this exe, else the install dir
  /// under %ProgramFiles%. Never the working directory, C:\Android or PATH -
  /// those are user-writable / plantable locations.
  static String resolveAdbPath() {
    final exeDir = File(Platform.resolvedExecutable).parent.path;
    final pf = Platform.environment['ProgramFiles'];
    final candidates = <String>[
      p.join(exeDir, 'adb.exe'),
      if (pf != null && pf.isNotEmpty) p.join(pf, 'LWCam', 'LWCAM', 'adb.exe'),
    ];
    for (final candidate in candidates) {
      if (File(candidate).existsSync()) {
        print('✅ Using adb at: $candidate');
        return candidate;
      }
    }
    // Not found: return the expected path so the failure names it.
    return candidates.first;
  }

  /// A device file name that is safe to join onto a local folder and a remote
  /// path: a plain name, no separators, `..`, `:` or control characters.
  static bool isSafeDeviceName(String name) =>
      name.isNotEmpty &&
      name == p.basename(name) &&
      !name.contains(RegExp(r'[\\/:\x00-\x1f]')) &&
      !name.contains('..');

  /// Stops the background adb server this app started.
  ///
  /// adb is a client/server pair: the first adb command silently forks a
  /// long-lived daemon (`adb -L tcp:5037 fork-server server`) and every later
  /// command talks to it. That daemon is deliberately designed to OUTLIVE its
  /// clients, so closing LWCAM left it running until the operator rebooted -
  /// holding the USB interface and keeping the phone claimed.
  ///
  /// Bounded and never throws: this runs on the app's way out, where nothing is
  /// allowed to delay process exit. A failure here costs a stray daemon, which
  /// is exactly the status quo it improves on.
  ///
  /// Note it stops the machine-wide server, not "our" server - there is only
  /// one per host. On a capture station that is the point. On a developer
  /// machine it also disconnects other adb tooling, which is the tradeoff.
  Future<void> killServer() async {
    try {
      await Process.run(adbPath, [
        'kill-server',
      ]).timeout(const Duration(seconds: 5));
      print('🔌 adb server stopped.');
    } catch (e) {
      print('adb kill-server skipped: $e');
    }
  }

  /// Lists the device's DCIM image filenames. Returns null when the device
  /// could not be listed at all (adb failure / phone disconnected / no DCIM
  /// path found) — deliberately distinct from an empty list, which means the
  /// folder exists and simply has no images. Callers taking a baseline
  /// snapshot (RW-14) MUST treat null as "do not snapshot": persisting a
  /// failure as an empty baseline would later mis-claim the phone's entire
  /// gallery into one task.
  Future<List<String>?> listDeviceImageNames() async {
    final possiblePaths = [
      _workingPath,
      '/storage/emulated/0/DCIM/Camera',
      '/sdcard/DCIM/Camera',
    ].whereType<String>().toList();

    for (final path in possiblePaths) {
      try {
        final result = await Process.run(adbPath, ['shell', 'ls', '-1', path]);
        if (result.exitCode != 0) {
          continue;
        }
        final output = result.stdout.toString().trim();
        if (output.contains('No such file')) {
          continue;
        }

        // ls succeeded on an existing folder — possibly with no images.
        _workingPath = path;
        return output
            .split('\n')
            .map((f) => f.trim().replaceAll('\r', ''))
            .where((f) => f.isNotEmpty)
            .where((f) {
              final name = f.toLowerCase();
              return name.endsWith('.jpg') ||
                  name.endsWith('.jpeg') ||
                  name.endsWith('.png') ||
                  name.endsWith('.heic') ||
                  name.endsWith('.heif') ||
                  name.endsWith('.webp');
            })
            .toList();
      } catch (e) {
        print('⚠️ Failed listing device images from $path: $e');
      }
    }

    return null;
  }

  /// Image name → size in bytes from a single `ls -l` of the working DCIM
  /// path. Null when the device/dir is unreachable; entries whose lines can't
  /// be parsed are simply omitted (callers treat absence as "size unknown").
  Future<Map<String, int>?> listDeviceImageSizes() async {
    if ((_workingPath ?? '').isEmpty) {
      await listDeviceImageNames(); // resolves _workingPath as a side effect
      if ((_workingPath ?? '').isEmpty) return null;
    }
    try {
      final result = await Process.run(adbPath, ['shell', 'ls', '-l', _workingPath!]);
      if (result.exitCode != 0) return null;
      final sizes = <String, int>{};
      for (final rawLine in result.stdout.toString().split('\n')) {
        final line = rawLine.trim().replaceAll('\r', '');
        if (line.isEmpty || line.startsWith('total')) continue;
        // toybox ls -l: perms links owner group SIZE date time NAME...
        final tokens = line.split(RegExp(r'\s+'));
        if (tokens.length < 8) continue;
        final size = int.tryParse(tokens[4]);
        if (size == null) continue;
        final name = tokens.sublist(7).join(' ');
        if (name.isNotEmpty) sizes[name] = size;
      }
      return sizes;
    } catch (e) {
      print('⚠️ Failed listing device image sizes: $e');
      return null;
    }
  }

  Future<File?> pullSingleFile(String name, {required Directory targetDir}) async {
    if (!isSafeDeviceName(name)) {
      print('⚠️ Refusing to pull unsafe device file name: $name');
      return null;
    }
    if ((_workingPath ?? '').isEmpty) {
      await listDeviceImageNames(); // resolves _workingPath as a side effect
      if ((_workingPath ?? '').isEmpty) {
        return null;
      }
    }

    final localPath = p.join(targetDir.path, name);
    final remoteFile = '$_workingPath/$name';

    try {
      final pull = await Process.run(adbPath, ['pull', remoteFile, localPath]);
      if (pull.exitCode != 0) {
        print('⚠️ adb pull failed for $name: ${pull.stderr}');
        return null;
      }

      final file = File(localPath);
      if (!file.existsSync()) {
        print('⚠️ Pulled file missing locally: $localPath');
        return null;
      }
      return file;
    } catch (e) {
      print('⚠️ Failed to pull file $name: $e');
      return null;
    }
  }

  ({int w, int h})? _deviceSize;

  /// Physical/effective device resolution (prefers the Override size), cached.
  /// Null if it can't be read.
  Future<({int w, int h})?> _resolveDeviceSize() async {
    if (_deviceSize != null) return _deviceSize;
    try {
      final res = await Process.run(adbPath, ['shell', 'wm', 'size']);
      if (res.exitCode != 0) return null;
      final matches = RegExp(r'(?:Override|Physical) size:\s*(\d+)x(\d+)')
          .allMatches(res.stdout.toString())
          .toList();
      if (matches.isEmpty) return null;
      final m = matches.last; // Override (if present) is listed after Physical
      _deviceSize = (w: int.parse(m.group(1)!), h: int.parse(m.group(2)!));
      return _deviceSize;
    } catch (e) {
      print('⚠️ wm size query failed: $e');
      return null;
    }
  }

  /// Fires the phone camera shutter per [cfg]. Returns true on a successful
  /// adb command. Never throws — a failed shutter must not crash capture.
  /// The camera app must be foreground on the phone (it is, during capture).
  Future<bool> triggerShutter(ShutterConfig cfg) async {
    try {
      if (cfg.method != 'camera' &&
          cfg.method != 'volumeDown' &&
          cfg.method != 'volumeUp') {
        // 'tap' or any unrecognized method defaults to tap.
        final size = await _resolveDeviceSize();
        if (size == null) {
          print('⚠️ Shutter tap: device size unknown.');
          return false;
        }
        final x = (size.w * cfg.tapXPercent / 100).round().clamp(0, size.w);
        final y = (size.h * cfg.tapYPercent / 100).round().clamp(0, size.h);
        final ok = await tapDevicePixels(x, y);
        if (ok) print('📸 Shutter fired (tap): adb shell input tap $x $y');
        return ok;
      }

      final args = switch (cfg.method) {
        'camera' => ['shell', 'input', 'keyevent', '27'], // KEYCODE_CAMERA
        'volumeDown' => ['shell', 'input', 'keyevent', '25'],
        _ => ['shell', 'input', 'keyevent', '24'], // volumeUp
      };
      final result = await Process.run(adbPath, args);
      if (result.exitCode != 0) {
        print('⚠️ Shutter (${cfg.method}) failed: ${result.stderr}');
        return false;
      }
      print('📸 Shutter fired (${cfg.method}): adb ${args.join(' ')}');
      return true;
    } catch (e) {
      print('⚠️ Shutter trigger error: $e');
      return false;
    }
  }

  /// Taps the device screen at absolute device pixel coordinates. Wakes the
  /// screen and, in the camera app, focuses at that point — the tap
  /// primitive underlying the shutter's 'tap' method above. (Box-mode
  /// tap-to-focus is now scrcpy's own native control — see
  /// ScrcpyService's clip-host design — so this is no longer also used
  /// for that.) Never throws.
  Future<bool> tapDevicePixels(int x, int y) async {
    try {
      final result =
          await Process.run(adbPath, ['shell', 'input', 'tap', '$x', '$y']);
      if (result.exitCode != 0) {
        print('⚠️ Tap ($x,$y) failed: ${result.stderr}');
        return false;
      }
      return true;
    } catch (e) {
      print('⚠️ Tap error: $e');
      return false;
    }
  }
}
