/// One page image inside a task.
class QcTaskImage {
  final int id;
  final String filename;

  /// False when the file behind the row cannot be read. The viewer says so
  /// rather than showing a broken frame.
  final bool available;

  /// Path the engine serves this image's preview from, already carrying a `v=`
  /// stamp that changes whenever the image or the reviewer's draft of it does.
  /// Used verbatim as a cache key so an edited page never shows its stale copy.
  final String previewUrl;

  /// Set once the reviewer has edited this image in their draft.
  final String? draftState;

  /// Marks where a split into a child folder begins.
  final bool separationStart;

  const QcTaskImage({
    required this.id,
    required this.filename,
    required this.available,
    required this.previewUrl,
    required this.draftState,
    required this.separationStart,
  });

  factory QcTaskImage.fromJson(Map<String, Object?> json) => QcTaskImage(
        id: (json['id'] as num?)?.toInt() ?? 0,
        filename: json['filename']?.toString() ?? '',
        available: json['available'] as bool? ?? false,
        previewUrl: json['previewUrl']?.toString() ?? '',
        draftState: json['draftState']?.toString(),
        separationStart: json['separationStart'] as bool? ?? false,
      );
}

/// One field of a project's metadata template.
///
/// `input` is one of:
///   text   - free text
///   select - one of [options]
///   fixed  - the project's own constant, shown but never edited here
class QcMetadataField {
  final String key;
  final String label;
  final String input;
  final bool mandatory;
  final List<String> options;

  /// Only set for `fixed` fields: the value the project pins for every folder.
  final String? value;

  /// Only set for `mapped` fields: the field this one derives from.
  final String? mappedFrom;

  /// Only set for `mapped` fields: source field's value -> this field's value.
  final Map<String, String> valueMap;

  const QcMetadataField({
    required this.key,
    required this.label,
    required this.input,
    required this.mandatory,
    required this.options,
    required this.value,
    this.mappedFrom,
    this.valueMap = const {},
  });

  bool get isFixed => input == 'fixed';
  bool get isSelect => input == 'select';

  /// Derived from another field through [valueMap] - the operator never types
  /// it. The project decides which fields these are; Record Type is only the
  /// most common one, not a special case.
  bool get isMapped => input == 'mapped';

  /// A field the operator actually fills, and so the only kind a mapping may
  /// derive FROM - see [QcMetadataTemplate.applyMappings].
  bool get isEditable => !isFixed && !isMapped;

  factory QcMetadataField.fromJson(Map<String, Object?> json) =>
      QcMetadataField(
        key: json['key']?.toString() ?? '',
        label: json['label']?.toString() ?? '',
        input: json['input']?.toString() ?? 'text',
        mandatory: json['mandatory'] as bool? ?? false,
        options: ((json['options'] as List?) ?? const [])
            .map((option) => option.toString())
            .toList(),
        value: json['value']?.toString(),
        mappedFrom: json['mappedFrom']?.toString(),
        valueMap: ((json['valueMap'] as Map?) ?? const {}).map(
          (key, value) => MapEntry(key.toString(), value.toString()),
        ),
      );
}

/// The project's metadata template.
class QcMetadataTemplate {
  final List<QcMetadataField> fields;

  /// Title -> record type. The engine derives recordType from the title on every
  /// save, so the form shows it but never lets it be typed.
  final Map<String, String> titleRecordTypeMap;

  const QcMetadataTemplate({
    required this.fields,
    required this.titleRecordTypeMap,
  });

  static const empty = QcMetadataTemplate(fields: [], titleRecordTypeMap: {});

  factory QcMetadataTemplate.fromJson(Map<String, Object?> json) =>
      QcMetadataTemplate(
        fields: ((json['fields'] as List?) ?? const [])
            .whereType<Map<String, Object?>>()
            .map(QcMetadataField.fromJson)
            .toList(),
        titleRecordTypeMap: ((json['titleRecordTypeMap']
                    as Map<String, Object?>?) ??
                const {})
            .map((key, value) => MapEntry(key, value.toString())),
      );

  String? recordTypeFor(String? title) =>
      (title == null || title.isEmpty) ? null : titleRecordTypeMap[title];

  QcMetadataField? fieldFor(String key) {
    for (final field in fields) {
      if (field.key == key) return field;
    }
    return null;
  }

