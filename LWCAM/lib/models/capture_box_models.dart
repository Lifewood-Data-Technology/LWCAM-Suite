/// Box→Folders capture workflow models (Phase 2 revision). Pure Dart — no
/// Flutter/GetX/DB imports — matching the batch_metadata.dart convention.
///
/// A physical BOX contains many FOLDERS; each folder carries its own keyed
/// metadata (spec §8 fields) and its own destination subfolder at transfer.
library;

import '../services/path_utils.dart' show sanitizeWindowsName;

// ── Volume ──────────────────────────────────────────────────────────────────
//
// Volume is ONE free-text field with nothing parsed out of it. It used to be
// keyed as "<something> file no. XXXX" and the text after a "file no." marker
// was treated as a file number: it drove the folder name, carried over to the
// next folder with the number stripped, and a folder without one had
// "(unknown file [N])" written INTO its Volume at transfer prep. That is one
// client's numbering convention, not a property of the workflow, and projects
// that number differently had no way to opt out. All of it is gone — whatever
// the operator types is the value, verbatim.

// ── Folder naming ───────────────────────────────────────────────────────────

/// Destination folder names for [foldersInSeqOrder] (creation order).
///
/// **The name is the folder's Volume**, verbatim apart from Windows
/// sanitization. Nothing is prefixed, parsed or appended in the normal case.
///
/// Uniqueness is still enforced, because this string becomes a real DIRECTORY
/// under the destination — `TransferController._destPathFor` joins it as one —
/// so two folders resolving to the same name would silently merge their images
/// into a single directory, and the CSV would carry two rows pointing at it.
/// Two cases need a fallback, and only these two:
///  - **A repeated name** (the same Volume twice in one box, or two different
///    Volumes that sanitize to the same string) gets ` - 0002`, ` - 0003`, …
///    The FIRST folder always keeps the bare Volume.
///  - **A blank Volume** has nothing to name the directory with, so it falls
///    back to the box's own details, disambiguated the same way.
///
/// [reserved] is lower-cased names already taken by OTHER groups
/// (`UploadStatsDB.reservedFolderNames`). The destination is
/// `<root>\<YYYYMMDD>\<folderName>` — a shared day folder with nothing
/// identifying the group — so without this two groups transferred on one day
/// whose folders share a Volume write into the same directory.
///
/// Computed at transfer prep (Volume stays editable while the box is open) and
/// persisted, so a retry re-derives the same names.
List<String> computeFolderNames(
  String boxDetails,
  List<CaptureFolder> foldersInSeqOrder, {
  Set<String> reserved = const {},
}) {
  final details = boxDetails.trim();
  final taken = <String>{...reserved};

  String claim(String base) {
    // Loop rather than a counter: the suffixed candidate could itself collide
    // with a folder literally named that.
    //
    // Compared case-INSENSITIVELY because these become Windows directories and
    // Windows does not distinguish "Register 12" from "register 12" — keying
    // the set on the exact string let both keep their bare name and resolve to
    // one directory, which is the merge this function exists to prevent. The
    // returned name keeps the operator's own casing.
    var candidate = base;
    var n = 1;
    while (!taken.add(candidate.toLowerCase())) {
      n++;
      candidate = '$base - ${n.toString().padLeft(4, '0')}';
    }
    return candidate;
  }

  return [
    for (final f in foldersInSeqOrder)
      () {
        // Blank-check the RAW value, then sanitize: sanitizeWindowsName('')
        // returns '_', so sanitizing first makes an unkeyed Volume look like a
        // real name and yields a folder called "_".
        final raw = (f.volume ?? '').trim();
        return claim(sanitizeWindowsName(raw.isEmpty ? details : raw));
      }(),
  ];
}

// ── Entities ─────────────────────────────────────────────────────────────────

class CaptureBox {
  final int id;
  final String deviceId;

