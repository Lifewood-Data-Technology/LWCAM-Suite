// ignore_for_file: avoid_print

import 'dart:async';

import 'package:get/get.dart';

import '../models/qc_task.dart';
import '../services/qc_api_client.dart';
import '../services/qc_engine_service.dart';

/// Which slice of the queue the list is showing. Mirrors the engine's `scope`
/// parameter exactly, so there is nothing to translate.
enum QcScope { pending, mine, completed }

extension QcScopeLabel on QcScope {
  String get wire => name;

  String get label => switch (this) {
        QcScope.pending => 'Available',
        QcScope.mine => 'My tasks',
        QcScope.completed => 'Completed',
      };
}

/// Whether a task in [scope] may be opened in the review screen.
///
/// Reviewing is for work you HOLD. An Available folder offers Claim and nothing
/// else - opening one to look was deliberate once and is not any more, because
/// it let an operator read and navigate a folder somebody else was about to
/// claim.
///
/// Completed is deliberately still openable: that read-only view is a real
/// feature and its queue card is the only way into it, so locking Available must
/// not quietly lock everything.
///
/// The bar is ANY readable page, not every page. It was every page, which meant
/// a folder missing one could not be opened - and opening it is the only way to
/// delete or replace the page that is missing, so the folder was stuck with no
/// route out. A folder with nothing readable stays closed: there is nothing to
/// review, and that is the same condition that disables its Claim button.
bool canOpenQcTask(QcScope scope, QcTask task) =>
    task.anyImageAvailable && scope != QcScope.pending;

/// What the operator can move to once a review has finished.
///
/// Work already HELD comes first: a task still in My task is offered before a
/// fresh claim, so an operator finishes what they took rather than accumulating
/// claims. [claimableCount] is only consulted when nothing is held.
class QcNextUp {
  const QcNextUp({this.claimed, this.claimableCount = 0});

  /// A task already claimed by this operator, ready to open.
  final QcTask? claimed;

  /// Unclaimed tasks waiting in Available. Only meaningful when [claimed] is
  /// null - it costs a request, so it is not fetched when something is held.
  final int claimableCount;

  /// False means do not prompt at all: there is nowhere to go but Available.
  bool get hasSomething => claimed != null || claimableCount > 0;
}

/// Drives the QC task list against the local engine.
///
/// Holds no image or draft state: those belong to the review screen, which is
/// still the web console. This is the first native slice — enough for an
/// operator to sign in, see the queue and take a task.
class QcController extends GetxController {
  final engineUp = false.obs;
  final loading = false.obs;
  final scope = QcScope.pending.obs;
  final tasks = <QcTask>[].obs;
  final total = 0.obs;

  /// Set when the last action failed, cleared when one succeeds. Shown in place
  /// of the list rather than as a snackbar: a queue that is empty because of an
  /// error must not look like a queue that is simply empty.
  final error = ''.obs;

  QcApiClient get _api => QcApiClient.instance;

  @override
  void onInit() {
    super.onInit();
    refreshAll();
  }

  Future<void> refreshAll() async {
    loading.value = true;
    try {
      engineUp.value = await QcEngineService.instance.isEngineResponding();
      if (!engineUp.value) {
        error.value = 'The QC engine is not running on this PC.';
        tasks.clear();
        return;
      }
      await _loadTasks();
    } finally {
      loading.value = false;
    }
  }

  /// The Completed list's search term. Empty means unfiltered.
  final searchQuery = ''.obs;
  Timer? _searchDebounce;