  /// The mapped fields that derive from [sourceKey], so editing one field knows
  /// exactly which others to recompute.
  List<QcMetadataField> mappedFieldsFrom(String sourceKey) => [
        for (final field in fields)
          if (field.isMapped && field.mappedFrom == sourceKey) field,
      ];

  /// Rewrites every mapped field in [values] from the field it maps from.
  ///
  /// Mirrors the engine's own normalization, so the form shows what a save would
  /// store rather than a value the engine is about to replace. Resolved ONE
  /// LEVEL DEEP and only from an editable source, the same rule the capture form
  /// uses (`metadata_template.dart`, `effectiveValueOf`) - a mapped-from-mapped
  /// chain yields null instead of recursing, so evaluation order cannot matter.
  void applyMappings(Map<String, String?> values) {
    for (final field in fields) {
      if (!field.isMapped) continue;
      final sourceKey = field.mappedFrom;
      final source = sourceKey == null ? null : fieldFor(sourceKey);
      if (sourceKey == null ||
          sourceKey == field.key ||
          source == null ||
          !source.isEditable) {
        values[field.key] = null;
        continue;
      }
      final sourceValue = values[sourceKey]?.trim();
      final mapped =
          sourceValue == null ? null : field.valueMap[sourceValue];
      values[field.key] = (mapped == null || mapped.isEmpty) ? null : mapped;
    }
  }
}

/// A QC task as the engine reports it.
///
/// The list endpoint and the detail endpoint return the same shape; [images] is
/// simply empty in list responses. The metadata form and template are still
/// unparsed - they belong to the metadata editor, which is not written yet, and
/// modelling them now would be guessing at a shape nothing has been built
/// against.
/// Why a Completed row has, or has not, a Group ID - so an empty one reads as
/// a stage in the pipeline rather than as missing data.
enum QcCompletedState { exported, awaitingExport, sentBack, reworkPendingExport }

extension QcCompletedStateLabel on QcCompletedState {
  String get label => switch (this) {
        QcCompletedState.exported => 'Exported',
        QcCompletedState.awaitingExport => 'Awaiting export',
        QcCompletedState.sentBack => 'Sent back for rework',
        QcCompletedState.reworkPendingExport => 'Rework pending export',
      };
}

class QcTask {
  final int folderId;
  final String status;

  /// Hash of the folder's source images. Every mutating call sends it back so
  /// the engine can refuse an edit written against images that have since
  /// changed underneath the reviewer.
  final String sourceHash;

  final String boxName;
  final String folderName;
  final int folderSeq;
  final String? projectName;
  final String? title;
  final int imageCount;

  /// False when the folder is in the database but its images cannot be read —
  /// usually a path that moved. Claiming one is pointless, so the list says so.
  final bool imageAvailable;

  final bool hasDraft;

  /// Ids of the pages the reviewer's draft has changed - rotated, straightened,
  /// brightened, cropped, replaced or inserted.
  ///
  /// A Set because the rail asks per tile. Empty unless the viewer holds the
  /// claim: the engine only reads a manifest for the reviewer who owns it, so a
  /// read-only viewer has no draft to report and no page is marked edited.
  final Set<int> draftImageIds;

  /// True when the reviewer's draft holds metadata edits not yet approved.
  final bool draftMetadataDirty;

  final List<QcTaskImage> images;
  final QcMetadataTemplate template;

  /// Every metadata value as the engine reports it, draft edits already folded
  /// in. Kept as the raw map: the editable set is 15 flat fields, and naming
  /// each one twice in Dart would add a second place to keep in step with the
  /// backend for nothing.
  final Map<String, Object?> metadata;
  final int? assignedTo;
  final DateTime? claimedAt;
  final DateTime submittedAt;

  /// The identifier the ingest team quotes, assigned when the folder is
  /// EXPORTED - not when it is approved. Null while a folder is approved but
  /// not yet swept up (the export sweep runs every 30s), and null forever for
  /// one sent back for rework, which never gets exported at all.
  final String? groupId;

  /// Whether the export has published this folder's package.
  final bool isExported;

  /// Set when the client asked for changes after delivery. Carried into the
  /// export CSV's Rework column.
  final bool clientRework;

  const QcTask({
    required this.folderId,
    required this.status,
    required this.sourceHash,
    required this.boxName,
    required this.folderName,
    required this.folderSeq,
    required this.projectName,
    required this.title,
    required this.imageCount,
    required this.imageAvailable,
    required this.hasDraft,
    required this.draftImageIds,
    this.draftMetadataDirty = false,
    this.images = const [],
    this.template = QcMetadataTemplate.empty,
    this.metadata = const {},
    required this.assignedTo,
    required this.claimedAt,
    required this.submittedAt,
    this.groupId,
    this.isExported = false,
    this.clientRework = false,
  });

