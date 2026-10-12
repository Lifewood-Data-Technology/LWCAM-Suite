// ignore_for_file: avoid_print

// Phone screen mirror for the capture page in LWCAM: runs scrcpy and embeds its
// window inside the app so the operator sees and controls the phone camera.
// Capture is the first step of the pipeline (capture -> LWIP -> QC -> upload).
// Know before editing: the mirror is a native Win32 child window, so it draws
// above Flutter and ScrcpyPane hides it when another route covers the page. It
// is tied to a kill-on-close job object (win32_job.dart) so it cannot outlive
// the app.

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import 'win32_job.dart';

/// Route observer registered on GetMaterialApp — [ScrcpyPane] uses it to hide
/// the native mirror whenever another route (dialog, form, page) covers the
/// capture page, because a native child window always draws above Flutter.
final RouteObserver<ModalRoute<void>> appRouteObserver =
    RouteObserver<ModalRoute<void>>();

/// EMBEDDED scrcpy screen mirroring: the scrcpy video window is adopted as a
/// Win32 CHILD of the LWCAM window (SetParent) and rendered inside the
/// capture page's left pane ([ScrcpyPane]) — one window that moves, minimizes
/// and closes together. Clicking the mirror still controls the phone.
///
/// Box mode additionally crops to the camera-app region — but NOT via
/// scrcpy's own `--crop`, which crashes (0xc0000094) when combined with
/// being embedded+resized. Instead scrcpy runs full-frame (identically to
/// legacy: control retained, --stay-awake) and is reparented into a small
/// black clip-host window sized/positioned so only the camera band falls
/// inside it — Win32 clips child rendering to the parent, so the rest of
/// the frame is simply never drawn. See _applyClippedHostRect.
///
/// Lifetime is guaranteed by a Windows Job Object with kill-on-close: the OS
/// terminates scrcpy when LWCAM exits FOR ANY REASON (crash included), so
/// the mirror can never be orphaned again. stop() also kills it explicitly on
/// logout / app close.
///
/// A plain singleton (FileLockService pattern) — must outlive page routes and
/// be reachable from main.dart's window-close handler.
class ScrcpyService {
  ScrcpyService._();
  static final ScrcpyService instance = ScrcpyService._();

  /// Main-window title from main.dart's WindowOptions — used to find the
  /// parent HWND. Must stay in sync if the window title ever changes.
  static const String appWindowTitle = 'LWCAM (Lifewood Capture)';

  /// Box-mode mirror crop, as fractions of the phone screen HEIGHT (full
  /// width). Keeps only the camera-app region — trims the status area at the
  /// very top and the shutter/mode bar at the bottom — so the actual capture
  /// preview fills the pane. These are camera-app/device specific; set
  /// top=0 & bottom=1 to disable cropping. Device-pixel absolute bounds are
  /// derived from the live `wm size` at spawn and consumed CLIENT-SIDE by
  /// the clip-host geometry (see _applyClippedHostRect) — NOT passed to
  /// scrcpy as `--crop`, which crashes when combined with being
  /// embedded+resized (see the CHANGELOG for the diagnosis).
  static const double boxMirrorCropTop = 0.06;
  static const double boxMirrorCropBottom = 0.75;

  /// scrcpy's `--max-size` budget. Box mode streams the FULL frame now (the
  /// clip-host crops client-side), so its budget must be bigger than
  /// legacy's to leave the visible camera band — a fraction of the frame —
  /// at a comparable resolution to before.
  static const int boxMirrorMaxSize = 1440;
  static const int legacyMirrorMaxSize = 1024;

  Process? _process;
  int _childHwnd = 0;

  /// Box mode only: a small black "STATIC" window (child of the main
  /// window) that scrcpy is reparented into instead of the main window
  /// directly. Win32 clips child rendering to the parent's client area, so
  /// sizing/positioning scrcpy's window larger than and offset within this
  /// host is how the camera-region crop is achieved without scrcpy's own
  /// (crashy) `--crop`. 0 when not created (legacy mode, or creation
  /// failed) — see _spawnAndEmbed / _applyClippedHostRect.
  int _hostHwnd = 0;

