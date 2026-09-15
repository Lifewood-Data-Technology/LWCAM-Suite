import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/controllers/qc_review_controller.dart';
import 'package:lwcam/models/qc_task.dart';

/// Changing the title has to move every field the project maps from it, in the
/// form, immediately - not only once the engine has been asked to save.
///
/// Built from the DEMO01 project's real template row: Record Type, Start Date
/// and End Date are all `mode: mapped` from Title. Note that the two WWI titles
/// map to the SAME dates, so a title change between them moves Record Type
/// alone - which is worth encoding, because "the dates did not change" is the
/// correct behaviour there and not a bug.
Map<String, Object?> demo01Template() => {
      'fields': [
        {
          'key': 'title',
          'label': 'Title',
          'input': 'select',
          'mandatory': true,
          'options': [
            'WWI South African Mounted Rifles Military Indexes',
            'WWI South African Mounted Rifles Military Personnel Cards',
            'WWI Medical Files',
            'WWII Medical Files',
          ],
        },
        {
          'key': 'recordType',
          'label': 'Record Type',
          'input': 'mapped',
          'mappedFrom': 'title',
          'valueMap': {
            'WWI Medical Files': 'Military Medical Records',
            'WWII Medical Files': 'Military Medical Records',
            'WWI South African Mounted Rifles Military Indexes':
                'Military Service Record Indexes',
            'WWI South African Mounted Rifles Military Personnel Cards':
                'Military Service Records',
          },
        },
        {
          'key': 'startDate',
          'label': 'Start Date',
          'input': 'mapped',
          'mandatory': true,
          'mappedFrom': 'title',
          'valueMap': {
            'WWI Medical Files': '1914',
            'WWII Medical Files': '1939',
            'WWI South African Mounted Rifles Military Indexes': '1914',
            'WWI South African Mounted Rifles Military Personnel Cards': '1914',
          },
        },
        {
          'key': 'endDate',
          'label': 'End Date',
          'input': 'mapped',
          'mandatory': true,
          'mappedFrom': 'title',
          'valueMap': {
            'WWI Medical Files': '1918',
            'WWII Medical Files': '1945',
            'WWI South African Mounted Rifles Military Indexes': '1918',
            'WWI South African Mounted Rifles Military Personnel Cards': '1918',
          },
        },
      ],
    };

QcReviewController demo01Controller({String title = 'WWI Medical Files'}) {
  final controller = QcReviewController(7);
  controller.task.value = QcTask.fromJson({
    'id': 7,
    'status': 'pending',
    'sourceHash': 'a' * 64,
    'assignedTo': 3,
    'metadata': <String, Object?>{
      'folderId': 7,
      'title': title,
      'recordType': 'Military Medical Records',
      'startDate': '1914',
      'endDate': '1918',
    },
    'metadataTemplate': demo01Template(),
    'images': <Object?>[],
  });
  return controller;
}

void main() {
  // NOTE: setting `task.value` does not populate `form` - only the private
  // _adopt does, and it is reachable solely through load()/an image op, both of
  // which need the engine. So each test establishes the starting title through
  // setField, which is the same call the Title dropdown makes. _adopt's own
  // derivation on load is covered at the unit level by
  // qc_template_mapping_test's "overwrites a stale stored value" case.
  test('changing the title moves the record type it maps to', () {
    final controller = demo01Controller();
    controller.setField('title', 'WWI Medical Files');
    expect(controller.form['recordType'], 'Military Medical Records');

    controller.setField(
        'title', 'WWI South African Mounted Rifles Military Indexes');

    expect(controller.form['recordType'], 'Military Service Record Indexes');
  });

  test('two titles sharing a date pair legitimately leave the dates alone', () {
    // Both WWI titles map to 1914/1918. Nothing moving here is CORRECT, and is
    // asserted out loud so it is not mistaken for a broken mapping.
    final controller = demo01Controller();
    controller.setField('title', 'WWI Medical Files');
    expect(controller.form['startDate'], '1914');
    expect(controller.form['endDate'], '1918');

    controller.setField(
        'title', 'WWI South African Mounted Rifles Military Indexes');

    expect(controller.form['startDate'], '1914');
    expect(controller.form['endDate'], '1918');
  });

  test('a title that maps to different dates moves all three fields', () {
    final controller = demo01Controller();
    controller.setField('title', 'WWI Medical Files');

    controller.setField('title', 'WWII Medical Files');

    expect(controller.form['recordType'], 'Military Medical Records');
    expect(controller.form['startDate'], '1939');
    expect(controller.form['endDate'], '1945');
  });

  test("a mapped field is never left holding the previous title's value", () {
    // The failure that would look like "the mapping did not update": a stale
    // derived value surviving a title change.
    final controller = demo01Controller();
    controller.setField(
        'title', 'WWI South African Mounted Rifles Military Personnel Cards');
    expect(controller.form['recordType'], 'Military Service Records');

    controller.setField('title', 'WWI Medical Files');

    expect(controller.form['recordType'], 'Military Medical Records');
  });

  test('the derived change marks the form dirty so it can be saved', () {
    final controller = demo01Controller();
    controller.setField('title', 'WWI Medical Files');
    controller.dirty.value = false;

    controller.setField(
        'title', 'WWI South African Mounted Rifles Military Indexes');

    expect(controller.dirty.value, isTrue);
  });
}
