/// In-memory cache of box names already used in PostgreSQL, per project —
/// refreshed at the tail of every sync tick (~30s) and consulted by
/// `BoxSessionController.boxNameExists` so two operator PCs can't (usually)
/// mint the same box name in one project. Purely advisory: when sync is off
/// or PG is unreachable the cache is simply empty and behavior degrades to
/// the local-only check. Names are stored lowercased (the check is
/// case-insensitive, matching the local rule).
class CloudBoxNames {
  CloudBoxNames._();
  static final CloudBoxNames instance = CloudBoxNames._();

  final Map<String, Set<String>> _lowerByProjectId = {};
  DateTime? lastRefreshed;

  /// Lowercased cloud box names for [projectId]; empty when unknown/off.
  Set<String> namesFor(String? projectId) =>
      projectId == null ? const {} : _lowerByProjectId[projectId] ?? const {};

  void update(String projectId, Iterable<String> names) {
    _lowerByProjectId[projectId] = names
        .map((n) => n.trim().toLowerCase())
        .toSet();
    lastRefreshed = DateTime.now();
  }

  /// Drops one name ahead of the next pull, so a box deleted here can be
  /// re-created under the same name without waiting out the refresh window.
  void remove(String projectId, String name) {
    _lowerByProjectId[projectId]?.remove(name.trim().toLowerCase());
  }

  /// Test seam / logout hygiene.
  void clear() {
    _lowerByProjectId.clear();
    lastRefreshed = null;
  }
}