  int _jobHandle = 0;
  bool _starting = false;

  /// Remembered crop-to-capture-region flag (box mode). Reused on an
  /// idempotent retry; reset on stop().
  bool? _cropCaptureView;

  /// Consecutive times scrcpy died within seconds of a successful embed.
  /// The pane's self-heal stops auto-retrying past a few of these — without
  /// this, embed→crash→re-embed loops forever (each embed used to reset the
  /// retry budget). A manual Retry still works and the streak clears on any
  /// stable run.
  int earlyExitStreak = 0;
  DateTime? _lastEmbedAt;

  /// True while an embedded mirror is live — drives the pane's placeholder.
  final ValueNotifier<bool> running = ValueNotifier<bool>(false);

  /// Aspect ratio (width / height) of the streamed frame after cropping —
  /// lets the layout ASPECT-FIT the mirror pane so the video fills it exactly
  /// (no letterboxing, no oversized native window). Null until known.
  final ValueNotifier<double?> captureAspect = ValueNotifier<double?>(null);

  /// Cached `wm size` result (width, height) so retries don't re-query adb.
  ({int w, int h})? _deviceSize;

  /// Last reported pane rect (PHYSICAL px, relative to the app client area).
  Rect? _paneRect;
  bool _paneVisible = false;

  /// What was last pushed to SetWindowPos — lets updatePaneRect skip the
  /// native call entirely when nothing changed (the pane reports after EVERY
  /// layout pass, which is every page rebuild).
  Rect? _appliedRect;
  bool _appliedVisible = false;
  bool _frameChangePending = true; // SWP_FRAMECHANGED once after adopt

  bool get isRunning => _process != null;

  /// Mirror diagnostics: prints AND appends to
  /// %USERPROFILE%\LWCAM_DBs\scrcpy.log — a release exe has no
  /// console, which made field failures ("mirror doesn't start") completely
  /// opaque. Best-effort; never throws.
  void _log(String line) {
    final stamped = '[${DateTime.now().toIso8601String()}] $line';
    print(stamped);
    try {
      final profile = Platform.environment['USERPROFILE'];
      if (profile == null) return;
      File(p.join(profile, 'LWCAM_DBs', 'scrcpy.log'))
          .writeAsStringSync('$stamped\r\n', mode: FileMode.append);
    } catch (_) {}
  }

  /// Locates scrcpy.exe: a bundled `scrcpy`/`scrcpy-win64-*` folder next to
  /// the app exe (deployed layout), else walking UP from both the exe dir and
  /// the working dir (covers running the raw exe from inside the build tree),
  /// then PATH.
  static String? resolveScrcpyExe() {
    final candidates = <String>[];
    void addDir(String dir) {
      candidates.add(p.join(dir, 'scrcpy', 'scrcpy.exe'));
      try {
        final d = Directory(dir);
        if (d.existsSync()) {
          for (final e in d.listSync()) {
            if (e is Directory &&
                p.basename(e.path).toLowerCase().startsWith('scrcpy')) {
              candidates.add(p.join(e.path, 'scrcpy.exe'));
            }
          }
        }
      } catch (_) {}
    }

    void addDirAndAncestors(String dir) {
      var current = dir;
      for (var i = 0; i < 7; i++) {
        addDir(current);
        final parent = p.dirname(current);
        if (parent == current) break; // drive root reached
        current = parent;
      }
    }

    addDirAndAncestors(p.dirname(Platform.resolvedExecutable));
    addDirAndAncestors(Directory.current.path);

    for (final c in candidates) {
      if (File(c).existsSync()) return c;
    }
    return null; // last resort: rely on PATH via the bare name
  }

