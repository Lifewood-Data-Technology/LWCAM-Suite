import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';
import 'safe_copy.dart';

/// Files only. The capture PC neither runs Python nor contacts the LWIP console.
class CalibrationTaskClient {
  CalibrationTaskClient(
    this.local,
    this.destination, {
    this.pollInterval = const Duration(seconds: 2),
  });
  final Directory local;
  final String destination;
  final Duration pollInterval;
  int _generation = 0;
  void cancel() => _generation++;
  String _hash(List<int> data) => sha256.convert(data).toString();
  Future<void>? _access;
  Future<T> _bounded<T>(Future<T> Function() operation) async {
    // A timed-out SMB call cannot be cancelled by dart:io. Keep its barrier,
    // so polling never creates an unbounded backlog of outstanding OS calls.
    while (_access != null) {
      await _access!.timeout(const Duration(seconds: 15));
    }
    final value = operation();
    final barrier = value.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    _access = barrier;
    unawaited(
      barrier.then((_) {
        if (identical(_access, barrier)) _access = null;
      }),
    );
    return value.timeout(const Duration(seconds: 15));
  }

  Future<void> _plain(String path) async {
    final type = await _bounded(
      () => FileSystemEntity.type(longPath(path), followLinks: false),
    );
    if (type == FileSystemEntityType.link) {
      throw StateError('Calibration links are not allowed');
    }
  }

  String _key(String phone) => _hash(utf8.encode(phone));
  File _pointer(String phone) =>
      File(p.join(local.path, 'pending_${_key(phone)}.json'));

  Future<Map<String, dynamic>?> pending(String phone) async {
    final file = _pointer(phone);
    if (!await file.exists()) return null;
    final task = Map<String, dynamic>.from(
      jsonDecode(await file.readAsString()) as Map,
    );
    return task['accepted'] == true ? null : task;
  }

  Future<void> accepted(String phone, String taskId) async {
    final task = await pending(phone);
    if (task?['task_id'] != taskId) {
      throw StateError('Calibration task was superseded');
    }
    task!['accepted'] = true;
    await writeStringAtomic(_pointer(phone).path, jsonEncode(task));
  }

  Future<Map<String, dynamic>> submit(
    File image,
    Map<String, dynamic> request,
  ) async {
    if (destination.trim().isEmpty) {
      throw StateError('Image destination is not configured');
    }
    final generation = ++_generation;
    await local.create(recursive: true);
    final id = const Uuid().v4();
    final work = Directory(p.join(local.path, id));
    await work.create();
    final bytes = await image.readAsBytes();
    if (bytes.isEmpty || bytes.length > 128 * 1024 * 1024) {
      throw StateError('Invalid chart image size');
    }
    await File(p.join(work.path, 'chart.jpg')).writeAsBytes(bytes, flush: true);
    final body = {
      ...request,
      'version': 1,
      'task_id': id,
      'image': {
        'name': 'chart.jpg',
        'size': bytes.length,
        'sha256': _hash(bytes),
      },
    };
    final raw = utf8.encode(jsonEncode(body));
    final task = {
      ...body,
      'request_sha256': _hash(raw),
      'destination': destination,
      'local_path': work.path,
      'submitted': false,
    };
    // Keep the exact bytes, so restart never changes a committed request hash.
    await File(
      p.join(work.path, 'request.json'),
    ).writeAsBytes(raw, flush: true);
    final phone = body['phone_serial'] as String;
    final previous = await pending(phone);
    if (previous != null) {
      await writeStringAtomic(
        p.join(local.path, '${previous['task_id']}.abandoned.json'),
        jsonEncode(previous),
      );
    }
    if (generation != _generation) {
      throw StateError('Calibration submission cancelled');
    }
    await writeStringAtomic(_pointer(phone).path, jsonEncode(task));
    await publish(task);
    return task;
  }

