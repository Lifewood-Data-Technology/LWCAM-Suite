// Encrypts and decrypts the stored database password with Windows DPAPI
// (used by LWCAM and LWCam Admin; the two copies must stay identical).
// The encrypted value lives in the node config file, never plaintext.
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

/// Windows DPAPI (CurrentUser scope) over dart:ffi, so database passwords are
/// never written in plaintext. Blobs are base64. Each caller passes the
/// entropy its field is bound to: the admin login uses [adminDpapiEntropy]
/// (the default), the capture login uses [captureDpapiEntropy] - LWCAM reads
/// `pgPasswordProtected` with the same code, so this file is kept identical in
/// both apps. No package:ffi: buffers come from kernel32 LocalAlloc/LocalFree.
///
/// Every native buffer that held plaintext is zeroed before it is freed.
/// (The Dart String a caller passes in or gets back cannot be wiped - that is
/// a limit of the language, not of this file.)

/// Entropy of `adminPgPasswordProtected`.
const adminDpapiEntropy = 'LWCamAdmin';

/// Entropy of `pgPasswordProtected` (the capture login).
const captureDpapiEntropy = 'LWCam';

final class _DataBlob extends Struct {
  @Uint32()
  external int cbData;
  external Pointer<Uint8> pbData;
}

typedef _CryptC = Int32 Function(Pointer<_DataBlob>, Pointer<Void>,
    Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, Uint32, Pointer<_DataBlob>);
typedef _CryptD = int Function(Pointer<_DataBlob>, Pointer<Void>,
    Pointer<_DataBlob>, Pointer<Void>, Pointer<Void>, int, Pointer<_DataBlob>);

final _k32 = DynamicLibrary.open('kernel32.dll');
final _localAlloc = _k32.lookupFunction<Pointer<Void> Function(Uint32, IntPtr),
    Pointer<Void> Function(int, int)>('LocalAlloc');
final _localFree = _k32.lookupFunction<Pointer<Void> Function(Pointer<Void>),
    Pointer<Void> Function(Pointer<Void>)>('LocalFree');
final _getLastError =
    _k32.lookupFunction<Uint32 Function(), int Function()>('GetLastError');

Pointer<T> _alloc<T extends NativeType>(int bytes) {
  final p = _localAlloc(0x40, bytes); // LPTR: fixed + zeroed
  if (p == nullptr) {
    throw StateError('LocalAlloc($bytes) failed (Win32 error ${_getLastError()})');
  }
  return p.cast<T>();
}

Pointer<_DataBlob> _blob(List<int> data) {
  final b = _alloc<_DataBlob>(sizeOf<_DataBlob>());
  try {
    final buf = _alloc<Uint8>(data.isEmpty ? 1 : data.length);
    buf.asTypedList(data.length).setAll(0, data);
    b.ref
      ..cbData = data.length
      ..pbData = buf;
    return b;
  } catch (_) {
    _localFree(b.cast());
    rethrow;
  }
}

/// Zeroes the blob's data, then frees the data and the struct.
void _freeBlob(Pointer<_DataBlob> b) {
  final data = b.ref.pbData;
  if (data != nullptr) {
    if (b.ref.cbData > 0) data.asTypedList(b.ref.cbData).fillRange(0, b.ref.cbData, 0);
    _localFree(data.cast());
  }
  _localFree(b.cast());
}

Uint8List _run(String fn, List<int> input, List<int> entropy) {
  final crypt = DynamicLibrary.open('crypt32.dll').lookupFunction<_CryptC, _CryptD>(fn);
  Pointer<_DataBlob>? inp, ent, out;
  try {
    inp = _blob(input);
    ent = _blob(entropy);
    out = _alloc<_DataBlob>(sizeOf<_DataBlob>());
    // flags 0x1 = CRYPTPROTECT_UI_FORBIDDEN
    final ok = crypt(inp, nullptr, ent, nullptr, nullptr, 1, out);
    if (ok == 0) throw StateError('$fn failed (Win32 error ${_getLastError()})');
    return Uint8List.fromList(out.ref.pbData.asTypedList(out.ref.cbData));
  } finally {
    // out.pbData is only set once the call succeeded; it is zeroed (it may be
    // the decrypted password) and freed by _freeBlob.
    if (inp != null) _freeBlob(inp);
    if (ent != null) _freeBlob(ent);
    if (out != null) _freeBlob(out);
  }
}

/// Encrypts [plain] for the current Windows user; returns base64.
String dpapiProtect(String plain, {String entropy = adminDpapiEntropy}) {
  final bytes = utf8.encode(plain);
  try {
    return base64Encode(_run('CryptProtectData', bytes, utf8.encode(entropy)));
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

/// Reverses [dpapiProtect]. Throws if the blob is not this user's, or was
/// protected with a different [entropy].
String dpapiUnprotect(String protectedB64, {String entropy = adminDpapiEntropy}) {
  final bytes = _run('CryptUnprotectData', base64Decode(protectedB64), utf8.encode(entropy));
  try {
    return utf8.decode(bytes);
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}