  /// Starts scrcpy (idempotent) and embeds its window into LWCAM. Never
  /// throws — mirroring is a convenience, not a requirement. [adbPath] is the
  /// SAME adb.exe the app uses (exported as ADB so scrcpy doesn't restart the
  /// adb server from under the app's live-sync).
  /// [cropCaptureView] controls the box-mode crop: pass a non-null value to
  /// SET it, or null to REUSE the remembered value (the ScrcpyPane retry
  /// path). Only matters on an actual (re)spawn — the idempotent guard skips
  /// it while already running.
  Future<void> ensureStarted({
    required String adbPath,
    bool? cropCaptureView,
  }) async {
    if (cropCaptureView != null) _cropCaptureView = cropCaptureView;
    if (_process != null || _starting) return;
    _starting = true;
    try {
      // A cold adb server / a just-finished manual scrcpy session (whose
      // bundled adb kills our server and vice versa) makes the first spawn(s)
      // die within seconds — retry a few times with backoff instead of
      // making the operator hammer the Retry button.
      for (var attempt = 1; attempt <= 3; attempt++) {
        final ok = await _spawnAndEmbed(adbPath, attempt: attempt);
        if (ok || _process != null) return;
        if (attempt < 3) {
          _log('🪞 scrcpy start attempt $attempt failed — retrying…');
          await Future<void>.delayed(const Duration(milliseconds: 1500));
        }
      }
      _log('⚠️ scrcpy did not start after 3 attempts.');
    } catch (e) {
      _log('⚠️ scrcpy mirroring unavailable: $e');
      _process = null;
      running.value = false;
    } finally {
      _starting = false;
    }
  }

