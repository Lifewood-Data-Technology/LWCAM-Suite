import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/app_user.dart';

/// The `qc` role after Phase 8 (2026-09-22): LWCAM grants nothing for it and
/// must still carry it intact.
///
/// `lwcam_users.json` is shared with LWCam Admin, and THIS app rewrites it
/// (`UsersStoreService`, via `AppUser.toJson`). `UserRole.fromJson` returns
/// null for anything it does not recognise and the caller ignores it, so
/// deleting the enum member would have read a reviewer's account, dropped the
/// role, and written the snapshot back without it — Admin, reading the same
/// file, would then show that account as no longer a reviewer. Nothing would
/// have failed; the role would simply have gone.
///
/// So these tests are about SURVIVAL, not capability. There is no `canQc` any
/// more, and no screen behind the role.
AppUser userWith(Set<UserRole> roles) => AppUser(
      username: 'someone',
      passwordHash: r'$2a$10$abcdefghijklmnopqrstuv',
      roles: roles,
    );

void main() {
  group('qc role parsing', () {
    test('parses the exact string the other apps write', () {
      // LWCam Admin and the QC backend both write plain 'qc' into users.roles,
      // and every parser in the suite is an exact lowercase match. A different
      // spelling here would silently drop the role instead of failing loudly.
      expect(UserRole.fromJson('qc'), UserRole.qc);
      expect(UserRole.qc.jsonValue, 'qc');
    });

    test('an unknown role is still ignored rather than fatal', () {
      // 'rework' belongs to the sibling LWRework app and legitimately appears in
      // a shared store.
      expect(UserRole.fromJson('rework'), isNull);
      expect(UserRole.fromJson(null), isNull);
    });
  });

  group('the shared snapshot keeps a role this app cannot use', () {
    test('a reviewer round-trips through the store unchanged', () {
      final reviewer = userWith({UserRole.qc});

      final reloaded = AppUser.fromJson(reviewer.toJson());

      expect(reloaded.roles, {UserRole.qc},
          reason: 'writing the snapshot back must not strip the QC role');
    });

    test('and so does a reviewer who also captures', () {
      final both = userWith({UserRole.qc, UserRole.capture});

      final reloaded = AppUser.fromJson(both.toJson());

      expect(reloaded.roles, {UserRole.qc, UserRole.capture});
    });

    test('the serialized form is the string the other apps read', () {
      final roles = userWith({UserRole.qc}).toJson()['roles'];

      expect(roles, ['qc']);
    });
  });

  group('what each account may reach in THIS app', () {
    test('a reviewer may reach nothing here', () {
      final qc = userWith({UserRole.qc});

      expect(qc.canNormalMode, isFalse);
      expect(qc.isAdmin, isFalse);
      // Which is what the login gate refuses on: with QC review gone to the
      // console, a qc-only account has no LWCAM destination at all.
      expect(qc.requiresDeviceId, isFalse);
    });

    test('holding qc as well changes nothing about capture or admin', () {
      final both = userWith({UserRole.qc, UserRole.admin});

      expect(both.isAdmin, isTrue);
      expect(both.canNormalMode, isFalse);
    });
  });

  group('login destination', () {
    // Mirrors AuthController: exactly one permitted area auto-routes, more than
    // one goes to the Home chooser. QC is not an area here any more, so it
    // contributes nothing to the count.
    int permittedAreas(AppUser u) =>
        [u.canNormalMode, u.isAdmin].where((b) => b).length;

    test('a reviewer-only account has no area, and is refused', () {
      expect(permittedAreas(userWith({UserRole.qc})), 0);
    });

    test('capture-only still auto-routes as before', () {
      expect(permittedAreas(userWith({UserRole.capture})), 1);
    });

    test('qc plus capture is capture alone, not a chooser', () {
      expect(permittedAreas(userWith({UserRole.qc, UserRole.capture})), 1);
    });
  });
}
