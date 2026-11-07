import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/services/calibration_task_client.dart';
import 'package:lwcam/services/color_cal_service.dart';
import 'package:path/path.dart' as p;

void main() {
  final fixtures = Directory(
    p.absolute('../verification/calibration_protocol'),
  );
  Map<String, dynamic> fixture(String name) =>
      jsonDecode(File(p.join(fixtures.path, name)).readAsStringSync())
          as Map<String, dynamic>;
  late Directory temp, local, share;
  late CalibrationTaskClient client;
  late Map<String, dynamic> task;

  Future<void> publishResult({String name = 'succeeded.json'}) async {
    final folder = Directory(
      p.join(share.path, '.calibration', task['task_id'], 'result'),
    );
    await folder.create(recursive: true);
    await File(
      p.join(fixtures.path, 'profile.json'),
    ).copy(p.join(folder.path, 'profile.json'));
    final result = fixture(name);
    for (final key in [
      'task_id',
      'request_sha256',
      'device_id',
      'phone_serial',
      'captured_at',
      'capture_local_date',
    ]) {
      result[key] = task[key];
    }
    result['image_sha256'] = (task['image'] as Map)['sha256'];
    await File(
      p.join(folder.parent.path, 'result.json'),
    ).writeAsString(jsonEncode(result));
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('calibration_protocol_');
    local = Directory(p.join(temp.path, 'local'));
    share = Directory(p.join(temp.path, 'share'));
    await share.create();
    client = CalibrationTaskClient(
      local,
      share.path,
      pollInterval: const Duration(milliseconds: 5),
    );
    final request = fixture('request.json');
    final now = DateTime.now().toLocal();
    // UTC timestamp with a matching capture-PC date is enough for these tests;
    // production submits the explicit local offset.
    request['captured_at'] = now.toUtc().toIso8601String();
    request['capture_local_date'] = now.toIso8601String().substring(0, 10);
    task = await client.submit(
      File(p.join(fixtures.path, 'chart.jpg')),
      request,
    );
    UploadStatsDB().debugOverrideBaseFolderForTests(temp.path);
  });
  tearDown(() async {
    client.cancel();
    await temp.delete(recursive: true);
  });

  test(
    'submission publishes exact byte digest and ready last; absent result is pending',
    () async {
      final folder = p.join(share.path, '.calibration', task['task_id']);
      final raw = await File(p.join(folder, 'request.json')).readAsBytes();
      final ready =
          jsonDecode(await File(p.join(folder, 'ready.json')).readAsString())
              as Map;
      expect(ready['request_sha256'], sha256.convert(raw).toString());
      expect(await client.readResult(task), isNull);
      expect(task['submitted'], isTrue);
    },
  );

  test(
    'shared success fixture downloaded, not activated, and survives client restart',
    () async {
      await publishResult();
      final restarted = CalibrationTaskClient(local, share.path);
      final pending = await restarted.pending('phone-1');
      expect(pending!['task_id'], task['task_id']);
      final result = await restarted.readResult(pending);
      expect(result!['ok'], isTrue);
      expect(
        (result['profile'] as Map)['source_task']['request_sha256'],
        task['request_sha256'],
      );
      expect(await ColorCalService().loadActive(), isNull);
    },
  );

  test('shared failed result preserves stable algorithm error', () async {
    await publishResult(name: 'failed.json');
    final result = await client.readResult(task);
    expect(result!['ok'], isFalse);
    expect((result['error'] as Map)['code'], 'no_chart_found');
  });

  test('shared corrupt result fixture is rejected', () async {
    final folder = p.join(share.path, '.calibration', task['task_id']);
    await File(
      p.join(fixtures.path, 'corrupt-result.json'),
    ).copy(p.join(folder, 'result.json'));
    await expectLater(client.readResult(task), throwsStateError);
  });

  test(
    'changed phone, request hash, and unsafe file each fail closed',
    () async {
      for (final change in ['phone_serial', 'request_sha256', 'path']) {
        await publishResult();
        final file = File(
          p.join(share.path, '.calibration', task['task_id'], 'result.json'),
        );
        final result = jsonDecode(await file.readAsString()) as Map;
        if (change == 'path') {
          result['files']['profile.json']['name'] = '../profile.json';
        } else {
          result[change] = 'changed';
        }
        await file.writeAsString(jsonEncode(result));
        await expectLater(client.readResult(task), throwsStateError);
      }
    },
  );

  test('damaged profile cannot be used', () async {
    await publishResult();
    await File(
      p.join(
        share.path,
        '.calibration',
        task['task_id'],
        'result',
        'profile.json',
      ),
    ).writeAsString('{}');
    await expectLater(client.readResult(task), throwsStateError);
  });

  test('retake supersedes old task and keeps old photograph', () async {
    final old = task;
    task = await client.submit(
      File(p.join(fixtures.path, 'chart.jpg')),
      fixture('request.json'),
    );
    expect((await client.pending('phone-1'))!['task_id'], task['task_id']);
    expect(File(p.join(old['local_path'], 'chart.jpg')).existsSync(), isTrue);
    expect(
      File(p.join(local.path, '${old['task_id']}.abandoned.json')).existsSync(),
      isTrue,
    );
    await expectLater(
      client.accepted('phone-1', old['task_id']),
      throwsStateError,
    );
  });

  test('cancel only stops local waiting; published request survives', () async {
    final waiting = client.wait(task);
    client.cancel();
    await expectLater(waiting, throwsStateError);
    expect(
      File(
        p.join(share.path, '.calibration', task['task_id'], 'ready.json'),
      ).existsSync(),
      isTrue,
    );
    expect(await client.pending('phone-1'), isNotNull);
  });

  test(
    'confirmation validates again, activates once and acknowledges pointer',
    () async {
      await publishResult();
      final result = (await client.readResult(task))!;
      final active = ActiveProfile.fromProfileJson(
        result['profile'],
        result['profile_path'],
      );
      final service = ColorCalService(
        localOverride: local,
        destinationOverride: share.path,
      );
      await service.setActive(active);
      expect((await service.loadActive())!.profileId, active.profileId);
      expect(await client.pending('phone-1'), isNull);
      await expectLater(service.setActive(active), throwsStateError);
    },
  );

  test('legacy or yesterday profile cannot be confirmed', () async {
    await publishResult();
    final result = (await client.readResult(task))!;
    final values = ActiveProfile.fromProfileJson(
      result['profile'],
      result['profile_path'],
    ).toJson();
    values['calibrated_at'] = DateTime.now()
        .subtract(const Duration(days: 1))
        .toIso8601String();
    await expectLater(
      ColorCalService(
        localOverride: local,
        destinationOverride: share.path,
      ).setActive(ActiveProfile.fromJson(values)),
      throwsStateError,
    );
  });

  test(
    'ready marker conflict is rejected instead of overwriting committed work',
    () async {
      final ready = File(
        p.join(share.path, '.calibration', task['task_id'], 'ready.json'),
      );
      await ready.writeAsString(jsonEncode(fixture('corrupt-ready.json')));
      await expectLater(client.publish(task), throwsStateError);
      expect(
        jsonDecode(await ready.readAsString())['request_sha256'],
        '0' * 64,
      );
    },
  );

  test(
    'confirmation rejects changed parameters even with the same profile ID',
    () async {
      await publishResult();
      final result = (await client.readResult(task))!;
      final profile = Map<String, dynamic>.from(result['profile'] as Map);
      profile['white_balance'] = [1.1, 1.0, 1.0];
      final active = ActiveProfile.fromProfileJson(
        profile,
        result['profile_path'],
      );
      await expectLater(
        ColorCalService(
          localOverride: local,
          destinationOverride: share.path,
        ).setActive(active),
        throwsStateError,
      );
      expect(await ColorCalService().loadActive(), isNull);
    },
  );

  test(
    'legacy and damaged activation files do not activate automatically',
    () async {
      final directory = Directory(
        p.join(
          temp.path,
          'color_cal',
          base64Url.encode(utf8.encode('default')).replaceAll('=', ''),
        ),
      );
      await directory.create(recursive: true);
      final file = File(p.join(directory.path, 'active.json'));
      await file.writeAsString('broken');
      expect(await ColorCalService().loadActive(), isNull);
      final legacy = ActiveProfile.fromProfileJson(
        fixture('profile.json'),
        'old.json',
      );
      await file.writeAsString(jsonEncode(legacy.toJson()));
      expect(await ColorCalService().loadActive(), isNull);
    },
  );
}