  /// One spawn + embed attempt. Returns true when the mirror is embedded.
  Future<bool> _spawnAndEmbed(String adbPath, {required int attempt}) async {
    final exe = resolveScrcpyExe() ?? 'scrcpy';
    final title = 'LWCAMMirror-$pid-$attempt';

    // Box mode: resolve the crop geometry (device size + camera-band
    // bounds) up front — cached in _deviceSize, published via
    // captureAspect. Consumed CLIENT-SIDE by _applyClippedHostRect, NOT
    // passed to scrcpy: server-side `--crop` crashes when the window is
    // also embedded+resized (see the CHANGELOG for the diagnosis).
    if (_cropCaptureView == true) {
      await _computeCaptureGeometry(adbPath);
    }

    // Borderless and parked far off-screen so nothing flashes on the
    // desktop before the window is adopted; size is irrelevant (the pane
    // dictates it after embedding). Box and legacy now run scrcpy IDENTICALLY
    // (full frame, control retained, stay-awake) — box mode's crop is
    // applied entirely by the clip-host below, never by scrcpy itself.
    final args = <String>[
      '--window-title', title,
      '--window-borderless',
      '--window-x', '-32000',
      '--window-y', '-32000',
      '--window-width', '400',
      '--window-height', '800',
      '--no-audio',
      // Mirror-only stream limits (captured photos stay full-res): without
      // these scrcpy decodes+renders the phone at native res / device fps
      // on the SAME iGPU as Flutter and drags the whole UI down. Box mode
      // gets a bigger budget: it streams the full frame (see the clip-host
      // crop above), so the visible camera band — a fraction of the frame
      // — needs more headroom than legacy's 1024 to look comparable.
      '--max-size',
      (_cropCaptureView == true ? boxMirrorMaxSize : legacyMirrorMaxSize)
          .toString(),
      '--max-fps', '30',
      '--video-bit-rate', '4M',
      '--stay-awake',
    ];

    _log('🪞 Starting scrcpy: $exe ${args.join(' ')}');
    final proc = await Process.start(
      exe,
      args,
      environment: {'ADB': adbPath},
    );
    proc.stdout.listen((_) {});
    // Surface scrcpy's own errors — silence here made "mirror doesn't start"
    // undiagnosable in the field.
    proc.stderr
        .transform(const SystemEncoding().decoder)
        .transform(const LineSplitter())
        .listen((line) {
      if (line.trim().isNotEmpty) _log('🪞 scrcpy: $line');
    });
    _process = proc;

    proc.exitCode.then((code) {
      _log('🪞 scrcpy exited ($code).');
      final embedAt = _lastEmbedAt;
      if (embedAt != null &&
          DateTime.now().difference(embedAt) < const Duration(seconds: 10)) {
        earlyExitStreak++;
        _log('🪞 early exit after embed (streak $earlyExitStreak).');
      } else if (embedAt != null) {
        earlyExitStreak = 0; // it ran stably before dying
      }
      _process = null;
      _childHwnd = 0;
      _destroyHostWindow();
      running.value = false;
      _closeJobHandle();
    });

    // The OS kills everything in this job when the handle dies with the
    // app — scrcpy can never outlive LWCAM.
    _assignToKillOnCloseJob(proc.pid);

    final child =
        await _waitForWindow(title, timeout: const Duration(seconds: 15));
    if (child == 0) {
      _log('⚠️ scrcpy window not found (attempt $attempt).');
      // Kill a possibly-lingering process so the retry starts clean.
      final p = _process;
      _process = null;
      try {
        p?.kill();
      } catch (_) {}
      _closeJobHandle();
      return false;
    }
    if (_process == null) return false; // died while we were waiting

    final parent = FindWindow(nullptr, TEXT(appWindowTitle));
    if (parent == 0) {
      print('⚠️ LWCAM window not found — mirror left unembedded, stopping.');
      await stop();
      return false;
    }

    // Adopt: strip the top-level styles, mark as child.
    final style = GetWindowLongPtr(child, GWL_STYLE);
    SetWindowLongPtr(
      child,
      GWL_STYLE,
      (style & ~WS_POPUP & ~WS_CAPTION & ~WS_THICKFRAME) |
          WS_CHILD |
          WS_CLIPSIBLINGS,
    );

    // Box mode: reparent into a small black clipping host (child of the
    // main window) instead of the main window directly — Win32 clips child
    // rendering to the parent's client area, so sizing/positioning scrcpy's
    // window larger than and offset within the host (done in
    // _applyClippedHostRect, once the pane reports its rect) shows only the
    // camera-region band. This is the crop; scrcpy itself is never asked to
    // crop. Falls back to a direct (uncropped-looking) embed if host
    // creation fails — mirroring must never fail over the crop.
    if (_cropCaptureView == true) {
      _hostHwnd = _createHostWindow(parent);
    }
    if (_hostHwnd != 0) {
      SetParent(child, _hostHwnd);
    } else {
      SetParent(child, parent);
    }

    _childHwnd = child;
    _appliedRect = null;
    _appliedVisible = false;
    _frameChangePending = true;
    _lastEmbedAt = DateTime.now();
    running.value = true;

    if (_paneVisible && _paneRect != null) {
      _applyPaneRect();
    } else {
      ShowWindow(child, SW_HIDE);
      if (_hostHwnd != 0) ShowWindow(_hostHwnd, SW_HIDE);
    }
    _log('🪞 scrcpy embedded (hwnd=$child, parent=$parent, '
        'host=$_hostHwnd).');
    return true;
  }

  /// Creates the box-mode clipping host: a plain black "STATIC" control
  /// (predefined window class — no RegisterClass/WndProc needed;
  /// SS_BLACKRECT paints its client area black, matching the pane's
  /// existing black background) as a child of [parentHwnd]. Returns 0 on
  /// failure (never throws) — callers fall back to a direct, uncropped
  /// embed.
  int _createHostWindow(int parentHwnd) {
    final className = 'STATIC'.toNativeUtf16();
    try {
      final hwnd = CreateWindowEx(
        0,
        className,
        nullptr,
        WS_CHILD | WS_CLIPCHILDREN | WS_CLIPSIBLINGS | SS_BLACKRECT,
        0,
        0,
        1,
        1,
        parentHwnd,
        0,
        GetModuleHandle(nullptr),
        nullptr,
      );
      if (hwnd == 0) _log('⚠️ Mirror clip-host creation failed.');
      return hwnd;
    } catch (e) {
      _log('⚠️ Mirror clip-host creation failed: $e');
      return 0;
    } finally {
      malloc.free(className);
    }
  }

