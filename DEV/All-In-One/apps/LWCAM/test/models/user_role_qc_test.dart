import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/models/app_user.dart';

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

  group('what each account may reach', () {
    test('qc is independent of capture and admin', () {
      final qc = userWith({UserRole.qc});
      expect(qc.canQc, isTrue);
      expect(qc.canNormalMode, isFalse);
      expect(qc.isAdmin, isFalse);
      // A QC operator reviews other people's captures, so no Device ID is
      // required of them - that gate is capture-only.
      expect(qc.requiresDeviceId, isFalse);
    });

    test('capture and admin do not imply qc', () {
      expect(userWith({UserRole.capture}).canQc, isFalse);
      expect(userWith({UserRole.admin}).canQc, isFalse);
    });

    test('a dual-role account keeps both', () {
      final both = userWith({UserRole.qc, UserRole.admin});
      expect(both.canQc, isTrue);
      expect(both.isAdmin, isTrue);
      expect(both.canNormalMode, isFalse);
    });

    test('an account with no known role reaches nothing', () {
      // This is what the login gate refuses on; before qc existed, a qc-only
      // account landed here and was told it had no access.
      final none = userWith({});
      expect(none.canQc || none.canNormalMode || none.isAdmin, isFalse);
    });
  });

  group('login destination', () {
    // Mirrors AuthController: exactly one permitted area auto-routes, more than
    // one goes to the Home chooser.
    int permittedAreas(AppUser u) =>
        [u.canNormalMode, u.isAdmin, u.canQc].where((b) => b).length;

    test('qc-only auto-routes, so it never sees a one-tile chooser', () {
      expect(permittedAreas(userWith({UserRole.qc})), 1);
    });

    test('capture-only still auto-routes as before', () {
      expect(permittedAreas(userWith({UserRole.capture})), 1);
    });

    test('qc plus capture is a chooser, not a guess', () {
      expect(permittedAreas(userWith({UserRole.qc, UserRole.capture})), 2);
    });
  });
}
