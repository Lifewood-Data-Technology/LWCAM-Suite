import 'package:lwcam_admin/models/app_user.dart';
import 'package:lwcam_admin/services/admin_pg_gateway.dart';

/// Test double for [AdminGateway]. Scripted: set [nextProbe], optionally
/// queue errors for push/pull, and inspect [pushedSnapshots]/[pullResult].
class FakeAdminGateway implements AdminGateway {
  GatewayProbeResult nextProbe = const GatewayProbeResult(GatewayStatus.reachable);
  Object? pushError;
  Object? pullError;
  UsersStore pullResult = const UsersStore();

  final List<UsersStore> pushedSnapshots = [];
  int pullCallCount = 0;
  int probeCallCount = 0;
  Object? rotateError;
  final List<String> rotatedTo = [];

  @override
  Future<GatewayProbeResult> probe() async {
    probeCallCount++;
    return nextProbe;
  }

  @override
  Future<void> pushSnapshot(UsersStore store) async {
    if (pushError != null) throw pushError!;
    pushedSnapshots.add(store);
  }

  @override
  Future<UsersStore> pullStore() async {
    pullCallCount++;
    if (pullError != null) throw pullError!;
    return pullResult;
  }

  @override
  Future<void> rotatePassword(String newPassword) async {
    if (rotateError != null) throw rotateError!;
    rotatedTo.add(newPassword);
  }

  @override
  Future<void> close() async {}
}
