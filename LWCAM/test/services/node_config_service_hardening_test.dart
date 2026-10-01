import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/node_config.dart';
import 'package:lwcam/services/node_config_service.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory dir;
  late String path;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('node_cfg_');
    path = p.join(dir.path, NodeConfigService.fileName);
  });
  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  NodeConfigService service() => NodeConfigService(
    getConfigPath: () => path,
    unprotect: (b) => b.startsWith('blob:') ? b.substring(5) : throw 'bad',
  );

  test('update reloads from disk: a newer Admin edit is not overwritten by a '
      'stale cached copy', () async {
    await File(path).writeAsString(jsonEncode({'pgHost': 'old', 'x': 1}));
    final svc = service();
    await svc.load(); // cached pgHost=old
    // LWCam Admin rewrites the file meanwhile.
    await File(path).writeAsString(
      jsonEncode({'pgHost': 'new-host', 'adminPgUser': 'boss'}),
    );
    await svc.update((c) => c.copyWith(syncEnabled: true));

    final disk = jsonDecode(await File(path).readAsString()) as Map;
    expect(disk['pgHost'], 'new-host');
    expect(disk['syncEnabled'], true);
    expect(disk['adminPgUser'], 'boss', reason: 'unknown keys round-trip');
  });

  test('save replaces in place and leaves no temp file', () async {
    await File(path).writeAsString('{"pgHost":"a"}');
    await service().save(const NodeConfig(pgHost: 'b'));
    expect(jsonDecode(await File(path).readAsString())['pgHost'], 'b');
    expect(dir.listSync().map((e) => p.basename(e.path)).toList(), [
      NodeConfigService.fileName,
    ]);
  });

  test('pgPasswordProtected wins over plain pgPassword; plain fallback for '
      'old files', () async {
    await File(path).writeAsString(
      jsonEncode({'pgPassword': 'plain', 'pgPasswordProtected': 'blob:secret'}),
    );
    expect((await service().load()).pgPassword, 'secret');

    await File(path).writeAsString(jsonEncode({'pgPassword': 'plain'}));
    expect((await service().load()).pgPassword, 'plain');
  });

  test('an unreadable protected blob falls back to the plain password', () async {
    await File(path).writeAsString(
      jsonEncode({'pgPassword': 'plain', 'pgPasswordProtected': 'garbage'}),
    );
    expect((await service().load()).pgPassword, 'plain');
  });

  test('a save never writes the plain password over a protected blob', () async {
    await File(path).writeAsString(
      jsonEncode({'pgHost': 'h', 'pgPasswordProtected': 'blob:secret'}),
    );
    final svc = service();
    await svc.update((c) => c.copyWith(syncEnabled: true));
    final disk = jsonDecode(await File(path).readAsString()) as Map;
    expect(disk['pgPasswordProtected'], 'blob:secret');
    expect(disk['pgPassword'], isNull);
    expect(await File(path).readAsString(), isNot(contains('"secret"')));
  });

  test('a corrupt file is not overwritten with defaults', () async {
    await File(path).writeAsString('{not json');
    final cfg = await service().load();
    expect(cfg.pgHost, isNull);
    expect(await File(path).readAsString(), '{not json');
  });
}
