// ignore_for_file: avoid_print

// Global keyboard hotkey that fires the phone shutter from the PC, for the
// capture page in LWCAM (the action itself goes through AdbDeviceService).
// Know before editing: the hotkey must be global because the embedded scrcpy
// window takes keyboard focus, and it is registered only while LWCAM is the
// foreground window so it does not steal the key from other apps.

import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';
import 'package:window_manager/window_manager.dart';

/// Registers a GLOBAL keyboard hotkey (RegisterHotKey under the hood) that
/// fires the phone camera shutter. A global hotkey is required because a plain
/// Flutter key handler never sees keys while the embedded native scrcpy mirror
/// window has focus.
///
/// The hotkey is FOREGROUND-SCOPED: it is only registered while LWCAM is
/// the foreground window, so the chosen key isn't stolen from other apps when
/// the operator alt-tabs away. (Clicking the child mirror does NOT blur the
/// top-level window, so the hotkey stays live over the mirror.)
///
/// Singleton — the capture page arms/disarms it; it must outlive widget
/// rebuilds and coordinate with the app-wide window focus listener.
class ShutterHotkeyService with WindowListener {
  ShutterHotkeyService._();
  static final ShutterHotkeyService instance = ShutterHotkeyService._();

  Future<void> Function()? _onTrigger;
  String? _keybind;
  bool _armed = false;
  bool _registered = false;
  bool _listening = false;
  // Temporarily held down (e.g. while a metadata dialog with text fields is
  // open) so the key reverts to normal text input instead of firing the
  // shutter. Distinct from [_armed]: the service stays armed/listening, it
  // just keeps the OS hotkey unregistered until [resume].
  bool _suspended = false;

  /// Maps a stored keybind label to a physical key. Unknown → null (skip).
  static PhysicalKeyboardKey? _physicalFor(String keybind) {
    const map = <String, PhysicalKeyboardKey>{
      'Space': PhysicalKeyboardKey.space,
      'Enter': PhysicalKeyboardKey.enter,
      'Delete': PhysicalKeyboardKey.delete,
      'F1': PhysicalKeyboardKey.f1,
      'F2': PhysicalKeyboardKey.f2,
      'F3': PhysicalKeyboardKey.f3,
      'F4': PhysicalKeyboardKey.f4,
      'F5': PhysicalKeyboardKey.f5,
      'F6': PhysicalKeyboardKey.f6,
      'F7': PhysicalKeyboardKey.f7,
      'F8': PhysicalKeyboardKey.f8,
      'F9': PhysicalKeyboardKey.f9,
      'F10': PhysicalKeyboardKey.f10,
      'F11': PhysicalKeyboardKey.f11,
      'F12': PhysicalKeyboardKey.f12,
    };
    return map[keybind];
  }

  HotKey? _hotKey;

  /// Arm the shutter hotkey with [keybind]; [onTrigger] runs on each press.
  /// Idempotent — call again (e.g. after an admin changes the keybind) to
  /// re-arm with new settings.
  Future<void> arm({
    required String keybind,
    required Future<void> Function() onTrigger,
  }) async {
    _onTrigger = onTrigger;
    _keybind = keybind;
    _armed = true;
    if (!_listening) {
      windowManager.addListener(this);
      _listening = true;
    }
    // Register now if we're the foreground window; the focus listener handles
    // the rest.
    await _register();
  }

  /// Disarm (leaving the capture page). Unregisters the hotkey and stops
  /// listening to focus changes.
  Future<void> disarm() async {
    _armed = false;
    _suspended = false;
    _onTrigger = null;
    await _unregister();
    if (_listening) {
      windowManager.removeListener(this);
      _listening = false;
    }
  }

  /// Temporarily release the OS hotkey so the key behaves normally (e.g. an
  /// operator typing Space/Delete/Enter into the folder-metadata form). Stays
  /// armed — [resume] re-registers. Cheap (a single unregister); safe to call
  /// even when not armed.
  Future<void> suspend() async {
    if (_suspended) return;
    _suspended = true;
    await _unregister();
  }

  /// Re-register the hotkey after a [suspend] (if still armed and the window
  /// is focused, which it is right after an in-app dialog closes).
  Future<void> resume() async {
    if (!_suspended) return;
    _suspended = false;
    if (_armed) await _register();
  }

  /// Last accepted trigger — RegisterHotKey (without MOD_NOREPEAT, which this
  /// plugin can't set) re-fires on keyboard auto-repeat while the key is held;
  /// without this debounce a held key would machine-gun the shutter.
  DateTime _lastTrigger = DateTime.fromMillisecondsSinceEpoch(0);

  Future<void> _register() async {
    if (!_armed || _registered || _suspended) return;
    final key = _keybind == null ? null : _physicalFor(_keybind!);
    if (key == null) {
      print('⚠️ Shutter hotkey: unknown keybind "$_keybind" — not registered.');
      return;
    }
    try {
      // modifiers MUST be non-null: the Windows plugin's C++ does
      // std::get<EncodableList> on the 'modifiers' argument and FAIL-FASTS
      // the whole app (0xC0000409) when Dart sends null.
      final hk = HotKey(
        key: key,
        modifiers: const [],
        scope: HotKeyScope.system,
      );
      await hotKeyManager.register(hk, keyDownHandler: (_) {
        final now = DateTime.now();
        if (now.difference(_lastTrigger).inMilliseconds < 700) return;
        _lastTrigger = now;
        // Fire-and-forget; the shutter method is async and self-logging.
        _onTrigger?.call();
      });
      _hotKey = hk;
      _registered = true;
      print('⌨️ Shutter hotkey registered: $_keybind');
    } catch (e) {
      print('⚠️ Shutter hotkey register failed: $e');
    }
  }

  Future<void> _unregister() async {
    final hk = _hotKey;
    if (hk == null) {
      _registered = false;
      return;
    }
    try {
      await hotKeyManager.unregister(hk);
    } catch (e) {
      print('⚠️ Shutter hotkey unregister failed: $e');
    }
    _hotKey = null;
    _registered = false;
  }

  // ── Foreground scoping ─────────────────────────────────────────────────
  @override
  void onWindowFocus() {
    if (_armed) _register();
  }

  @override
  void onWindowBlur() {
    if (_armed) _unregister();
  }
}
