/// Legacy spec §8 constants: kept only because MetadataTemplate.standard()
/// (metadata_template.dart) is contractually required to reproduce these
/// exact values, and metadata_template_test.dart's parity tests import them
/// as the independent source of truth. The per-batch DB model that used to
/// live here (BatchMetadata) is gone — box/folder metadata now lives on
/// capture_boxes/capture_folders (see upload_stats_db.dart).
library;

// ── Dropdown value lists (spec §8.2) ───────────────────────────────────────

const List<String> kCoverTagValues = [
  'Cover Will Be Captured',
  'Cover Will not Be Captured',
  'Cover Unavailable or Missing',
];

const List<String> kImageTagsValues = [
  'Faded or Damaged Documents',
  'Reflective Surface',
  'Document Glued Together',
];

const List<String> kTitleValues = [
  'WWI South African Mounted Rifles Military Indexes',
  'WWI South African Mounted Rifles Military Personnel Cards',
  'WWI Medical Files',
  'WWII Medical Files',
];

// ── Title → Record Type mapping (spec §8.4) ─────────────────────────────────

const Map<String, String> _recordTypeByTitle = {
  'WWI South African Mounted Rifles Military Personnel Cards': 'Military Service Records',
  'WWI South African Mounted Rifles Military Indexes': 'Military Service Record Indexes',
  'WWI Medical Files': 'Military Medical Records',
  'WWII Medical Files': 'Military Medical Records',
};

/// Record Type is never keyed — always derived from Title (spec §8.4).
/// Returns null for an unknown/absent title.
String? recordTypeForTitle(String? title) {
  if (title == null) return null;
  return _recordTypeByTitle[title.trim()];
}

/// RFC 4180 escaping for a CSV cell: wrap in quotes and double any internal
/// quote when the value contains a comma, quote, CR, or LF. Used only for the
/// new metadata columns — the existing 6 upload-records cells keep their
/// current naive quoting so the keying-disabled output stays byte-identical.
String csvEscape(String? value) {
  final v = value ?? '';
  if (v.contains(',') || v.contains('"') || v.contains('\n') || v.contains('\r')) {
    return '"${v.replaceAll('"', '""')}"';
  }
  return v;
}
