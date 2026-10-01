import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:lwcam_admin/controllers/station_setup_controller.dart';
import 'package:lwcam_admin/services/node_config_service.dart';
import 'package:lwcam_admin/services/pg_client.dart';
import 'package:postgres/postgres.dart';

class _FakeConn implements Connection {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

void main() {
  test('default is the one shared app login', () {
    expect(defaultPgUser, 'lwcam_user');
  });

  group('testConnection', () {
    final calls = <(String, String)>[]; // (user, database)
    late StationSetupController c;

    setUp(() {
      calls.clear();
      c = StationSetupController(
        openConnection: ({
          required host,
          required port,
          required database,
          required user,
          required password,
          required useSsl,
        }) async {
          calls.add((user, database));
          if (password == 'wrong') {
            throw const SyncConnectException(
              'x',
              failure: PgFailure.badPassword,
            );
          }
          return _FakeConn();
        },
      );
      c.pgHost.value = 'db';
      c.pgDatabase.value = 'lwcam';
      c.pgUser.value = 'lwcam_user';
      c.pgPassword.value = 'cap';
    });

    test('checks the one login against the configured database', () async {
      await c.testConnection();
      expect(calls, [('lwcam_user', 'lwcam')]);
    });

    test('names the login that failed', () async {
      c.pgPassword.value = 'wrong';
      await expectLater(
        c.testConnection(),
        throwsA(predicate((e) => e.toString().contains('Database login'))),
      );
    });
  });

  test(
    'save stores the one login encrypted and retires the old admin login',
    () async {
      final dir = Directory.systemTemp.createTempSync('setup_test');
      addTearDown(() {
        Get.reset();
        dir.deleteSync(recursive: true);
      });
      final file = '${dir.path}/lwcam_node_config.json';
      File(file).writeAsStringSync(jsonEncode({
        'adminPgUser': 'lwcam_admin',
        'adminPgPasswordProtected': 'OLDBLOB',
      }));
      Get.put(NodeConfigService(getConfigPath: () => file));
      final c = StationSetupController();
      await c.ensureLoaded();
      expect(c.pgUser.value, 'lwcam_user');
      expect(c.pgPort.value, 5432);
      c.pgConnectionEnabled.value = false;
      c.usersStorePath.value = dir.path;
      c.destinationPath.value = '${dir.path}/img';
      c.pgPassword.value = 'cap-secret';
      await c.save();
      final text = File(file).readAsStringSync();
      final json = jsonDecode(text) as Map;
      expect(json['pgUser'], 'lwcam_user');
      // Capture password: DPAPI blob, plain field blanked.
      expect(json['pgPassword'], isEmpty);
      expect(json['pgPasswordProtected'], isNotEmpty);
      // Old admin fields are neither written nor cleared.
      expect(json['adminPgUser'], anyOf(isNull, ''));
      expect(json['adminPgPasswordProtected'], anyOf(isNull, ''));
      expect(text, isNot(contains('cap-secret')));
      await c.ensureLoaded(force: true);
      expect(c.pgPassword.value, 'cap-secret');
    },
    skip: Platform.isWindows ? false : 'DPAPI is Windows-only',
  );
}
