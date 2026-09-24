import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam_admin/services/admin_pg_statements.dart';

/// ALTER ROLE cannot take bind parameters, so this builder quotes a role name
/// and a password into SQL that runs with superuser rights. Bad quoting here is
/// a privilege-level injection, which is why it is tested rather than inlined.
void main() {
  group('alterRolePasswordSql', () {
    test('quotes the role as an identifier and the password as a literal', () {
      expect(
        alterRolePasswordSql(role: 'postgres', password: 'Abc12345').sql,
        'ALTER ROLE ' '"postgres"' ' PASSWORD ' "'Abc12345'",
      );
    });

    test('takes no bind parameters - the statement is fully rendered', () {
      expect(
        alterRolePasswordSql(role: 'postgres', password: 'Abc12345').parameters,
        isEmpty,
      );
    });

    test('a quote in the password is doubled, not escaped out of the literal',
        () {
      // The injection attempt: close the literal and append a statement.
      final sql = alterRolePasswordSql(
        role: 'postgres',
        password: "x'; DROP TABLE users; --",
      ).sql;
      expect(sql, contains("'x''; DROP TABLE users; --'"));
      // Four quote characters: the opening one, the doubled pair standing for
      // the typed quote, and the closing one. Nothing after the literal can be
      // parsed as a second statement.
      expect(sql.split("'").length - 1, 4);
    });

    test('a quote in the role name is doubled too', () {
      expect(
        alterRolePasswordSql(role: 'we"ird', password: 'Abc12345').sql,
        startsWith('ALTER ROLE ' '"we""ird"' ' PASSWORD '),
      );
    });

    test('a backslash is refused rather than quoted', () {
      // Doubling quotes is correct only while standard_conforming_strings is
      // on. Refusing beats depending on a server setting being what we assume.
      expect(
        () => alterRolePasswordSql(
          role: 'postgres',
          password: String.fromCharCodes([0x78, 0x5c, 0x78]), // x + backslash + x
        ),
        throwsArgumentError,
      );
    });

    test('control characters are refused', () {
      expect(
        () => alterRolePasswordSql(
          role: 'postgres',
          password: String.fromCharCodes([0x61, 0x0a, 0x62]), // a + newline + b
        ),
        throwsArgumentError,
      );
    });

    test('an empty password or a blank role is refused', () {
      expect(
        () => alterRolePasswordSql(role: 'postgres', password: ''),
        throwsArgumentError,
      );
      expect(
        () => alterRolePasswordSql(role: '   ', password: 'Abc12345'),
        throwsArgumentError,
      );
    });
  });
}
