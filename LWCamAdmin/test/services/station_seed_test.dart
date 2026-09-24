import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/services/pg_client.dart';
import 'package:lwcam_admin/services/station_seed.dart';

/// The seed is what removes the operator from the credential path entirely, and
/// the classifier is what stops a missing database from reading as a network
/// fault. Both are small; both were the difference between an install that
/// works and one that needs a developer.
void main() {
  group('StationSeed', () {
    test('parses what setup writes', () {
      final seed = StationSeed.tryParse('''
{
  "pgHost": "localhost",
  "pgPort": 5432,
  "pgDatabase": "lwcam",
  "pgUser": "postgres",
  "pgPassword": "gcNTRniJy7AYV5kHkMzgNxweftG7wnwv"
}
''');
      expect(seed, isNotNull);
      expect(seed!.host, 'localhost');
      expect(seed.port, 5432);
      expect(seed.database, 'lwcam');
      expect(seed.user, 'postgres');
      expect(seed.password, 'gcNTRniJy7AYV5kHkMzgNxweftG7wnwv');
    });

    test('a missing port falls back to 5432 rather than rejecting the seed', () {
      final seed = StationSeed.tryParse(
          '{"pgHost":"h","pgDatabase":"d","pgUser":"u","pgPassword":"p"}');
      expect(seed?.port, 5432);
    });

    test('an incomplete seed is ignored, not half-applied', () {
      // No password is the case that matters: applying the rest would leave the
      // station looking configured while being unable to connect.
      expect(
        StationSeed.tryParse(
            '{"pgHost":"h","pgPort":5432,"pgDatabase":"d","pgUser":"u"}'),
        isNull,
      );
      expect(StationSeed.tryParse('{"pgHost":"","pgPassword":"p"}'), isNull);
    });

    test('malformed or hostile content never throws', () {
      // Admin must open even if someone hand-edits this file.
      for (final text in ['', 'not json', '[]', 'null', '{', '42']) {
        expect(StationSeed.tryParse(text), isNull, reason: 'input: \$text');
      }
    });
  });

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

    test('anything else stays unreachable', () {
      expect(
        classifyPgError(Exception('SocketException: Connection refused')),
        PgFailure.unreachable,
      );
    });

    test('each failure gets an operator-facing sentence', () {
      // The old single message sent people to check firewalls when the database
      // simply had not been created.
      expect(describePgFailure(PgFailure.missingDatabase),
          contains('does not exist yet'));
      expect(describePgFailure(PgFailure.badPassword), contains('rejected'));
      expect(describePgFailure(PgFailure.unreachable), contains('host'));
    });
  });

  group('stationSeedCandidates', () {
    test('ProgramData is searched before the install folder', () {
      // Order matters: ProgramData is the only location Admin can delete from,
      // and the seed holds a superuser password that must not outlive its use.
      final paths = stationSeedCandidates(
        executablePath: r'C:\Program Files\LW Suite\LWCamAdmin\lwcam_admin.exe',
        environment: const {'ProgramData': r'C:\ProgramData'},
      );
      expect(paths.first, r'C:\ProgramData\LWCAM\station-seed.json');
      // The old install-folder location is still searched, so a station set up
      // by an earlier build is not stranded.
      expect(
        paths.any((s) => s.contains(r'LW Suite\station-seed.json')),
        isTrue,
      );
    });

    test('a missing ProgramData variable falls back rather than throwing', () {
      final paths = stationSeedCandidates(
        executablePath: r'C:\somewherepp.exe',
        environment: const {},
      );
      expect(paths.first, r'C:\ProgramData\LWCAM\station-seed.json');
    });
  });
}
