// ignore_for_file: avoid_print

// In-memory cache of open QC recapture requests per box, for the capture app
// (LWCAM). QC rejects images, PostgreSQL records them, and this cache feeds the
// box list's "Needs Rework" badge and the box view's rework mode.
// Know before editing: a failed read is swallowed on purpose so the box list
// works offline; use lastError and lastRefreshed to show staleness.

import 'rework_service.dart';

/// In-memory cache of the QC recapture requests still open for the logged-in
/// operator, grouped by box — refreshed by `BoxSessionController.loadBoxes` (so
/// on box-list open and on Refresh) and read by the box tile's "Needs Rework"
/// badge and by the box view's rework mode.
///
/// Pattern: [CloudBoxNames] — a plain singleton holding the last successful
/// read, no timers of its own.
///
/// Deliberately SWALLOWS a failed read. [ReworkService.fetchOpenRework] throws
/// when PG is unreachable, which is right for a dedicated worklist screen (an
/// empty list there would read as "nothing to do"), but wrong here: the box list
/// has to keep working offline, and an unbadged box just looks like a normal
/// transferred box. The cost is that rework is invisible while PG is down, which
/// is why [lastRefreshed] and [lastError] are exposed for the UI to surface.
class OpenReworkCache {
  OpenReworkCache._();
  static final OpenReworkCache instance = OpenReworkCache._();

  /// `<lowercased project key>|<lowercased box name>` → that box's open items.
  final Map<String, List<ReworkItem>> _byBox = {};

  DateTime? lastRefreshed;

  /// Why the last refresh found nothing, or null when it succeeded. Set only for
  /// a genuine failure — a successful read with no open rework leaves it null.
  String? lastError;

  static String _key(String? projectKey, String boxName) =>
      '${(projectKey ?? '').trim().toLowerCase()}|${boxName.trim().toLowerCase()}';

  /// Open items for a box, newest-first within a folder as the query returns
  /// them. Empty when the box has none, when PG could not be reached, or when
  /// the box was captured on another station (its rows are assigned to whoever
  /// captured it, and this station could not resolve its input files anyway).
  List<ReworkItem> itemsForBox(String? projectKey, String boxName) =>
      _byBox[_key(projectKey, boxName)] ?? const [];

  bool hasRework(String? projectKey, String boxName) =>
      itemsForBox(projectKey, boxName).isNotEmpty;

  /// Re-reads the worklist for [username]. Never throws: a failure clears the
  /// cache (stale badges would be worse than none — a closed request that keeps
  /// showing sends the operator to re-photograph an image that is already fixed)
  /// and records [lastError].
  ///
  /// [alreadyClosedKeys] are `<projectKey>|<boxName>|<folderSeq>|<imageName>`
  /// closures still queued in this device's outbox (see
  /// UploadStatsDB.pendingReworkClosureKeys). They are filtered out here because
  /// PostgreSQL cannot know about them until the outbox drains — without this a
  /// just-submitted rework keeps its orange badge for up to a sync tick, and the
  /// operator can re-enter rework mode and be asked to redo work they have
  /// already done.
  Future<void> refresh(
    String username, {
    ReworkService? service,
    Set<String> alreadyClosedKeys = const {},
  }) async {
    if (username.trim().isEmpty) {
      clear();
      return;
    }
    try {
      final items = await (service ?? ReworkService()).fetchOpenRework(username);
      _byBox.clear();
      for (final item in items) {
        final key = '${item.projectKey}|${item.boxName}|${item.folderSeq}'
            '|${item.imageName}';
        if (alreadyClosedKeys.contains(key)) continue;
        (_byBox[_key(item.projectKey, item.boxName)] ??= []).add(item);
      }
      lastRefreshed = DateTime.now();
      lastError = null;
    } catch (e) {
      _byBox.clear();
      lastError = e is StateError ? e.message : '$e';
      print('ℹ️ Rework badges unavailable: $lastError');
    }
  }

  /// Test seam / logout hygiene.
  void clear() {
    _byBox.clear();
    lastRefreshed = null;
    lastError = null;
  }
}
