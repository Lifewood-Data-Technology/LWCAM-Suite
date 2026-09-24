import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/transfer_destination_service.dart';
import 'package:path/path.dart' as p;

void main() {
  group('TransferDestinationService', () {
    test('builds a day folder', () {
      final date = DateTime(2026, 6, 15);

      expect(TransferDestinationService.dayFolderName(date), '20260615');
      expect(
        TransferDestinationService.directoryForDate(
          p.join('X:', 'Images'),
          date,
        ).path,
        p.join('X:', 'Images', '20260615'),
      );
    });

    test('pads single-digit month/day', () {
      expect(
        TransferDestinationService.dayFolderName(DateTime(2026, 1, 5)),
        '20260105',
      );
    });
  });
}