  factory QcTask.fromJson(Map<String, Object?> json) {
    final metadata = (json['metadata'] as Map<String, Object?>?) ?? const {};
    return QcTask(
      folderId: (json['id'] as num?)?.toInt() ?? 0,
      status: json['status']?.toString() ?? '',
      sourceHash: json['sourceHash']?.toString() ?? '',
      boxName: metadata['boxName']?.toString() ?? '',
      folderName: metadata['folderName']?.toString() ?? '',
      folderSeq: (metadata['folderSeq'] as num?)?.toInt() ?? 0,
      projectName: metadata['projectName']?.toString(),
      title: metadata['title']?.toString(),
      imageCount: (json['imageCount'] as num?)?.toInt() ?? 0,
      imageAvailable: json['imageAvailable'] as bool? ?? false,
      hasDraft: json['hasDraft'] as bool? ?? false,
      draftImageIds: {
        for (final id in (json['draftImageIds'] as List?) ?? const [])
          if (id is num) id.toInt(),
      },
      draftMetadataDirty: json['draftMetadataDirty'] as bool? ?? false,
      template: QcMetadataTemplate.fromJson(
        (json['metadataTemplate'] as Map<String, Object?>?) ?? const {},
      ),
      metadata: metadata,
      images: ((json['images'] as List?) ?? const [])
          .whereType<Map<String, Object?>>()
          .map(QcTaskImage.fromJson)
          .toList(),
      assignedTo: (json['assignedTo'] as num?)?.toInt(),
      claimedAt: _date(json['claimedAt']),
      submittedAt: _date(json['submittedAt']) ?? DateTime.now(),
      groupId: (json['groupId']?.toString().trim().isEmpty ?? true)
          ? null
          : json['groupId'].toString().trim(),
      isExported: json['isExported'] as bool? ?? false,
      clientRework: json['clientRework'] as bool? ?? false,
    );
  }

  /// The engine sends timestamptz as ISO-8601. A malformed one must not take
  /// the whole list down, so it degrades to null.
  static DateTime? _date(Object? value) {
    final text = value?.toString();
    if (text == null || text.isEmpty) return null;
    return DateTime.tryParse(text)?.toLocal();
  }

  /// What to show as the task's name. `title` is operator-keyed and often
  /// blank early on, so the folder name is the fallback that always exists.
  String get displayName =>
      (title?.trim().isNotEmpty ?? false) ? title!.trim() : folderName;

  /// Whether ANY page can be read.
  ///
  /// [imageAvailable] means every page can, which is the right bar for "should
  /// somebody claim this" but the wrong one for "can this be opened": a folder
  /// missing a single page could not be opened at all, and opening it is the
  /// only way to remove or replace that page. A QC-inserted image does not
  /// survive a capture rework - the folder is rebuilt from what was captured -
  /// so that is not a rare corner.
  ///
  /// Falls back to [imageAvailable] when no per-image list came with the task,
  /// which is the shape the queue used before images were included.
  bool get anyImageAvailable =>
      images.isEmpty ? imageAvailable : images.any((image) => image.available);

  /// How many pages are referenced but cannot be read.
  int get missingImageCount => images.where((image) => !image.available).length;

  /// The Completed list's identifier: the Group ID once the folder has been
  /// exported, falling back to the name so a row is never blank. What the
  /// fallback MEANS is carried by [completedState] beside it.
  String get completedIdentifier => groupId ?? displayName;

  /// Why this row does or does not have a Group ID.
  ///
  /// A Group ID alone does not mean Exported: a client-rework revert clears
  /// `isExported` but KEEPS the group_id (FamilySearch wants the correction
  /// republished under the SAME ID), so a row can carry an old Group ID while
  /// the corrected package has not shipped yet. Checking groupId alone showed
  /// the green Exported chip in that window; isExported is the actual signal.
  QcCompletedState get completedState {
    if (status.toLowerCase() == 'rework') return QcCompletedState.sentBack;
    if (groupId != null) {
      return isExported
          ? QcCompletedState.exported
          : QcCompletedState.reworkPendingExport;
    }
    return QcCompletedState.awaitingExport;
  }
}
