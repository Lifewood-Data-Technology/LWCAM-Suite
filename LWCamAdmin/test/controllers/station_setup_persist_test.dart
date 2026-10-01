import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:lwcam_admin/controllers/station_setup_controller.dart';
import 'package:lwcam_admin/models/node_config.dart';
import 'package:lwcam_admin/services/admin_login.dart';
import 'package:lwcam_admin/services/dpapi.dart';
import 'package:lwcam_admin/services/node_config_service.dart';

void main() {
  late Directory dir;
  late String file;
  late StationSetupController c;
  Map<String, dynamic> disk() =>
      jsonDecode(File(file).readAsStringSync()) as Map<String, dynamic>;

  Future<void> boot(Map<String, Object?> initial) async {
    File(file).writeAsStringSync(jsonEncode({
      'pgHost': '',
      'usersStorePath': dir.path,
      'destinationPath': '${dir.path}/img',
      'pgConnectionEnabled': false,
      ...initial,
    }));
    Get.put(NodeConfigService(getConfigPath: () => file));
    c = StationSetupController();
    await c.ensureLoaded();
    c.pgHost.value = ''; // never touch the network from a test
  }

  setUp(() {
    dir = Directory.systemTemp.createTempSync('persist_test');
    file = '${dir.path}/lwcam_node_config.json';
  });
  tearDown(() {
    Get.reset();
    dir.deleteSync(recursive: true);
  });

  final skip = Platform.isWindows ? false : 'DPAPI is Windows-only';

  test('an old plaintext pgPassword loads, then is saved protected', () async {
    await boot({'pgPassword': 'old-plain'});
    expect(c.pgPassword.value, 'old-plain');
    await c.save();
    final j = disk();
    expect(j['pgPassword'], isEmpty);
    expect(
        dpapiUnprotect(j['pgPasswordProtected'] as String,
            entropy: captureDpapiEntropy),
        'old-plain');
    expect(File(file).readAsStringSync(), isNot(contains('old-plain')));
    // ...and the protected value is what a re-open shows.
    await c.ensureLoaded(force: true);
    expect(c.pgPassword.value, 'old-plain');
  }, skip: skip);

  test('save keeps keys written to the file after the page opened', () async {
    await boot({'lwcamKey': 1, 'qcOutputRoot': 'D:/out'});
    // LWCAM (or IT) edits the file while the Station Setup page is open.
    final j = disk()
      ..['lwcamKey'] = 2
      ..['qcOutputRoot'] = 'E:/other'
      ..['newerBuildKey'] = 'keep';
    File(file).writeAsStringSync(jsonEncode(j));
    await c.save();
    expect(disk()['lwcamKey'], 2);
    expect(disk()['qcOutputRoot'], 'E:/other');
    expect(disk()['newerBuildKey'], 'keep');
  });

  test('an undecryptable login blob shows an error and is not overwritten',
      () async {
    await boot({
      // valid base64 that is not a blob for this account
      'pgPasswordProtected': 'AAAAAAAAAAAAAAAA',
      'adminPgUser': 'lwcam_admin',
      'adminPgPasswordProtected': 'AAAAAAAAAAAAAAAA',
    });
    expect(c.capturePasswordUnreadable.value, isTrue);
    expect(c.pgPassword.value, isEmpty);
    await c.save();
    expect(disk()['pgPasswordProtected'], 'AAAAAAAAAAAAAAAA');
    // The old separate admin login is retired by any save (one shared login).
    expect(disk()['adminPgPasswordProtected'], anyOf(isNull, ''));

    // Typing a new password replaces it and clears the error.
    c.pgPassword.value = 'new-pw';
    await c.save();
    expect(dpapiUnprotect(disk()['pgPasswordProtected'] as String,
        entropy: captureDpapiEntropy), 'new-pw');
    expect(c.capturePasswordUnreadable.value, isFalse);
  }, skip: skip);

  test('adminLoginFor flags an unreadable blob for the admin landing page', () {
    const cfg = NodeConfig(
      pgUser: 'lwcam_capture',
      pgPassword: 'cap',
      adminPgUser: 'lwcam_admin',
      adminPgPasswordProtected: 'BLOB',
    );
    adminLoginFor(cfg, unprotect: (_) => throw StateError('no'));
    expect(adminLoginUnreadable.value, isTrue);
    adminLoginFor(cfg, unprotect: (_) => 'ok');
    expect(adminLoginUnreadable.value, isFalse);
  });

  test('capture password: protected blob first, plain only for old files', () {
    const both = NodeConfig(pgPassword: 'plain', pgPasswordProtected: 'BLOB');
    expect(capturePasswordOf(both, unprotect: (_) => 'from-blob'), 'from-blob');
    expect(capturePasswordOf(const NodeConfig(pgPassword: 'plain')), 'plain');
    expect(
      () => capturePasswordOf(const NodeConfig(pgPasswordProtected: 'BLOB'),
          unprotect: (_) => throw StateError('no')),
      throwsStateError,
    );
  });
}
