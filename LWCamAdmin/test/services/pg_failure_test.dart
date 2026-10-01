import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/services/pg_client.dart';

void main() {
  group('classifyPgError', () {
    test('a missing database is not a network problem', () {
      expect(
        classifyPgError(Exception(
            'connection to server at "localhost" (::1), port 5432 failed: '
            'FATAL:  database "lwcam" does not exist')),
        PgFailure.missingDatabase,
      );
    });

    test('a rejected password is named as one', () {
      expect(
        classifyPgError(Exception(
            'FATAL:  password authentication failed for user "postgres"')),
        PgFailure.badPassword,
      );
    });

    test('no pg_hba entry is its own failure', () {
      expect(
        classifyPgError(Exception(
            'FATAL: no pg_hba.conf entry for host "100.64.1.5", user '
            '"lwcam_capture", database "lwcam", SSL encryption')),
        PgFailure.noHbaEntry,
      );
    });

    test('hostssl-only rules seen from a plain connection = encryption', () {
      expect(
        classifyPgError(Exception(
            'FATAL: no pg_hba.conf entry for host "10.0.0.2", user "u", '
            'database "d", no encryption')),
        PgFailure.encryptionRequired,
      );
      expect(
        classifyPgError(
            Exception('Server does not support SSL, but it is required')),
        PgFailure.encryptionRequired,
      );
    });

    test('timeouts and unresolvable names read as host unreachable', () {
      expect(classifyPgError(TimeoutException('x')), PgFailure.timeout);
      expect(
        classifyPgError(Exception(
            'SocketException: Connection timed out, errno = 10060')),
        PgFailure.timeout,
      );
      expect(
        classifyPgError(Exception(
            "SocketException: Failed host lookup: 'db-pc.tail1234.ts.net'")),
        PgFailure.timeout,
      );
    });

    test('a refused connection stays unreachable', () {
      expect(
        classifyPgError(Exception('SocketException: Connection refused')),
        PgFailure.unreachable,
      );
    });
  });

  test('each failure gets an operator-facing sentence', () {
    expect(describePgFailure(PgFailure.missingDatabase),
        contains('does not exist yet'));
    expect(describePgFailure(PgFailure.badPassword), contains('rejected'));
    expect(describePgFailure(PgFailure.unreachable), contains('host'));
    expect(describePgFailure(PgFailure.timeout), contains('host unreachable'));
    expect(describePgFailure(PgFailure.noHbaEntry), contains('pg_hba.conf'));
    expect(describePgFailure(PgFailure.encryptionRequired), contains('TLS'));
  });
}
