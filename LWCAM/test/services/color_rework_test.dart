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
  test('empty legacy marker gains identity; damaged or foreign marker stays protected', () async {
    final marker = File(p.join(root.path, kProcessingMarkerName));
    final identity = <String,dynamic>{'project_key':'p','box_name':'b','folder_seq':1};
    await marker.writeAsString('\uFEFF');
    await ensureReworkCaptureMarker(root.path, identity);
    final data = jsonDecode(await marker.readAsString()) as Map;
    expect(data['project_key'], 'p');
    expect(data['rework_in_progress'], isTrue);
    await expectLater(ensureReworkCaptureMarker(root.path, {...identity,'folder_seq':2}), throwsStateError);
    await marker.writeAsString('{broken');
    await expectLater(ensureReworkCaptureMarker(root.path, identity), throwsStateError);
    expect(await marker.readAsString(), '{broken');
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
  test('discardStaged removes only the matching intent and keeps the photo',
      () async {
    final source = await File(
      p.join(root.path, 'shot-discard.jpg'),
    ).writeAsBytes([4, 5, 6]);
    final staged = await ColorReworkStore.stage(
      'station',
      'target.jpg',
      source,
      ColorBinding.none('skipped'),
    );
    expect(ColorReworkStore.isStoreFile(staged), isTrue);
    expect(await ColorReworkStore.pending('station', 'target.jpg'), isNotNull);

    await ColorReworkStore.discardStaged(staged);

    expect(await ColorReworkStore.pending('station', 'target.jpg'), isNull);
    expect(await staged.exists(), isTrue);
    await ColorReworkStore.discardStaged(staged); // idempotent
  });
  test('discarding an older generation leaves the newer intent alone',
      () async {
    final source = await File(
      p.join(root.path, 'shot-generation.jpg'),
    ).writeAsBytes([7, 8, 9]);
    final first = await ColorReworkStore.stage(
      'station',
      'target.jpg',
      source,
      ColorBinding.none('skipped'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final second = await ColorReworkStore.stage(
      'station',
      'target.jpg',
      source,
      ColorBinding.none('skipped'),
    );
    expect(second.path, isNot(first.path));

    await ColorReworkStore.discardStaged(first);
    expect(
      (await ColorReworkStore.pending('station', 'target.jpg'))?.path,
      second.path,
    );
    await ColorReworkStore.discardStaged(second);
    expect(await ColorReworkStore.pending('station', 'target.jpg'), isNull);
  });
  test('complete with a generation guard does not delete a newer intent',
      () async {
    final source = await File(
      p.join(root.path, 'shot-complete.jpg'),
    ).writeAsBytes([10, 11, 12]);
    final first = await ColorReworkStore.stage(
      'station',
      'target.jpg',
      source,
      ColorBinding.none('skipped'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 2));
    final second = await ColorReworkStore.stage(
      'station',
      'target.jpg',
      source,
      ColorBinding.none('skipped'),
    );

    await ColorReworkStore.complete(
      'station',
      'target.jpg',
      staged: first,
    );
    expect(
      (await ColorReworkStore.pending('station', 'target.jpg'))?.path,
      second.path,
    );
    await ColorReworkStore.complete(
      'station',
      'target.jpg',
      staged: second,
    );
    expect(await ColorReworkStore.pending('station', 'target.jpg'), isNull);
  });
  test('discardStaged refuses a file outside the recapture store', () async {
    final outside = File(p.join(root.path, 'intent.json'))
      ..writeAsStringSync('{}');
    expect(ColorReworkStore.isStoreFile(outside), isFalse);
    await expectLater(
      ColorReworkStore.discardStaged(outside),
      throwsStateError,
    );
  });
  test('an applied target is distinguished from abandoned staging', () async {
    final source = await File(p.join(root.path, 'shot-applied.jpg'))
        .writeAsBytes([1, 2, 3]);
    final target = await File(p.join(root.path, 'target-applied.jpg'))
        .writeAsBytes([1, 2, 3]);
    final staged = await ColorReworkStore.stage(
      'station',
      target.path,
      source,
      ColorBinding.none('disabled'),
    );
    expect(
      await ColorReworkStore.stagedMayHaveBeenApplied('station', target.path),
      isTrue,
    );

    await target.writeAsBytes([9]);
    expect(
      await ColorReworkStore.stagedMayHaveBeenApplied('station', target.path),
      isFalse,
      reason: 'the target still holds different bytes, so this is abandoned '
          'staging, not an applied recapture',
    );

    await target.delete();
    expect(
      await ColorReworkStore.stagedMayHaveBeenApplied('station', target.path),
      isFalse,
    );
    await File('${staged.path}.color.json').writeAsString('{}');
    await expectLater(
      ColorReworkStore.stagedMayHaveBeenApplied('station', target.path),
      completion(isFalse),
    );

    final noIntent = await File(p.join(root.path, 'target-no-intent.jpg'))
        .writeAsBytes([1, 2, 3]);
    expect(
      await ColorReworkStore.stagedMayHaveBeenApplied(
        'station',
        noIntent.path,
      ),
      isFalse,
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
