import 'package:path/path.dart' as p;

/// Warns when the QC work and output folders sit on different drives.
///
/// This was a hard refusal until it was checked against the engine. Nothing
/// there requires one drive: every rename the QC backend and LWIP perform
/// targets a SIBLING built from the destination's own name (`with_name(...)`),
/// and the export's one cross-root step copies into a staging folder inside the
/// output directory before renaming within it. So 1.Images, 2.Batches and
/// 3.Export can each live on their own disk, which is a sensible layout when one
/// of them is a fast scratch disk.
///
/// It stays a warning because an UNINTENDED split is worth knowing about: every
/// finished package then crosses volumes as a real byte copy. On separate
/// physical disks that is usually a win; on two partitions of one disk it is
/// pure cost.
///
/// Returns null when both are on the same drive, either path is blank, or either
/// is relative (a relative path has no drive to compare, and the folder pickers
/// only ever produce absolute ones).
String? qcSplitDriveWarning(String workFolder, String outputFolder) {
  final work = workFolder.trim();
  final output = outputFolder.trim();
  if (work.isEmpty || output.isEmpty) return null;

  final workDrive = p.rootPrefix(work);
  final outputDrive = p.rootPrefix(output);
  if (workDrive.isEmpty || outputDrive.isEmpty) return null;
  if (p.equals(workDrive, outputDrive)) return null;

  return 'The QC work folder and output folder are on different drives '
      '($workDrive and $outputDrive). This is allowed, and is worth it when one '
      'is a fast scratch disk - but every finished package is copied across '
      'volumes rather than moved. If that was not deliberate, put both on the '
      'same drive.';
}
