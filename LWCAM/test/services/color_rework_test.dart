import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/services/color_capture_session.dart';
import 'package:lwcam/services/color_rework_store.dart';
import 'package:lwcam/services/processing_marker_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('color_rework_');
    UploadStatsDB().debugOverrideBaseFolderForTests(root.path);
  });
  tearDown(() async {
    await root.delete(recursive: true);
  });
  test('durable recapture detects changes to both image and binding', () async {
    final source = await File(
      p.join(root.path, 'shot.jpg'),
    ).writeAsBytes([1, 2, 3]);
    final staged = await ColorReworkStore.stage(
      'station',
      'target.jpg',
      source,
      ColorBinding.none('skipped'),
    );
    expect(
      (await ColorReworkStore.pending('station', 'target.jpg'))?.path,
      staged.path,
    );
    await File('${staged.path}.color.json').writeAsString('{}');
    await expectLater(
      ColorReworkStore.pending('station', 'target.jpg'),
      throwsStateError,
    );
  });
  test(
    'only the recaptured page changes; legacy calibration stays with others',
    () async {
      await File(p.join(root.path, 'a.jpg')).writeAsBytes([1]);
      await File(p.join(root.path, 'b.jpg')).writeAsBytes([2]);
      final marker = File(p.join(root.path, kProcessingMarkerName));
      await marker.writeAsString(
        jsonEncode({
          'image_count': 2,
          'color_profile': {'profile_id': 'old', 'calibrated_today': true},
        }),
      );
      await setReworkInProgress(root.path, true, requireReadable: true);
      await updateReworkColorBinding(
        root.path,
        'b.jpg',
        ColorBinding.none('skipped'),
      );
      final held = jsonDecode(await marker.readAsString()) as Map;
      expect(held['rework_in_progress'], true);
      final block = held['color_calibration'] as Map;
      expect(block['images']['a.jpg']['profile'], isNotNull);
      expect(block['images']['b.jpg']['reason'], 'skipped');
      await setReworkInProgress(root.path, false, requireReadable: true);
      expect(
        (jsonDecode(await marker.readAsString()) as Map)['rework_in_progress'],
        isNull,
      );
    },
  );
  test(
    'missing or unreadable marker cannot admit a recapture overwrite',
    () async {
      await expectLater(
        setReworkInProgress(root.path, true, requireReadable: true),
        throwsStateError,
      );
      await File(
        p.join(root.path, kProcessingMarkerName),
      ).writeAsString('broken');
      await expectLater(
        setReworkInProgress(root.path, true, requireReadable: true),
        throwsStateError,
      );
    },
  );
}