  Future<void> publish(Map<String, dynamic> task) async {
    final root = Directory(
      longPath(
        p.join(
          task['destination'] as String,
          '.calibration',
          task['task_id'] as String,
        ),
      ),
    );
    final work = task['local_path'] as String;
    await _plain(task['destination'] as String);
    await _plain(p.dirname(root.path));
    await _plain(root.path);
    await _bounded(() => root.create(recursive: true));
    for (final name in [
      'chart.jpg',
      'chart.jpg.part',
      'request.json',
      'request.json.tmp',
      'ready.json',
      'ready.json.tmp',
    ]) {
      await _plain(p.join(root.path, name));
    }
    final source = File(p.join(work, 'chart.jpg'));
    final target = File(p.join(root.path, 'chart.jpg'));
    final raw = await File(p.join(work, 'request.json')).readAsBytes();
    if (_hash(raw) != task['request_sha256']) {
      throw StateError('Local request damaged');
    }
    if (_hash(await source.readAsBytes()) != (task['image'] as Map)['sha256']) {
      throw StateError('Local chart damaged');
    }
    final ready = File(p.join(root.path, 'ready.json'));
    if (!await _bounded(() => ready.exists())) {
      await _bounded(() => safeCopy(source, target.path));
      if (_hash(await _bounded(() => target.readAsBytes())) !=
          (task['image'] as Map)['sha256']) {
        throw StateError('Chart copy checksum mismatch');
      }
      await _bounded(
        () => writeStringAtomic(
          p.join(root.path, 'request.json'),
          utf8.decode(raw),
        ),
      );
      await _bounded(
        () => writeStringAtomic(
          ready.path,
          jsonEncode({
            'task_id': task['task_id'],
            'request_sha256': task['request_sha256'],
          }),
        ),
      );
    }
    final committed =
        jsonDecode(await _bounded(() => ready.readAsString())) as Map;
    if (committed['task_id'] != task['task_id'] ||
        committed['request_sha256'] != task['request_sha256']) {
      throw StateError('Task directory already contains a different request');
    }
    task['submitted'] = true;
    final current = await pending(task['phone_serial'] as String);
    if (current?['task_id'] == task['task_id']) {
      await writeStringAtomic(
        _pointer(task['phone_serial'] as String).path,
        jsonEncode(task),
      );
    }
  }

  Future<Map<String, dynamic>> wait(
    Map<String, dynamic> task, {
    void Function(String)? onWaiting,
  }) async {
    final generation = _generation;
    final since = DateTime.now();
    while (generation == _generation) {
      try {
        if (task['submitted'] != true) await publish(task);
        final value = await readResult(task);
        if (generation != _generation) break;
        if (value != null) return value;
        onWaiting?.call(
          DateTime.now().difference(since).inSeconds >= 120
              ? 'LWIP has not finished. Keep waiting, leave, or retake; the task remains saved.'
              : 'Waiting for LWIP to analyse the chart…',
        );
      } on FileSystemException {
        onWaiting?.call('Shared folder unavailable. Waiting to reconnect…');
      } on TimeoutException {
        onWaiting?.call(
          'Shared folder is not responding. The task remains saved.',
        );
      }
      await Future<void>.delayed(pollInterval);
    }
    throw StateError('Stopped waiting; LWIP task was not cancelled');
  }

  Future<Map<String, dynamic>?> readResult(Map<String, dynamic> task) async {
    final root = p.join(
      task['destination'] as String,
      '.calibration',
      task['task_id'] as String,
    );
    await _plain(p.dirname(root));
    await _plain(root);
    final file = File(longPath(p.join(root, 'result.json')));
    await _plain(file.path);
    if (!await _bounded(() => file.exists())) return null;
    if (await _bounded(() => file.length()) > 1024 * 1024) {
      throw StateError('Result exceeds protocol limit');
    }
    final bytes = await _bounded(() => file.readAsBytes());
    if (bytes.length > 1024 * 1024) {
      throw StateError('Result exceeds protocol limit');
    }
    final result = Map<String, dynamic>.from(
      jsonDecode(utf8.decode(bytes)) as Map,
    );
    for (final key in [
      'task_id',
      'request_sha256',
      'device_id',
      'phone_serial',
      'captured_at',
      'capture_local_date',
    ]) {
      if (result[key] != task[key]) {
        throw StateError('Calibration result mismatch: $key');
      }
    }
    if (result['version'] != 1 ||
        result['image_sha256'] != (task['image'] as Map)['sha256']) {
      throw StateError('Calibration result identity or version mismatch');
    }
    if (!['succeeded', 'failed'].contains(result['status'])) {
      throw StateError('Invalid result status');
    }
    final files = result['files'] as Map;
    final debug = <String, String>{};
    Map<String, dynamic>? profile;
    for (final entry in files.entries) {
      final name = entry.key as String;
      if (!['profile.json', 'detected.png', 'rectified.png'].contains(name)) {
        throw StateError('Unexpected result file');
      }
      final descriptor = entry.value as Map;
      if (descriptor['name'] != 'result/$name') {
        throw StateError('Unsafe result filename');
      }
      await _plain(p.join(root, 'result'));
      final remote = File(longPath(p.join(root, 'result', name)));
      await _plain(remote.path);
      final limit = name == 'profile.json' ? 1024 * 1024 : 32 * 1024 * 1024;
      if (await _bounded(() => remote.length()) > limit) {
        throw StateError('Result attachment exceeds limit');
      }
      final data = await _bounded(() => remote.readAsBytes());
      if (_hash(data) != descriptor['sha256']) {
        throw StateError('Calibration result checksum mismatch');
      }
      final target = File(p.join(task['local_path'] as String, name));
      final temp = File('${target.path}.tmp');
      await temp.writeAsBytes(data, flush: true);
      await temp.rename(target.path);
      if (name == 'profile.json') {
        profile = Map<String, dynamic>.from(
          jsonDecode(utf8.decode(data)) as Map,
        );
      } else {
        debug[name == 'detected.png' ? 'detected_png' : 'rectified_png'] =
            target.path;
      }
    }
    if (result['status'] == 'succeeded') {
      if (profile == null || profile['profile_id'] != result['profile_id']) {
        throw StateError('Missing calibration profile');
      }
      validateProfile(profile);
      profile['created_at'] = task['captured_at'];
      profile['phone_serial'] = task['phone_serial'];
      profile['camera'] = {'device_id': task['device_id']};
      profile['source_task'] = {
        for (final key in ['task_id', 'request_sha256', 'capture_local_date'])
          key: task[key],
        'image_sha256': (task['image'] as Map)['sha256'],
      };
    }
    return {
      ...result,
      'ok': result['status'] == 'succeeded',
      'profile': profile,
      'profile_path': p.join(task['local_path'] as String, 'profile.json'),
      'debug': debug,
    };
  }

