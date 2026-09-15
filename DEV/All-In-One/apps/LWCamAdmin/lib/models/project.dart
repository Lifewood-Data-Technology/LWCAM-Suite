/// Project domain model (Project -> Boxes -> Folders -> Images). Pure Dart —
/// lives in the same shared users-store JSON as [AppUser]/[UsersStore].
library;

import 'dart:math';

import 'metadata_template.dart';

/// Internal immutable identity for a project. All references (user
/// assignments, box stamping) use this — renaming [Project.projectId] or
/// [Project.name] never breaks a link. Not cryptographically unique, but
/// collision-proof enough for a single shared store (time + random).
String generateProjectKey() {
  final millis = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final rand = Random().nextInt(0x7fffffff).toRadixString(36);
  return 'p$millis$rand';
}

class Project {
  final String key;
  final String projectId;
  final String name;

  /// Country + location mixed into one short code (cloud
  /// `projects.country_location_code`, VARCHAR(32) UNIQUE). Free text, set by
  /// SuperAdmin at creation. Nullable only for projects created before the
  /// field existed — the edit dialog forces one on next save, and the cloud
  /// sync skips code-less projects.
  final String? countryLocationCode;
  final DateTime startDate;

  /// Best-effort advisory flag: a box has been created under this project on
  /// some operator PC. Box data itself is per-device local SQLite, so this
  /// can under-report (false negative) if the stamp write raced or failed —
  /// it is only ever used to decide whether to show a stronger delete
  /// confirmation, never to gate correctness.
  final bool hasData;
  final DateTime? createdAt;
  final String? createdBy;

  /// The project's metadata template (which fields, types, fixed values,
  /// options, order, mandatory-ness — see metadata_template.dart). Null
  /// means "use the built-in standard template" (today's SA behaviour).
  final MetadataTemplate? template;

  const Project({
    required this.key,
    required this.projectId,
    required this.name,
    required this.startDate,
    this.countryLocationCode,
    this.hasData = false,
    this.createdAt,
    this.createdBy,
    this.template,
  });

  Project copyWith({
    String? projectId,
    String? name,
    String? countryLocationCode,
    DateTime? startDate,
    bool? hasData,
    MetadataTemplate? template,
    bool clearTemplate = false,
  }) {
    return Project(
      key: key,
      projectId: projectId ?? this.projectId,
      name: name ?? this.name,
      countryLocationCode: countryLocationCode ?? this.countryLocationCode,
      startDate: startDate ?? this.startDate,
      hasData: hasData ?? this.hasData,
      createdAt: createdAt,
      createdBy: createdBy,
      template: clearTemplate ? null : (template ?? this.template),
    );
  }

  Map<String, Object?> toJson() => {
    'key': key,
    'projectId': projectId,
    'name': name,
    'countryLocationCode': countryLocationCode,
    'startDate': startDate.toIso8601String(),
    'hasData': hasData,
    'createdAt': createdAt?.toIso8601String(),
    'createdBy': createdBy,
    'template': template?.toJson(),
  };

  factory Project.fromJson(Map<String, Object?> json) {
    final rawTemplate = json['template'];
    return Project(
      key: json['key']?.toString() ?? '',
      projectId: json['projectId']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      countryLocationCode: json['countryLocationCode']?.toString(),
      startDate: DateTime.tryParse(json['startDate']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      hasData: json['hasData'] as bool? ?? false,
      createdAt: DateTime.tryParse(json['createdAt']?.toString() ?? ''),
      createdBy: json['createdBy']?.toString(),
      template: rawTemplate is Map
          ? MetadataTemplate.fromJson(rawTemplate.cast<String, Object?>())
          : null,
    );
  }
}