  /// Types straight into the box; the request waits for a pause. Without the
  /// debounce every keystroke would be a round trip to the engine.
  void search(String term) {
    searchQuery.value = term;
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () async {
      if (scope.value != QcScope.completed) return;
      loading.value = true;
      try {
        await _loadTasks();
      } finally {
        loading.value = false;
      }
    });
  }

  Future<void> setScope(QcScope value) async {
    if (scope.value == value) return;
    scope.value = value;
    // Leaving Completed drops the term, so returning to it does not silently
    // show a filtered list with an empty-looking box.
    _searchDebounce?.cancel();
    if (value != QcScope.completed) searchQuery.value = '';
    loading.value = true;
    try {
      await _loadTasks();
    } finally {
      loading.value = false;
    }
  }

  Future<void> _loadTasks() async {
    try {
      final page = await _api.tasks(
        scope: scope.value.wire,
        // Only Completed is searchable, so the term is never sent for the other
        // scopes even if one is still typed in the box.
        query: scope.value == QcScope.completed ? searchQuery.value : null,
      );
      final records = (page['records'] as List?) ?? const [];
      tasks.value = records
          .whereType<Map<String, Object?>>()
          .map(QcTask.fromJson)
          .toList();
      total.value = (page['total'] as num?)?.toInt() ?? tasks.length;
      error.value = '';
    } on QcApiException catch (e) {
      // A rejected token is the one failure worth naming precisely: it means the
      // session with the engine lapsed, not that anything is wrong with the work.
      error.value = e.isUnauthorized
          ? 'The QC session expired. Sign out and back in.'
          : e.message;
      tasks.clear();
      total.value = 0;
    }
  }

  /// Claims a folder and reloads. Returns true when the claim stuck.
  Future<bool> claim(int folderId) async {
    loading.value = true;
    try {
      await _api.claim(folderId);
      scope.value = QcScope.mine;
      await _loadTasks();
      return true;
    } on QcApiException catch (e) {
      error.value = e.message;
      return false;
    } finally {
      loading.value = false;
    }
  }

  /// Claims whatever is next in the caller's projects and returns it.
  ///
  /// Returns the CLAIMED TASK rather than a bool because claiming now opens the
  /// review screen straight away, and only the engine knows which folder it
  /// handed over - `POST /claim-next` answers with the whole task. Null means
  /// nothing was claimed, so an `if (task == null)` guard reads the same way the
  /// old bool did.
  Future<QcTask?> claimNext() async {
    loading.value = true;
    try {
      final claimed = QcTask.fromJson(await _api.claimNext());
      scope.value = QcScope.mine;
      await _loadTasks();
      return claimed;
    } on QcApiException catch (e) {
      error.value = e.message;
      return null;
    } finally {
      loading.value = false;
    }
  }

  /// Sends a finished folder back to QC as a client rework and claims it.
  ///
  /// Returns the reopened task so the caller can go straight into review: the
  /// point of reverting is to fix something, and making the reviewer hunt for
  /// the folder again in the pending queue would be the whole complaint about
  /// Claim next all over again.
  ///
  /// Switches to My tasks on the way, because that is where the folder now is.
  /// Null on refusal - the engine says no when the reviewer already holds a
  /// task, or when the list they clicked from had gone stale.
  Future<QcTask?> revert(QcTask task) async {
    loading.value = true;
    try {
      final reopened = QcTask.fromJson(
        await _api.revert(task.folderId, task.sourceHash),
      );
      scope.value = QcScope.mine;
      searchQuery.value = '';
      await _loadTasks();
      return reopened;
    } on QcApiException catch (e) {
      error.value = e.message;
      return null;
    } finally {
      loading.value = false;
    }
  }

  /// Reloads My task after a review finished, and reports what is next.
  ///
  /// The reload is the point on its own: the engine stops returning an approved
  /// or reworked folder, so re-fetching `mine` is what makes the finished task
  /// leave the list. Without it GetX keeps this controller alive, `onInit` never
  /// runs again, and the operator stares at work they have already done.
  Future<QcNextUp> nextUpAfterCompletion() async {
    scope.value = QcScope.mine;
    loading.value = true;
    try {
      await _loadTasks();
      final held = tasks.firstWhereOrNull((task) => task.imageAvailable);
      if (held != null) return QcNextUp(claimed: held);

      // Nothing held, so ask how much is waiting. Deliberately a COUNT and not
      // claimNext(): the operator has not agreed to take anything yet, and
      // claiming in order to discover whether a claim was possible would leave a
      // folder locked to somebody who then said no.
      try {
        final page = await _api.tasks(scope: QcScope.pending.wire, size: 1);
        final records = (page['records'] as List?) ?? const [];
        return QcNextUp(
          claimableCount: (page['total'] as num?)?.toInt() ?? records.length,
        );
      } on QcApiException {
        // The reload above already succeeded, so the list is honest. Report
        // nothing claimable rather than failing the whole hand-off - the
        // operator lands on Available and can see the real state for themselves.
        return const QcNextUp();
      }
    } finally {
      loading.value = false;
    }
  }

  /// Gives a claimed folder back to the queue.
  Future<bool> release(int folderId) async {
    loading.value = true;
    try {
      await _api.release(folderId);
      await _loadTasks();
      return true;
    } on QcApiException catch (e) {
      error.value = e.message;
      return false;
    } finally {
      loading.value = false;
    }
  }
}
