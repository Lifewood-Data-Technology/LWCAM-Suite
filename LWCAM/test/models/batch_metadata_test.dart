import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/batch_metadata.dart';

void main() {
  group('recordTypeForTitle (§8.4)', () {
    test('maps all four titles', () {
      expect(recordTypeForTitle('WWI South African Mounted Rifles Military Personnel Cards'),
          'Military Service Records');
      expect(recordTypeForTitle('WWI South African Mounted Rifles Military Indexes'),
          'Military Service Record Indexes');
      expect(recordTypeForTitle('WWI Medical Files'), 'Military Medical Records');
      expect(recordTypeForTitle('WWII Medical Files'), 'Military Medical Records');
    });

    test('unknown / null title → null', () {
      expect(recordTypeForTitle('Something else'), isNull);
      expect(recordTypeForTitle(null), isNull);
    });
  });

  group('csvEscape', () {
    test('leaves plain values untouched', () {
      expect(csvEscape('Vol 1'), 'Vol 1');
      expect(csvEscape(null), '');
    });

    test('quotes and doubles internal quotes for special chars', () {
      expect(csvEscape('a,b'), '"a,b"');
      expect(csvEscape('say "hi"'), '"say ""hi"""');
      expect(csvEscape('line1\nline2'), '"line1\nline2"');
    });
  });
}