  /// Destroys the box-mode clip-host (if any) — called whenever scrcpy's
  /// process goes away (crash, kill, stop) so a fresh host is created next
  /// spawn rather than leaking one per restart.
  void _destroyHostWindow() {
    if (_hostHwnd == 0) return;
    try {
      DestroyWindow(_hostHwnd);
    } catch (_) {}
    _hostHwnd = 0;
  }

  /// The pane reports its rect (PHYSICAL px, client-area relative) after
  /// every layout; the embedded window is moved/shown to match. No-op when
  /// nothing changed (this is called on every page rebuild).
  void updatePaneRect(Rect physicalRect) {
    _paneRect = physicalRect;
    _paneVisible = true;
    _applyPaneRect();
  }

  /// The pane is gone or covered by another route — hide the native window
  /// (it would otherwise draw above whatever Flutter shows there).
  void hidePane() {
    _paneVisible = false;
    if (_childHwnd != 0 && _appliedVisible) {
      ShowWindow(_childHwnd, SW_HIDE);
      if (_hostHwnd != 0) ShowWindow(_hostHwnd, SW_HIDE);
      _appliedVisible = false;
    }
  }

  void _applyPaneRect() {
    final rect = _paneRect;
    if (_childHwnd == 0 || rect == null || !_paneVisible) return;
    // NEVER apply a degenerate rect: sizing the window to ~zero makes
    // scrcpy's own resize math divide by zero and CRASH the mirror process
    // (0xc0000094 in the field). Transient zero-size layouts happen during
    // route swaps/minimize — just hide until a real rect arrives.
    if (rect.width < 40 || rect.height < 40) {
      if (_appliedVisible) {
        ShowWindow(_childHwnd, SW_HIDE);
        if (_hostHwnd != 0) ShowWindow(_hostHwnd, SW_HIDE);
        _appliedVisible = false;
      }
      return;
    }
    if (IsWindow(_childHwnd) == 0) return; // stale handle (process died)
    if (_appliedVisible && _appliedRect == rect && !_frameChangePending) {
      return; // nothing changed — skip the native call
    }

    if (_hostHwnd != 0) {
      _applyClippedHostRect(rect);
    } else {
      SetWindowPos(
        _childHwnd,
        NULL,
        rect.left.round(),
        rect.top.round(),
        rect.width.round(),
        rect.height.round(),
        SWP_NOZORDER |
            SWP_SHOWWINDOW |
            SWP_NOACTIVATE |
            // Frame recalculation is only needed once, right after the
            // adopt changed the window styles.
            (_frameChangePending ? SWP_FRAMECHANGED : 0),
      );
    }

    _appliedRect = rect;
    _appliedVisible = true;
    _frameChangePending = false;
  }

