import 'dart:async';

import 'package:get/get.dart';

import '../services/qc_api_client.dart';

/// Drives the Exports screen.
///
/// The server exports approved folders on its own schedule, so this screen is
/// for WATCHING that happen and for dealing with what did not: it holds the
/// current (or last) run and, separately, the ledger of folders whose export
/// failed and has not since succeeded. Those two outlive each other differently
/// - a run is replaced by the next one, a failure persists until it is fixed -
/// which is why they are fetched and displayed apart.
class QcExportsController extends GetxController {
  QcApiClient get _api => QcApiClient.instance;

  /// While a run is alive. Slow enough not to hammer a single-threaded engine
  /// that is busy converting TIFFs, quick enough to feel live.
  static const pollInterval = Duration(seconds: 2);

  final loading = false.obs;
  final working = false.obs;
  final error = ''.obs;

  /// The active run, or the most recent one. Null before anything has run.
  final run = Rxn<Map<String, Object?>>();

  /// Unresolved failures, newest first.
  final failures = <Map<String, Object?>>[].obs;

  /// The upload phase's status, or null before the first read.
  final uploads = Rxn<Map<String, Object?>>();

  /// Why a run cannot be started right now, empty when it can.
  final blockers = <String>[].obs;

  Timer? _poll;

  @override
  void onInit() {
    super.onInit();
    load();
  }

  @override
  void onClose() {
    _poll?.cancel();
    super.onClose();
  }

  bool get isRunning {
    final status = run.value?['status']?.toString();
    return status == 'QUEUED' || status == 'RUNNING';
  }

  List<Map<String, Object?>> get items =>
      ((run.value?['items'] as List?) ?? const []).cast<Map<String, Object?>>();

  /// A package is going up, or is waiting to: keep the screen live.
  bool get isUploading {
    final u = uploads.value;
    if (u == null || u['enabled'] != true || u['problem'] != null) return false;
    return u['current'] != null ||
        ((u['pending'] as List?)?.isNotEmpty ?? false);
  }

  List<Map<String, Object?>> get uploadFailures =>
      ((uploads.value?['failures'] as List?) ?? const [])
          .cast<Map<String, Object?>>();

  Future<void> load() async {
    loading.value = true;
    try {
      await _refresh();
      error.value = '';
    } on QcApiException catch (e) {
      error.value = e.message;
    } finally {
      loading.value = false;
    }
  }

  /// The three status calls are independent, so they go out together and a
  /// tick costs one round trip. Preflight queries the database for blockers
  /// that cannot change while a run is in flight, so the poll timer skips it.
  Future<void> _refresh({bool includePreflight = true}) async {
    final (current, failed, uploadState) = await (
      _api.exportCurrent(),
      _api.exportFailures(),
      _api.exportUploads(),
    ).wait;
    run.value = current;
    failures.value = failed;
    uploads.value = uploadState;
    if (includePreflight) {
      final preflight = await _api.exportPreflight();
      blockers.value = [
        if (preflight['ready'] != true)
          for (final issue in (preflight['errors'] as List?) ?? const [])
            if (issue is Map && issue['message'] != null)
              issue['message'].toString(),
      ];
    }
    _syncPolling();
  }

  /// Polls only while something is happening, and stops the moment it is not -
  /// a timer left running against a finished run is a background request every
  /// two seconds for as long as the screen is open.
  void _syncPolling() {
    final live = isRunning || isUploading;
    if (live && _poll == null) {
      _poll = Timer.periodic(pollInterval, (_) async {
        try {
          await _refresh(includePreflight: false);
        } on QcApiException {
          // A blip should not tear the screen down; the next tick retries and
          // a real failure surfaces through the run's own status.
        }
      });
    } else if (!live) {
      _poll?.cancel();
      _poll = null;
    }
  }

  /// Every failed upload, back in the sweep's queue.
  Future<bool> retryUploads() async {
    if (working.value) return false;
    working.value = true;
    try {
      uploads.value = await _api.retryUploads();
      error.value = '';
      _syncPolling();
      return true;
    } on QcApiException catch (e) {
      error.value = e.message;
      return false;
    } finally {
      working.value = false;
    }
  }

  Future<bool> runExport() => _act(() => _api.runExport());

  Future<bool> retryFolder(int folderId) =>
      _act(() => _api.retryExportFolder(folderId));

  /// Every unresolved failure, in one run.
  Future<bool> retryAllFailed() => _act(() => _api.retryExports());

  Future<bool> _act(Future<Map<String, Object?>> Function() call) async {
    if (working.value) return false;
    working.value = true;
    try {
      run.value = await call();
      error.value = '';
      // The ledger only changes once the run reaches the folder, so re-read
      // rather than assuming this cleared anything.
      failures.value = await _api.exportFailures();
      _syncPolling();
      return true;
    } on QcApiException catch (e) {
      error.value = e.message;
      return false;
    } finally {
      working.value = false;
    }
  }
}
