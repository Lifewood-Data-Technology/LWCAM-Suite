import 'dart:async';

import 'package:get/get.dart';

import '../services/admin_store_service.dart';

/// Drives the 30s reconcile tick. All the actual online/dirty/lastPush/
/// lastPull state lives on [AdminStoreService] itself (it's the thing being
/// reconciled) — this controller is just the timer, so the UI has one
/// source of truth to read instead of two copies that could drift.
class SyncStatusController extends GetxController {
  Timer? _timer;

  @override
  void onInit() {
    super.onInit();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _tick());
  }

  Future<void> _tick() async {
    if (!Get.isRegistered<AdminStoreService>()) return;
    await Get.find<AdminStoreService>().trySync();
  }

  @override
  void onClose() {
    _timer?.cancel();
    super.onClose();
  }
}
