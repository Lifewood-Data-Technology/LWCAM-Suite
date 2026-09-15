import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/services/qc_path_advice.dart';

/// Splitting the QC work and output folders across drives used to be REFUSED at
/// save time. Nothing in the engine requires one drive: every rename it and LWIP
/// perform targets a sibling built from the destination's own name, and the
/// export copies into a staging folder inside the output directory before
/// renaming within it. So the three capture roots may each have their own disk.
///
/// It stays a warning because an unintended split turns every finished package
/// into a cross-volume byte copy.
void main() {
  test('same drive says nothing', () {
    expect(
      qcSplitDriveWarning(r'D:\QC\Work', r'D:\QC\Output'),
      isNull,
    );
  });

  test('same drive in different case still says nothing', () {
    expect(qcSplitDriveWarning(r'D:\QC\Work', r'd:\Other\Output'), isNull);
  });

  test('different drives warn, and name both', () {
    final warning = qcSplitDriveWarning(r'D:\QC\Work', r'E:\QC\Output');
    expect(warning, isNotNull);
    expect(warning, contains('D:'));
    expect(warning, contains('E:'));
  });

  test('the warning says it is allowed, so nobody reads it as a failure', () {
    final warning = qcSplitDriveWarning(r'D:\Work', r'E:\Output')!;
    expect(warning.toLowerCase(), contains('allowed'));
  });

  test('a blank folder is not a warning', () {
    // Half-filled form: the missing-field check reports that, not this.
    expect(qcSplitDriveWarning('', r'E:\QC\Output'), isNull);
    expect(qcSplitDriveWarning(r'D:\QC\Work', '  '), isNull);
  });

  test('a relative path has no drive to compare', () {
    expect(qcSplitDriveWarning(r'QC\Work', r'E:\QC\Output'), isNull);
  });

  test('a UNC path is compared by its share, not rejected', () {
    expect(
      qcSplitDriveWarning(r'\\nas\captures\work', r'\\nas\captures\out'),
      isNull,
    );
  });
}
