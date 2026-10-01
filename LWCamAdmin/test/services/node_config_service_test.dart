import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/models/node_config.dart';
import 'package:lwcam_admin/services/node_config_service.dart';

void main() {
  late Directory dir;
  late String path;
  NodeConfigService make() => NodeConfigService(getConfigPath: () => path);
  Map<String, dynamic> disk() =>
      jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('ncs_test');
    path = '${dir.path}/lwcam_node_config.json';
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('unknown keys (LWCAM settings, legacy keys) survive a save', () async {
    File(path).writeAsStringSync(jsonEncode({
      'pgHost': 'db',
      'lwcamOnlyThing': {
        'a': [1, 2],
      },
      'role': 'legacy',
    }));
    await make().update((c) => c.copyWith(pgPort: 6543));
    expect(disk()['lwcamOnlyThing'], {
      'a': [1, 2],
    });
    expect(disk()['role'], 'legacy');
    expect(disk()['pgPort'], 6543);
  });

  test('update() re-reads the disk, so another apps edit is not lost',
      () async {
    File(path).writeAsStringSync(jsonEncode({'pgHost': 'db'}));
    final s = make();
    await s.load(); // cached copy
    // LWCAM rewrites the file behind our back.
    File(path).writeAsStringSync(jsonEncode({'pgHost': 'db', 'lwcamKey': 42}));
    await s.update((c) => c.copyWith(pgPort: 1234));
    expect(disk()['lwcamKey'], 42);
    expect(disk()['pgPort'], 1234);
  });

  test('save replaces atomically: no temp left, previous good file is .bak',
      () async {
    final s = make();
    await s.save(const NodeConfig(pgHost: 'one'));
    await s.save(const NodeConfig(pgHost: 'two'));
    expect(File('$path.tmp').existsSync(), isFalse);
    expect(disk()['pgHost'], 'two');
    expect(jsonDecode(File('$path.bak').readAsStringSync())['pgHost'], 'one');
  });

  test('a corrupt file recovers from .bak on load', () async {
    final s = make();
    await s.save(const NodeConfig(pgHost: 'one'));
    await s.save(const NodeConfig(pgHost: 'two'));
    File(path).writeAsStringSync('{ torn');
    expect((await make().load()).pgHost, 'one');
  });

  test('a corrupt file with no backup is not overwritten by a fresh config',
      () async {
    File(path).writeAsStringSync('{ torn');
    final c = await make().load();
    expect(c.pgHost, isNull);
    expect(File(path).readAsStringSync(), '{ torn');
  });

  test('a corrupt main file never replaces the last good .bak', () async {
    final s = make();
    await s.save(const NodeConfig(pgHost: 'one'));
    await s.save(const NodeConfig(pgHost: 'two'));
    File(path).writeAsStringSync('{ torn');
    await s.save(const NodeConfig(pgHost: 'three'));
    expect(jsonDecode(File('$path.bak').readAsStringSync())['pgHost'], 'one');
  });
}