  static void validateProfile(Map<String, dynamic> value) {
    bool number(dynamic n) => n is num && n.isFinite;
    final wb = value['white_balance'];
    final correction = value['correction'];
    if (value['schema_version'] != 1 ||
        value['working_space'] != 'linear_srgb_d65' ||
        wb is! List ||
        wb.length != 3 ||
        wb.any((n) => !number(n) || n < .2 || n > 5) ||
        correction is! Map ||
        correction['type'] != 'matrix3x3') {
      throw StateError('Invalid calibration parameters');
    }
    final matrix = correction['matrix'];
    if (matrix is! List ||
        matrix.length != 3 ||
        matrix.any(
          (row) =>
              row is! List || row.length != 3 || row.any((n) => !number(n)),
        )) {
      throw StateError('Invalid calibration matrix');
    }
    final tone = correction['tone'];
    if (tone != null) {
      if (tone is! Map ||
          ![
            'gamma_white_anchored',
            'lut1d_white_anchored',
            'lut1d_rgb_white_anchored',
          ].contains(tone['type'])) {
        throw StateError('Unsupported tone correction');
      }
      final rgb = tone['type'] == 'lut1d_rgb_white_anchored';
      final whites = rgb ? tone['white'] : [tone['white']];
      if (whites is! List ||
          whites.length != (rgb ? 3 : 1) ||
          whites.any((v) => !number(v) || v <= 0 || v > 2)) {
        throw StateError('Invalid tone white');
      }
      if (tone['type'] == 'gamma_white_anchored') {
        final g = tone['gamma'];
        if (!number(g) || g < .3 || g > 3) throw StateError('Invalid gamma');
      } else {
        final xs = rgb ? tone['x'] : [tone['x']];
        final ys = rgb ? tone['y'] : [tone['y']];
        if (xs is! List ||
            ys is! List ||
            xs.length != (rgb ? 3 : 1) ||
            ys.length != xs.length) {
          throw StateError('Invalid tone channels');
        }
        for (var i = 0; i < xs.length; i++) {
          if (xs[i] is! List ||
              ys[i] is! List ||
              xs[i].length < 2 ||
              xs[i].length != ys[i].length) {
            throw StateError('Invalid tone knots');
          }
          for (final list in [xs[i] as List, ys[i] as List]) {
            if (list.any((v) => !number(v) || v < 0 || v > 1)) {
              throw StateError('Invalid tone value');
            }
            for (var j = 1; j < list.length; j++) {
              if (list[j] < list[j - 1]) {
                throw StateError('Unordered tone knots');
              }
            }
          }
        }
        if (rgb && tone['white_out'] != null) {
          final output = tone['white_out'];
          if (output is! List ||
              output.length != 3 ||
              output.any((v) => !number(v) || v <= 0 || v > 2)) {
            throw StateError('Invalid output white');
          }
        }
      }
    }
  }
}
