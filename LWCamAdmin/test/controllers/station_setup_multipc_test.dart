import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/controllers/station_setup_controller.dart';
import 'package:lwcam_admin/services/pg_client.dart';
import 'package:postgres/postgres.dart';

class _FakeConn implements Connection {
  @override
  dynamic noSuchMethod(Invocation invocation) => Future<void>.value();
}

/// Station Setup on a capture PC whose database lives on ANOTHER machine.
void main() {
  final hosts = <String>[];
  PgFailure? failWith;
  late StationSetupController c;

  setUp(() {
    hosts.clear();
    failWith = null;
    c = StationSetupController(
      openConnection: ({
        required host,
        required port,
        required database,
        required user,
        required password,
        required useSsl,
      }) async {
        hosts.add(host);
        final f = failWith;
        if (f != null) throw SyncConnectException('x', failure: f);
        return _FakeConn();
      },
    );
    c.pgDatabase.value = 'lwcam';
    c.pgUser.value = 'lwcam_user';
    c.pgPassword.value = 'cap';
  });

  test('a database PC is reached by name, LAN IP and Tailscale name/IP',
      () async {
    const all = [
      'db-pc',
      '192.168.0.120',
      'db-pc.tail1234.ts.net',
      '100.101.102.103',
    ];
    for (final h in all) {
      c.pgHost.value = ' $h ';
      await c.testConnection();
      // Every non-local host is TLS (SslMode.require), whatever the checkbox.
      expect(pgSslMode(h, false), SslMode.require);
    }
    expect(hosts, all);
  });

  test('each failure is told apart, with the host and port in the message',
      () async {
    c.pgHost.value = 'db-pc.tail1234.ts.net';
    final expected = {
      PgFailure.noHbaEntry: 'pg_hba.conf',
      PgFailure.encryptionRequired: 'TLS',
      PgFailure.badPassword: 'rejected',
      PgFailure.timeout: 'host unreachable',
    };
    for (final e in expected.entries) {
      failWith = e.key;
      await expectLater(
        c.testConnection(),
        throwsA(predicate((x) {
          final t = x.toString();
          return t.contains(e.value) &&
              t.contains('Database login') &&
              t.contains('db-pc.tail1234.ts.net:5432');
        })),
        reason: '${e.key}',
      );
    }
  });

  test('a pasted host:port or URL is refused before any connection', () async {
    for (final bad in ['db-pc:5432', 'postgres://db-pc/lwcam', 'db pc']) {
      c.pgHost.value = bad;
      await expectLater(c.testConnection(), throwsA(isA<StateError>()));
    }
    expect(hosts, isEmpty);
    expect(pgHostProblem('fe80::1'), isNull); // IPv6 has many colons
  });
}