  /// Box mode: positions the host to the pane rect, then positions/sizes
  /// the scrcpy child INSIDE the host (host-client-relative coordinates) so
  /// only the camera-region band falls inside the host's client area — the
  /// crop, achieved by Win32 clipping child rendering to the parent rather
  /// than by scrcpy's own `--crop`. Falls back to filling the host
  /// edge-to-edge (uncropped) if the device resolution isn't known yet.
  void _applyClippedHostRect(Rect rect) {
    final paneW = rect.width.round();
    final paneH = rect.height.round();

    // HWND_TOP (NOT SWP_NOZORDER): the host must sit ABOVE the sibling
    // FLUTTERVIEW window, otherwise Flutter's black pane Container paints
    // over it and the mirror shows as solid black. (The old direct-embed
    // path got this for free — SetParent drops a window at the top of the
    // sibling z-order; a freshly CreateWindowEx'd host does not.)
    SetWindowPos(
      _hostHwnd,
      HWND_TOP,
      rect.left.round(),
      rect.top.round(),
      paneW,
      paneH,
      SWP_SHOWWINDOW | SWP_NOACTIVATE,
    );

    // Frame recalculation is only needed once, right after the adopt
    // changed the scrcpy window's styles.
    final frameFlag = _frameChangePending ? SWP_FRAMECHANGED : 0;
    final size = _deviceSize;
    if (size == null || size.w <= 0 || size.h <= 0) {
      SetWindowPos(
        _childHwnd,
        NULL,
        0,
        0,
        paneW,
        paneH,
        SWP_NOZORDER | SWP_SHOWWINDOW | SWP_NOACTIVATE | frameFlag,
      );
      return;
    }

    final w = size.w;
    final h = size.h;
    final top = (h * boxMirrorCropTop).round().clamp(0, h);
    final bottom = (h * boxMirrorCropBottom).round().clamp(0, h);
    final cropH = (bottom - top).clamp(1, h);

    // scrcpy's window is given the FULL frame's aspect (w/h) so it renders
    // edge-to-edge with no internal letterboxing — a uniform scale factor
    // (paneW/w) then applies to both dimensions, letting the crop band be
    // positioned by a simple offset.
    final scrcpyW = paneW;
    final scrcpyH = (paneW * h / w).round().clamp(1, 1 << 20);
    final visibleBandH = (scrcpyH * cropH / h).round().clamp(1, scrcpyH);
    // Centers the visible band vertically within the pane when the pane is
    // taller than the band needs (the width-clamp case in gallery_page's
    // box-mode layout leaves surplus height, never surplus width).
    final centerOffset = ((paneH - visibleBandH) ~/ 2).clamp(0, paneH);
    final y = -(scrcpyH * top / h).round() + centerOffset;

    SetWindowPos(
      _childHwnd,
      NULL,
      0,
      y,
      scrcpyW,
      scrcpyH,
      SWP_NOZORDER | SWP_SHOWWINDOW | SWP_NOACTIVATE | frameFlag,
    );
  }

  /// Kills the mirror (logout, app close). The job object would catch it
  /// anyway on app death; this is the orderly path.
  Future<void> stop() async {
    final proc = _process;
    if (proc == null) {
      _closeJobHandle();
      return;
    }
    try {
      proc.kill();
    } catch (_) {}
    _process = null;
    _childHwnd = 0;
    _destroyHostWindow();
    _cropCaptureView = null;
    _deviceSize = null; // the next session may be a different phone
    _lastEmbedAt = null;
    earlyExitStreak = 0;
    captureAspect.value = null;
    running.value = false;
    _closeJobHandle();
  }

  /// Resolves the box-mode crop geometry (device resolution + camera-band
  /// bounds) from the live `wm size` — caches `_deviceSize` and publishes
  /// `captureAspect` for the pane's aspect-fit sizing. Consumed CLIENT-SIDE
  /// by `_applyClippedHostRect`; NOT turned into a scrcpy `--crop` argument
  /// (see that method's doc comment for why). Returns false (never throws)
  /// when disabled, the query fails, or the result is degenerate —
  /// mirroring must never fail over the crop (falls back to uncropped).
  Future<bool> _computeCaptureGeometry(String adbPath) async {
    if (boxMirrorCropTop <= 0 && boxMirrorCropBottom >= 1) return false;
    try {
      var size = _deviceSize;
      if (size == null) {
        final res = await Process.run(adbPath, ['shell', 'wm', 'size']);
        if (res.exitCode != 0) return false;
        // Output: "Physical size: 1080x2400" and possibly an "Override size:"
        // line; the effective display is the last one listed.
        final matches = RegExp(r'(?:Override|Physical) size:\s*(\d+)x(\d+)')
            .allMatches(res.stdout.toString())
            .toList();
        if (matches.isEmpty) return false;
        final m = matches.last;
        size = (w: int.parse(m.group(1)!), h: int.parse(m.group(2)!));
        _deviceSize = size; // cached — retries skip the adb round-trip
      }
      final w = size.w;
      final h = size.h;
      final top = (h * boxMirrorCropTop).round().clamp(0, h);
      final bottom = (h * boxMirrorCropBottom).round().clamp(0, h);
      final cropH = bottom - top;
      if (w <= 0 || cropH <= 0) return false;
      // Publish the streamed aspect so the layout can aspect-fit the pane
      // (no letterboxing, no oversized native window).
      captureAspect.value = w / cropH;
      print('🪞 Mirror crop geometry: device ${w}x$h, band [$top,$bottom], '
          'aspect ${captureAspect.value!.toStringAsFixed(3)}');
      return true;
    } catch (e) {
      print('⚠️ Mirror crop geometry compute failed: $e');
      return false;
    }
  }