  /// The box's name (cloud column `box_name`; the Dart identifier predates
  /// the schema alignment and is referenced everywhere, so it stays).
  final String boxDetails;

  /// 'OPEN' | 'TRANSFERRED' — full CAPS, mirroring the cloud statuses.
  final String status;

  /// Username of the operator who created the box (cloud `user_id`).
  final String? scanningOpr;

  /// Cloud project natural key (projects.project_id), frozen at creation.
  final String? projectId;
  final DateTime? createdAt;

  /// Cloud `transfer_end_at`.
  final DateTime? transferredAt;

  /// Cloud `transferred_to`: the `<root>\YYYYMMDD` day directory this box's
  /// transfer was fixed to on its first attempt (UploadStatsDB.
  /// markCaptureBoxTransferStarted). Every retry and the processing-marker
  /// writer use it. Builds before 2026-09-10 wrote the bare root, on success.
  final String? transferredTo;

  /// The folder the operator was last capturing into — restored as the
  /// active folder when the box is reopened (free folder switching means
  /// the active folder is no longer always the last-created one).
  final int? lastActiveFolderId;

  /// Key of the [Project] (see project.dart) this box was created under.
  /// Null for boxes created before the Projects feature shipped.
  final String? projectKey;

  /// Snapshot of the project's metadata template (see metadata_template.dart)
  /// taken at box-creation time — mid-box template edits never disturb an
  /// open box. Null for legacy boxes (created before templates shipped) and
  /// for boxes whose project had no custom template; both fall back to
  /// MetadataTemplate.standard() via MetadataTemplate.fromJsonStringOrStandard.
  final String? templateJson;

  /// Persisted outcome of the box's last background transfer, so the box
  /// list shows it after a restart/re-login: 'running' (a leftover value at
  /// startup means the transfer was cut off mid-run), 'partial', 'failed',
  /// or null (never attempted / fully succeeded). Local-only — never synced.
  final String? lastTransferState;
  final String? lastTransferError;

  const CaptureBox({
    required this.id,
    required this.deviceId,
    required this.boxDetails,
    this.status = 'OPEN',
    this.scanningOpr,
    this.projectId,
    this.createdAt,
    this.transferredAt,
    this.transferredTo,
    this.lastActiveFolderId,
    this.projectKey,
    this.templateJson,
    this.lastTransferState,
    this.lastTransferError,
  });

  bool get isTransferred => status == 'TRANSFERRED';

  factory CaptureBox.fromDbMap(Map<String, Object?> row) {
    DateTime? parse(Object? v) => v == null ? null : DateTime.tryParse(v.toString());
    return CaptureBox(
      id: (row['id'] as num).toInt(),
      deviceId: (row['device_id'] as String?) ?? '',
      boxDetails: (row['box_name'] as String?) ?? '',
      status: (row['status'] as String?) ?? 'OPEN',
      scanningOpr: row['user_id'] as String?,
      projectId: row['project_id'] as String?,
      createdAt: parse(row['created_at']),
      transferredAt: parse(row['transfer_end_at']),
      transferredTo: row['transferred_to'] as String?,
      lastActiveFolderId: (row['last_active_folder_id'] as num?)?.toInt(),
      projectKey: row['project_key'] as String?,
      templateJson: row['template_json'] as String?,
      lastTransferState: row['last_transfer_state'] as String?,
      lastTransferError: row['last_transfer_error'] as String?,
    );
  }
}

class CaptureFolder {
  /// 0 for a not-yet-inserted draft.
  final int id;
  final int boxId;

  /// 1-based creation order within the box.
  final int folderSeq;

  final String? coverTag;
  final String? imageTags;
  final String? title;

  /// Free text, exactly as keyed. Becomes this folder's destination
  /// directory name — see [computeFolderNames].
  final String? volume;
  final String? startDate;
  final String? endDate;
  final String? archivalRefNo;

