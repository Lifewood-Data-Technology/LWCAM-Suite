import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/capture_box_models.dart';
import 'package:lwcam/models/metadata_template.dart';

CaptureFolder _folder({int id = 0, String? volume, String? title = 'WWI Medical Files'}) {
  return CaptureFolder(
    id: id,
    boxId: 1,
    coverTag: 'Cover Will Be Captured',
    title: title,
    volume: volume,
    startDate: '1914',
    endDate: '1918',
  );
}

void main() {
  group('computeFolderNames', () {
    // The folder name IS the Volume now. It used to be
    // "<boxDetails> - <fileNo> - 0001", parsed out of a "file no." marker,
    // with "(unknown file [N])" for anything numberless - one client's
    // convention that no other project could opt out of.
    test('the name is the Volume, verbatim', () {
      final names = computeFolderNames('BOX A', [
        _folder(volume: 'ASC Baptisms 1899'),
        _folder(volume: 'ASC Marriages 1901-1904'),
      ]);
      expect(names, ['ASC Baptisms 1899', 'ASC Marriages 1901-1904']);
    });

    // Not cosmetic: the name becomes a real directory under the destination
    // (TransferController._destPathFor joins it), so two folders sharing one
    // name would merge their images into a single directory.
    test('a repeated Volume is disambiguated, the first keeping the bare name', () {
      final names = computeFolderNames('BOX A', [
        _folder(volume: 'Register 12'),
        _folder(volume: 'Register 34'),
        _folder(volume: 'Register 12'),
      ]);
      expect(names, ['Register 12', 'Register 34', 'Register 12 - 0002']);
      expect(names.toSet().length, 3);
    });

    test('two Volumes that sanitize to the same string still get separate '
        'directories', () {
      final names = computeFolderNames('BOX A', [
        _folder(volume: 'A/B'),
        _folder(volume: 'A:B'),
      ]);
      expect(names.toSet().length, 2,
          reason: 'sanitizing collapses both, so the guard must key on the '
              'sanitized name, not the raw Volume');
    });

    test('a blank Volume falls back to the group details', () {
      final names = computeFolderNames('BOX A', [
        _folder(volume: '   '),
        _folder(volume: null),
        _folder(volume: 'Register 7'),
      ]);
      expect(names, ['BOX A', 'BOX A - 0002', 'Register 7']);
    });

    test('names are Windows-sanitized', () {
      final names = computeFolderNames('BOX:A', [_folder(volume: 'Reg 1<2')]);
      expect(names.single.contains('<'), isFalse);
      expect(names.single.contains(':'), isFalse);
    });

    // Prep persists these names and re-runs on a retry. It no longer rewrites
    // the Volume at all, so a second pass sees identical input - but assert it,
    // because the previous design DID rewrite it and drifted the name.
    test('a re-prep of the same folders produces identical names', () {
      const details = 'BOX A';
      final volumes = ['Register 4444', '', 'Register 4455', 'Register 4444'];
      List<String> run() => computeFolderNames(
          details, [for (final v in volumes) _folder(volume: v)]);
      expect(run(), run());
      expect(run(), [
        'Register 4444',
        'BOX A',
        'Register 4455',
        'Register 4444 - 0002',
      ]);
    });

    // Windows directories are case-insensitive, so these two resolve to ONE
    // directory on disk. Keying the set on the exact string let both keep the
    // bare name and merge their images.
    test('a Volume repeated in a different case is still disambiguated', () {
      final names = computeFolderNames('BOX A', [
        _folder(volume: 'Register 12'),
        _folder(volume: 'register 12'),
      ]);
      expect(names.first, 'Register 12');
      expect(names.map((n) => n.toLowerCase()).toSet().length, 2,
          reason: 'Windows would treat these as the same directory');
    });

    // The destination is <root>\<YYYYMMDD>\<folderName>: a shared day
    // folder with nothing identifying the group, so a name repeated by another
    // group transferred the same day is a merged directory.
    test('a name another group already holds is disambiguated', () {
      final names = computeFolderNames(
        'BOX B',
        [_folder(volume: 'Register 1')],
        reserved: {'register 1'},
      );
      expect(names.single, 'Register 1 - 0002');
    });

    test('reserved names are matched case-insensitively', () {
      final names = computeFolderNames(
        'BOX B',
        [_folder(volume: 'REGISTER 1')],
        reserved: {'register 1'},
      );
      expect(names.single, 'REGISTER 1 - 0002');
    });

    test('nothing reserved leaves the Volume untouched', () {
      expect(
          computeFolderNames('B2', [_folder(volume: 'Register 1')]).single,
          'Register 1');
    });
  });

  group('CaptureFolder.copyWith', () {
    // The New Group flow keys folder 1 before the box exists (boxId 0) and
    // re-homes the draft afterwards. It used to rebuild the folder and list
    // the fields to carry, which dropped Record Type: folder 1 opened as a
    // draft "missing: Record Type" and only stuck once the operator edited
    // and saved it again. Re-homing must carry EVERY field.
    test('re-homing to a new boxId carries every keyed field', () {
      const draft = CaptureFolder(
        boxId: 0,
        coverTag: 'Cover Will Be Captured',
        imageTags: 'Faded or Damaged Documents',
        title: 'Baptism of North Perak',
        volume: 'Volume 1',
        startDate: '1930',
        endDate: '1950',
        archivalRefNo: 'ARN-1',
        recordType: 'Baptism Records',
      );
      final homed = draft.copyWith(boxId: 42);
      expect(homed.boxId, 42);
      expect(homed.recordType, 'Baptism Records');
      expect(homed.coverTag, draft.coverTag);
      expect(homed.imageTags, draft.imageTags);
      expect(homed.title, draft.title);
      expect(homed.volume, draft.volume);
      expect(homed.startDate, draft.startDate);
      expect(homed.endDate, draft.endDate);
      expect(homed.archivalRefNo, draft.archivalRefNo);
    });

    test('boxId is preserved when not given', () {
      const f = CaptureFolder(boxId: 7, recordType: 'Baptism Records');
      expect(f.copyWith(title: 'T').boxId, 7);
    });
  });

  group('CaptureFolder', () {
    // Mandatory-field completeness and Record Type are now TEMPLATE-DRIVEN
    // (see MetadataTemplate in metadata_template.dart) rather than
    // CaptureFolder getters — these tests use the built-in standard
    // template, which reproduces the old spec §8.1/§8.4 behaviour exactly
    // (see metadata_template_test.dart for the template-level coverage).
    final standardTemplate = MetadataTemplate.standard();

    test('missingMandatoryFieldsOf mirrors spec §8.1 via the standard template', () {
      const empty = CaptureFolder(boxId: 1);
      expect(standardTemplate.missingMandatoryFieldsOf(empty),
          ['Cover Tag', 'Title', 'Volume', 'Start Date', 'End Date']);
      expect(standardTemplate.isCompleteOf(_folder(volume: 'Register 1')), isTrue);
    });

    test('Record Type (mapped from Title) derives via effectiveValueOf',
        () {
      final f = _folder(volume: 'Register 9', title: 'WWI Medical Files');
      expect(standardTemplate.effectiveValueOf(kRecordTypeFieldId, f), 'Military Medical Records');
    });

    test('toDbMap/fromDbMap round-trip', () {
      final f = CaptureFolder(
        id: 5,
        boxId: 2,
        folderSeq: 3,
        coverTag: 'Cover Will Be Captured',
        imageTags: 'Reflective Surface',
        title: 'WWII Medical Files',
        volume: 'V file no. 8',
        startDate: '1939',
        endDate: '1945',
        archivalRefNo: 'ARN-1',
        folderName: 'BOX - 8 - 0001',
        createdAt: DateTime(2026, 7, 9),
        updatedAt: DateTime(2026, 7, 9, 12),
      );
      final map = f.toDbMap(isComplete: standardTemplate.isCompleteOf(f))
        ..['id'] = f.id
        ..['created_at'] = f.createdAt!.toIso8601String()
        ..['updated_at'] = f.updatedAt!.toIso8601String();
      final back = CaptureFolder.fromDbMap(map);
      expect(back.id, 5);
      expect(back.boxId, 2);
      expect(back.folderSeq, 3);
      expect(back.volume, 'V file no. 8');
      expect(back.folderName, 'BOX - 8 - 0001');
      expect(map['is_complete'], 1);
    });
  });

  group('CaptureBox', () {
    test('fromDbMap + status', () {
      final b = CaptureBox.fromDbMap({
        'id': 7,
        'device_id': 'SAX01',
        'box_name': 'BOX A',
        'status': 'TRANSFERRED',
        'user_id': 'alice',
        'project_id': 'PRJ-1',
        'created_at': DateTime(2026, 7, 9).toIso8601String(),
        'transfer_end_at': DateTime(2026, 7, 10).toIso8601String(),
        'transferred_to': r'D:\dest\20260710',
      });
      expect(b.id, 7);
      expect(b.transferredTo, r'D:\dest\20260710');
      expect(b.boxDetails, 'BOX A');
      expect(b.scanningOpr, 'alice');
      expect(b.projectId, 'PRJ-1');
      expect(b.isTransferred, isTrue);
      expect(b.transferredAt, DateTime(2026, 7, 10));
    });
  });
}