  // ── Win32 plumbing ─────────────────────────────────────────────────────────

  Future<int> _waitForWindow(String title, {required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    final native = title.toNativeUtf16();
    try {
      while (DateTime.now().isBefore(deadline)) {
        if (_process == null) return 0; // scrcpy already died (no device etc.)
        final hwnd = FindWindow(nullptr, native);
        if (hwnd != 0) return hwnd;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return 0;
    } finally {
      malloc.free(native);
    }
  }

  void _assignToKillOnCloseJob(int processPid) {
    final hJob = assignToKillOnCloseJob(processPid);
    if (hJob == 0) return;
    _closeJobHandle(); // a previous run's handle, if any
    _jobHandle = hJob; // held for the app's life (or until stop())
    print('🪞 scrcpy pid $processPid bound to kill-on-close job.');
  }

  void _closeJobHandle() {
    closeJobHandle(_jobHandle); // kill-on-close ⇒ also terminates scrcpy
    _jobHandle = 0;
  }
}

/// The reserved area the embedded scrcpy window renders over. Plain black
/// placeholder (the mirror letterboxes inside it); shows a hint + retry when
/// the mirror isn't running. Hides the native window whenever this pane is
/// covered by another route or disposed.
class ScrcpyPane extends StatefulWidget {
  /// The app's adb.exe — forwarded to [ScrcpyService.ensureStarted] on retry.
  final String adbPath;

  const ScrcpyPane({super.key, required this.adbPath});

  @override
  State<ScrcpyPane> createState() => _ScrcpyPaneState();
}

class _ScrcpyPaneState extends State<ScrcpyPane> with RouteAware {
  ModalRoute<void>? _route;
  bool _coveredByRoute = false;

  // Background self-healing: if the mirror isn't running while the pane is
  // visible (e.g. the initial spawn lost the adb link to a pull burst), retry
  // automatically — bounded so a genuinely absent device doesn't spawn
  // processes forever. Reset when the mirror comes up.
  Timer? _autoRetryTimer;
  int _autoRetriesLeft = 5;

  // Backoff schedule for the auto-retry, by _autoRetriesLeft at schedule time
  // (freshly reset to 5 when the mirror goes unhealthy — see _onRunningChanged).
  // The common failure (startup pull-burst contention) recovers within a
  // couple of seconds, so retry fast at first; back off toward a steady 10s
  // afterward so a genuinely absent device isn't hammered.
  static const Duration _autoRetryFirstDelay = Duration(seconds: 3);
  static const Duration _autoRetrySecondDelay = Duration(seconds: 5);
  static const Duration _autoRetrySteadyDelay = Duration(seconds: 10);

  Duration _autoRetryDelay() {
    if (_autoRetriesLeft >= 5) return _autoRetryFirstDelay;
    if (_autoRetriesLeft == 4) return _autoRetrySecondDelay;
    return _autoRetrySteadyDelay;
  }

  @override
  void initState() {
    super.initState();
    ScrcpyService.instance.running.addListener(_onRunningChanged);
    _scheduleAutoRetry();
  }

  void _onRunningChanged() {
    if (ScrcpyService.instance.running.value) {
      _autoRetriesLeft = 5; // healthy again — future drops get fresh retries
      _autoRetryTimer?.cancel();
      _autoRetryTimer = null;
    } else {
      _scheduleAutoRetry();
    }
  }

  void _scheduleAutoRetry() {
    if (ScrcpyService.instance.running.value) return;
    if (_autoRetriesLeft <= 0) return;
    // Crash-loop breaker: if scrcpy keeps dying right after embedding,
    // respawning it every 10s just churns the machine — stop and leave the
    // manual Retry (which clears the streak).
    if (ScrcpyService.instance.earlyExitStreak >= 4) return;
    _autoRetryTimer?.cancel();
    _autoRetryTimer = Timer(_autoRetryDelay(), () async {
      _autoRetryTimer = null;
      if (!mounted || ScrcpyService.instance.running.value) return;
      _autoRetriesLeft--;
      await ScrcpyService.instance.ensureStarted(adbPath: widget.adbPath);
      if (mounted) _scheduleAutoRetry();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route != _route) {
      if (_route != null) appRouteObserver.unsubscribe(this);
      _route = route;
      if (route != null) appRouteObserver.subscribe(this, route);
    }
  }

  @override
  void dispose() {
    _autoRetryTimer?.cancel();
    ScrcpyService.instance.running.removeListener(_onRunningChanged);
    appRouteObserver.unsubscribe(this);
    ScrcpyService.instance.hidePane();
    super.dispose();
  }

  // Another route was pushed on top (dialog, metadata form, uploader…) — the
  // native window would draw over it, so hide until we're current again.
  @override
  void didPushNext() {
    _coveredByRoute = true;
    ScrcpyService.instance.hidePane();
  }

  @override
  void didPopNext() {
    _coveredByRoute = false;
    _scheduleReport();
  }

  void _scheduleReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
  }

  void _report() {
    if (!mounted || _coveredByRoute) return;
    final render = context.findRenderObject();
    if (render is! RenderBox || !render.attached || !render.hasSize) return;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final topLeft = render.localToGlobal(Offset.zero);
    ScrcpyService.instance.updatePaneRect(
      Rect.fromLTWH(
        topLeft.dx * dpr,
        topLeft.dy * dpr,
        render.size.width * dpr,
        render.size.height * dpr,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // Re-report after every layout pass (window resize, pane resize).
        _scheduleReport();
        Widget content = Container(
          color: const Color(0xFF000000),
          alignment: Alignment.center,
          child: ValueListenableBuilder<bool>(
            valueListenable: ScrcpyService.instance.running,
            builder: (context, running, _) {
              if (running) return const SizedBox.shrink();
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.phonelink_off,
                      color: Color(0xFF9E9E9E), size: 40),
                  const SizedBox(height: 12),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      'Phone mirror unavailable.\nCheck the USB connection.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: Color(0xFF9E9E9E), fontSize: 13),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: () {
                      // Manual retry clears the crash-loop breaker and gives
                      // the self-heal a fresh budget.
                      ScrcpyService.instance.earlyExitStreak = 0;
                      _autoRetriesLeft = 5;
                      ScrcpyService.instance
                          .ensureStarted(adbPath: widget.adbPath);
                      _scheduleAutoRetry();
                    },
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('Retry'),
                  ),
                ],
              );
            },
          ),
        );

        // Tap-to-focus removed here (see ensureStarted's revert comment):
        // the WS_EX_TRANSPARENT click-through it depended on reintroduced
        // the mirror's crash-loop, so the embedded window is opaque again
        // and no click reaches Flutter at this location. A future fix
        // needs a mechanism that doesn't touch scrcpy's own window at all
        // (mapPaneTapToDevicePixels/tapDevicePixels below are still valid
        // building blocks for whatever that turns out to be).

        return content;
      },
    );
  }
}