  /// Record Type — template-driven like the other keyed fields (see
  /// metadata_template.dart): editable, fixed, or (the standard template's
  /// default) mapped from Title. Stored so an editable/fixed Record Type has
  /// somewhere to live; a mapped one is recomputed at read time and this
  /// stored value is simply unused for that folder.
  final String? recordType;

  /// Destination subfolder name, persisted at transfer prep (null until then).
  final String? folderName;
  final DateTime? createdAt;
  final DateTime? updatedAt;

  const CaptureFolder({
    this.id = 0,
    required this.boxId,
    this.folderSeq = 0,
    this.coverTag,
    this.imageTags,
    this.title,
    this.volume,
    this.startDate,
    this.endDate,
    this.archivalRefNo,
    this.recordType,
    this.folderName,
    this.createdAt,
    this.updatedAt,
  });

  // Mandatory-field completeness is TEMPLATE-DRIVEN — see
  // MetadataTemplate.missingMandatoryFieldsOf / isCompleteOf in
  // metadata_template.dart. There is no longer a context-free "is this
  // folder complete" answer: it depends on which project (and therefore
  // which template) the folder's box belongs to.

  /// [boxId] is settable because the New Group flow builds folder 1's draft
  /// before the box exists (boxId 0) and has to re-home it afterwards. It used
  /// to do that by constructing a new CaptureFolder and listing the fields to
  /// carry over, which silently dropped Record Type — the same hand-listing
  /// mistake updateCaptureFolderMetadata made. Re-homing through copyWith
  /// carries every field, including ones added later.
  CaptureFolder copyWith({
    int? id,
    int? boxId,
    int? folderSeq,
    String? coverTag,
    String? imageTags,
    String? title,
    String? volume,
    String? startDate,
    String? endDate,
    String? archivalRefNo,
    String? recordType,
    String? folderName,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return CaptureFolder(
      id: id ?? this.id,
      boxId: boxId ?? this.boxId,
      folderSeq: folderSeq ?? this.folderSeq,
      coverTag: coverTag ?? this.coverTag,
      imageTags: imageTags ?? this.imageTags,
      title: title ?? this.title,
      volume: volume ?? this.volume,
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      archivalRefNo: archivalRefNo ?? this.archivalRefNo,
      recordType: recordType ?? this.recordType,
      folderName: folderName ?? this.folderName,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  /// [isComplete] is caller-supplied — completeness is template-driven (see
  /// MetadataTemplate.isCompleteOf), not something CaptureFolder can compute
  /// on its own.
  Map<String, Object?> toDbMap({required bool isComplete}) => {
    'box_id': boxId,
    'folder_seq': folderSeq,
    'cover_tag': coverTag,
    'image_tags': imageTags,
    'title': title,
    'volume': volume,
    'start_date': startDate,
    'end_date': endDate,
    'archival_ref_no': archivalRefNo,
    'record_type': recordType,
    'is_complete': isComplete ? 1 : 0,
    'folder_name': folderName,
    'source_created_at': createdAt?.toIso8601String(),
    'source_updated_at': updatedAt?.toIso8601String(),
  };

  factory CaptureFolder.fromDbMap(Map<String, Object?> row) {
    DateTime? parse(Object? v) => v == null ? null : DateTime.tryParse(v.toString());
    return CaptureFolder(
      id: (row['id'] as num).toInt(),
      boxId: (row['box_id'] as num).toInt(),
      folderSeq: (row['folder_seq'] as num?)?.toInt() ?? 0,
      coverTag: row['cover_tag'] as String?,
      imageTags: row['image_tags'] as String?,
      title: row['title'] as String?,
      volume: row['volume'] as String?,
      startDate: row['start_date'] as String?,
      endDate: row['end_date'] as String?,
      archivalRefNo: row['archival_ref_no'] as String?,
      recordType: row['record_type'] as String?,
      folderName: row['folder_name'] as String?,
      createdAt: parse(row['source_created_at']),
      updatedAt: parse(row['source_updated_at']),
    );
  }
}
