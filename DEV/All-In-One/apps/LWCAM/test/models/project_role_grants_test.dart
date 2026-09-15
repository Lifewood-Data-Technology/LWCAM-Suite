import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/app_user.dart';

AppUser userWith(
  Set<UserRole> roles, {
  Map<UserRole, Set<String>> grants = const {},
  Set<String> legacyKeys = const {},
}) =>
    AppUser(
      username: 'someone',
      passwordHash: r'$2a$10$abcdefghijklmnopqrstuv',
      roles: roles,
      roleProjectKeys: grants,
      projectKeys: legacyKeys,
    );

void main() {
  // These two decide the whole navigation shape: which projects the Projects
  // list shows, and which tabs each project offers once opened.
  group('rolesForProjectKey', () {
    test('a role reaches only the projects it was granted', () {
      final u = userWith({
        UserRole.admin,
        UserRole.capture,
      }, grants: {
        UserRole.admin: {'A', 'B'},
        UserRole.capture: {'A', 'C'},
      });
      expect(u.rolesForProjectKey('A'), {UserRole.admin, UserRole.capture});
      expect(u.rolesForProjectKey('B'), {UserRole.admin});
      expect(u.rolesForProjectKey('C'), {UserRole.capture});
      expect(u.rolesForProjectKey('D'), isEmpty);
    });

    test('a global role with no project row grants nothing', () {
      // An admin who holds the role but no assignment sees an empty Projects
      // list, not every project.
      final u = userWith({UserRole.admin}, grants: {UserRole.admin: {}});
      expect(u.rolesForProjectKey('A'), isEmpty);
      expect(u.allProjectKeys, isEmpty);
    });

    test('a leftover project row for a revoked role does not resurrect it', () {
      // LWCam Admin can drop a role from users.roles while a stale
      // user_projects row survives. The tab must not come back.
      final u = userWith({UserRole.capture}, grants: {
        UserRole.admin: {'A'},
        UserRole.capture: {'A'},
      });
      expect(u.rolesForProjectKey('A'), {UserRole.capture});
    });

    test('roles never leak across projects via the legacy flat key set', () {
      // A mixed-role legacy snapshot carries only the flattened projectKeys.
      // Implying grants from it would hand a capture operator the admin set.
      final u = userWith({UserRole.admin, UserRole.capture},
          legacyKeys: {'A', 'B'});
      expect(u.rolesForProjectKey('A'), isEmpty);
      expect(u.allProjectKeys, isEmpty);
    });

    test('a single-role legacy snapshot is unambiguous and still works', () {
      final u = userWith({UserRole.qc}, legacyKeys: {'A'});
      expect(u.rolesForProjectKey('A'), {UserRole.qc});
      expect(u.allProjectKeys, {'A'});
    });
  });

  group('allProjectKeys', () {
    test('is the union across roles, deduplicated', () {
      final u = userWith({
        UserRole.admin,
        UserRole.capture,
        UserRole.qc,
      }, grants: {
        UserRole.admin: {'A', 'B'},
        UserRole.capture: {'A'},
        UserRole.qc: {'C'},
      });
      expect(u.allProjectKeys, {'A', 'B', 'C'});
    });
  });
}
