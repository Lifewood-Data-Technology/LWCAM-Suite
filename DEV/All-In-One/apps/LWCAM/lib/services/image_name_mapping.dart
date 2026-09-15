/// The transfer engine's generated base name for a device filename.
String baseNameForDeviceFilename(String deviceId, String name) {
  final match = RegExp(r'(\d{8})_(\d{6})').firstMatch(name);
  if (match == null) return '';
  return '${deviceId}_IMG_${match.group(1)}_${match.group(2)}';
}

/// Reverses LWCAM's production transfer naming without storing another cloud
/// column. Returns null rather than guessing when the name is not one of the
/// two formats LWCAM actually emits/records:
///   IMG_YYYYMMDD_HHMMSS.ext
///   `device_IMG_YYYYMMDD_HHMMSS[_NNN].ext`
String? sourceImageNameFromCloudImage(String deviceId, String cloudName) {
  final source = RegExp(
    r'^IMG_(\d{8})_(\d{6})(\.[^.]+)$',
    caseSensitive: false,
  ).firstMatch(cloudName);
  if (source != null) return cloudName;

  final transferred = RegExp(
    '^${RegExp.escape(deviceId)}_IMG_'
    r'(\d{8})_(\d{6})(?:_\d{3})?(\.[^.]+)$',
    caseSensitive: false,
  ).firstMatch(cloudName);
  if (transferred == null) return null;
  return 'IMG_${transferred.group(1)}_${transferred.group(2)}'
      '${transferred.group(3)}';
}
