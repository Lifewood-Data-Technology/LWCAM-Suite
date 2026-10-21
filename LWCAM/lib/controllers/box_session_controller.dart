// ignore_for_file: avoid_print

// State and operations for one capture session: the box list, the open box,
// its folders and the images assigned to them (LWCAM capture app).
// A box is a physical batch; each folder carries metadata. Images are copied
// into a durable per-box store as soon as they are shot, so a crash never
// loses them (see box_integrity.dart, orphan_image_store.dart).
// The file also builds the transfer plan, stages files for the transfer queue
// and marks boxes transferred, after which LWIP picks the folders up.
import 'dart:async';
import '../services/color_capture_session.dart';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:path/path.dart' as p;

import '../auth/auth_controller.dart';
import '../controllers/transfer_controller.dart'
    show BoxFolderInfo, BoxTransferContext;
import '../db/upload_stats_db.dart';
import '../models/capture_box_models.dart';
import '../models/metadata_template.dart';
import '../pages/settings_page.dart' show SettingsController;
import '../services/adb_device_service.dart';
import '../services/audit_log_service.dart';
import '../services/box_integrity.dart' as integrity;
import '../services/cloud_box_names.dart';
import '../services/open_rework_cache.dart';
import '../services/orphan_image_store.dart';
import '../services/rework_service.dart' show ReworkItem;
import '../services/safe_copy.dart';
import '../services/processing_marker_service.dart';
import '../services/sync_service.dart';
import '../services/transfer_destination_service.dart';
import '../services/thumbnail_service.dart';

/// One box on the list, with derived counts (pattern: ReworkBoxEntry).
class CaptureBoxEntry {
  final CaptureBox box;
  final int folderCount;
  final int imageCount;
  final bool allFoldersComplete;

  /// Images QC sent back that are still open for this operator, from
  /// [OpenReworkCache] — 0 when there are none AND when PG was unreachable, so
  /// never treat it as proof that a box is clean.
  final int reworkCount;

  const CaptureBoxEntry({
    required this.box,
    required this.folderCount,
    required this.imageCount,
    required this.allFoldersComplete,
    this.reworkCount = 0,
  });

  bool get needsRework => reworkCount > 0;
}

/// List order: rework first, then boxes still being captured, then completed
/// ones; newest first within each group.
///
/// A rework box is TRANSFERRED, so this cannot be done in getCaptureBoxes' SQL
/// ORDER BY — the rework counts come from PostgreSQL, not the local DB. That
/// query's ordering stays as the pre-sort, and [sort] is stable, so boxes with
/// no rework keep it.
///
/// Pure and top-level so it can be tested without a DB or a GetX binding.
void sortBoxEntries(List<CaptureBoxEntry> entries) {
  int rank(CaptureBoxEntry e) =>
      e.needsRework ? 0 : (e.box.isTransferred ? 2 : 1);
  entries.sort((a, b) {
    final byRank = rank(a).compareTo(rank(b));
    if (byRank != 0) return byRank;
    final ca = a.box.createdAt;
    final cb = b.box.createdAt;
    if (ca == null || cb == null) return 0; // keep the query's order
    return cb.compareTo(ca);
  });
}

/// Everything the box-list Transfer action needs after planning: the engine
/// context, the ordered device filenames to stage, and the counts shown in
/// the confirmation dialog.
class BoxTransferPlan {
  final CaptureBox box;
  final BoxTransferContext context;

  /// Device filenames to stage, ordered folder_seq → filename.
  final List<String> orderedSourceNames;
  final int totalAssigned;
  final int skippedAlreadyUploaded;

  /// folderName → number of files that will actually be staged.
  final Map<String, int> perFolderCounts;

  const BoxTransferPlan({
    required this.box,
    required this.context,
    required this.orderedSourceNames,
    required this.totalAssigned,
    required this.skippedAlreadyUploaded,
    required this.perFolderCounts,
  });
}

/// The result of [BoxSessionController.stageBoxFiles]: a stage dir the
/// caller now owns (and must delete once done with it) plus the staged
/// files within it, in [BoxTransferPlan.orderedSourceNames] order.
class StagedBox {
  final Directory stageDir;
  final List<File> files;

  const StagedBox({required this.stageDir, required this.files});
}

/// A folder blocking transfer, with why (used by the gate dialog).
class FolderIssue {
  final CaptureFolder folder;
  final List<String> missingFields; // empty ⇒ the issue is "no images"
  final int imageCount;

  const FolderIssue({
    required this.folder,
    required this.missingFields,
    required this.imageCount,
  });

  String get description {
    final parts = <String>[];
    if (missingFields.isNotEmpty)
      parts.add('missing ${missingFields.join(', ')}');
    if (imageCount == 0) parts.add('no images');
    return 'Folder ${folder.folderSeq}: ${parts.join('; ')}';
  }
}

/// Session state for the Box→Folders capture workflow (keying ON). Registered
/// permanent ONLY by CaptureBoxListPage — its registration is the box-mode
/// signal the gallery checks (no route args, no constructor changes there).
/// Everything is DB-backed, so an app restart resumes cleanly.
class BoxSessionController extends GetxController {
  final AuthController auth;

  /// Filesystem ledger for images whose capture-time DB assignment failed
  /// (transient error / crash / no active folder). Injectable for tests;
  /// defaults to the production AppSupport-backed store.
  final OrphanImageStore orphanStore;

  BoxSessionController(this.auth, {OrphanImageStore? orphanStore})
    : orphanStore = orphanStore ?? OrphanImageStore.production();

  final UploadStatsDB _db = UploadStatsDB();

  /// Single-flight guard so overlapping heal triggers (loadBoxes fired from
  /// closeActiveBox racing openBox) coalesce into one pass.
  Future<void>? _healInFlight;

  AuditLogService? get _auditOrNull =>
      Get.isRegistered<AuditLogService>() ? Get.find<AuditLogService>() : null;

  final boxes = <CaptureBoxEntry>[].obs;
  final isLoading = false.obs;

  /// Non-null when the last [loadBoxes] threw. Without this the page could not
  /// tell "no boxes" from "could not read them", and a failed load rendered an
  /// empty list — indistinguishable from data loss to an operator holding
  /// un-transferred work.
  final Rxn<String> loadError = Rxn<String>();

  final Rxn<CaptureBox> activeBox = Rxn<CaptureBox>();
  final foldersOfActiveBox = <CaptureFolder>[].obs;
  final Rxn<CaptureFolder> activeFolder = Rxn<CaptureFolder>();

  /// filename → folderId cache for the ACTIVE box (loaded on open; kept in
  /// sync by assign/unassign). The DB UNIQUE constraint is the backstop.
  final Map<String, int> _folderIdByFilename = {};

  /// Image count of the active folder — drives the gallery status banner.
  final activeFolderImageCount = 0.obs;

  /// One-shot signal: the box-list Transfer button sets this true before
  /// opening a box so the gallery enters QC view immediately (the pre-transfer
  /// review gate). The gallery reads and clears it in initState.
  bool startInQcView = false;

  /// One-shot signal (same contract as [startInQcView]): the box-list "Rework"
  /// button fills this with the box's open QC requests before opening it, and
  /// the gallery reads and clears it in initState to enter REWORK mode.
  ///
  /// Non-empty is what puts the capture page in rework mode, so it must be
  /// cleared on every other path into the gallery — a stale list would put a
  /// normal capture session into a mode that suppresses the live shutter.
  List<ReworkItem> startInReworkWith = const [];

  // ── Rework staging (survives the capture page) ────────────────────────────
  //
  // Recaptured photos are staged until Submit Rework. These live HERE, not on
  // _GalleryPageState, because leaving the box disposes that page: an operator
  // who recaptured three images, stepped back to the box list and returned
  // found the tiles reverted and had to shoot all three again (reported
  // 2026-07-30). Re-photographing is the expensive part of rework, so it must
  // not be thrown away by navigation.
  //
  // Cleared on a successful submit and whenever a DIFFERENT box is opened —
  // never on page dispose.

  /// image name → recaptured photo waiting to be written.
  final Map<String, File> reworkStaged = {};

  /// image names the operator marked as fixed by a metadata correction.
  final Set<String> reworkMetadataFixed = {};

  /// Holds the staged photos; owned by this controller, deleted with them.
  Directory? reworkStagingDir;

  /// The box [reworkStaged] belongs to, so another box's staging is never shown.
  int? reworkStagedBoxId;

  /// Drops staged rework work and its files. [keepFiles] when the files have
  /// just been consumed by a submit and moved into place.
  Future<void> clearReworkStaging({bool keepFiles = false}) async {
    reworkStaged.clear();
    reworkMetadataFixed.clear();
    reworkStagedBoxId = null;
    final dir = reworkStagingDir;
    reworkStagingDir = null;
    if (dir == null || keepFiles) return;
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      print('ℹ️ Could not delete rework staging dir: $e');
    }
  }

  String get deviceId => auth.deviceId.value.trim();
  String get operatorName =>
      auth.currentUser.value?.username ?? auth.username.value;

  /// Key of the project selected for this capture session (see
  /// AuthController.activeProject) — every box created/listed here is
  /// scoped to it.
  String? get activeProjectKey => auth.activeProject.value?.key;

  /// The active project's LIVE template (or the built-in standard if the
  /// project has none) — used when a box doesn't exist yet (the folder-1
  /// metadata dialog in `_newBox`) and to snapshot into a new box.
  MetadataTemplate get liveProjectTemplate =>
      auth.activeProject.value?.template ?? MetadataTemplate.standard();

  /// Small per-box.id memo so repeatedly resolving a box's template (e.g.
  /// once per folder in loadBoxes) doesn't re-parse the same JSON string.
  final Map<int, MetadataTemplate> _templateCache = {};

  /// The template SNAPSHOTTED on [box] at creation time — falls back to the
  /// standard template for legacy boxes (no snapshot) or unparsable JSON.
  MetadataTemplate templateForBox(CaptureBox box) {
    return _templateCache.putIfAbsent(
      box.id,
      () => MetadataTemplate.fromJsonStringOrStandard(box.templateJson),
    );
  }

  /// The template governing the currently active box (see [openBox]) — what
  /// the folder-metadata dialog and gallery folder chips read while a box is
  /// open. Falls back to the standard template when no box is active
  /// (shouldn't normally be read in that state).
  MetadataTemplate get activeTemplate {
    final box = activeBox.value;
    return box == null ? MetadataTemplate.standard() : templateForBox(box);
  }

  // ── Box list ──────────────────────────────────────────────────────────────

  /// Silently re-files any healable orphaned captures (failed capture-time
  /// DB writes) into the DB. Single-flight so concurrent triggers coalesce;
  /// never throws. Called at box-list load, box open, and pre-transfer — the
  /// natural points where the DB is healthy and the operator is between
  /// actions.
  Future<void> healOrphans() {
    if (deviceId.isEmpty) return Future.value();
    return _healInFlight ??= integrity
        .healOrphanImages(
          db: _db,
          store: orphanStore,
          deviceId: deviceId,
          audit: _auditOrNull,
        )
        .then((_) {})
        .catchError((Object e) {
          print('⚠️ healOrphans: $e');
        })
        .whenComplete(() => _healInFlight = null);
  }

  /// Pre-transfer completeness gate — see box_integrity.verifyBoxComplete.
  /// Returns null when the box is genuinely complete, else a message.
  Future<String?> verifyBoxComplete(CaptureBox box) =>
      integrity.verifyBoxComplete(
        db: _db,
        store: orphanStore,
        deviceId: deviceId,
        boxId: box.id,
      );

  Future<void> loadBoxes() async {
    if (deviceId.isEmpty) return;
    await healOrphans();
    isLoading.value = true;
    loadError.value = null;
    try {
      _templateCache.clear();
      // QC's open recapture requests, so tiles can show "Needs Rework" and sort
      // to the top. Never throws — an unreachable PG just means no badges (see
      // OpenReworkCache), so the box list still works offline. Closures still
      // queued in this device's outbox are filtered out, so a just-submitted
      // rework drops its badge at once instead of waiting for a sync tick.
      //
      // NOT awaited: it opens a fresh PG connection with a 5s connect timeout,
      // and awaiting it gated the whole render — a cold offline open paid ~10s
      // (the page loads twice) and a queued transfer paid 5s per box. The count
      // only annotates and sorts tiles, so render now and badge a beat later.
      final closedKeys = await _db.pendingReworkClosureKeys(deviceId);
      unawaited(
        OpenReworkCache.instance
            .refresh(
              auth.currentUser.value?.username ?? '',
              alreadyClosedKeys: closedKeys,
            )
            .then((_) => _reapplyReworkCounts()),
      );
      final raw = await _db.getCaptureBoxes(
        deviceId,
        projectKey: activeProjectKey,
      );
      final entries = <CaptureBoxEntry>[];
      for (final b in raw) {
        final folders = await _db.getCaptureFolders(
          deviceId: deviceId,
          boxId: b.id,
        );
        final counts = await _db.countImagesPerFolder(
          deviceId: deviceId,
          boxId: b.id,
        );
        final template = templateForBox(b);
        entries.add(
          CaptureBoxEntry(
            box: b,
            folderCount: folders.length,
            imageCount: counts.values.fold(0, (a, c) => a + c),
            allFoldersComplete:
                folders.isNotEmpty &&
                folders.every((f) => template.isCompleteOf(f)),
            reworkCount: OpenReworkCache.instance
                .itemsForBox(b.projectKey, b.boxDetails)
                .length,
          ),
        );
      }
      sortBoxEntries(entries);
      boxes.value = entries;
    } catch (e) {
      print('⚠️ loadBoxes failed: $e');
      loadError.value = e.toString();
    } finally {
      isLoading.value = false;
    }
  }

  /// Re-badges the already-rendered list once the cloud rework counts arrive,
  /// and re-sorts so rework boxes float back to the top. DB-free — the box rows
  /// have not changed, only the counts that annotate them.
  void _reapplyReworkCounts() {
    if (boxes.isEmpty) return;
    final updated = [
      for (final e in boxes)
        CaptureBoxEntry(
          box: e.box,
          folderCount: e.folderCount,
          imageCount: e.imageCount,
          allFoldersComplete: e.allFoldersComplete,
          reworkCount: OpenReworkCache.instance
              .itemsForBox(e.box.projectKey, e.box.boxDetails)
              .length,
        ),
    ];
    sortBoxEntries(updated);
    boxes.value = updated;
  }

  /// True when [details] duplicates ANY box in the project — transferred
  /// ones included: box names are unique per project (the cloud schema's
  /// UNIQUE(project_id, box_name) has no status carve-out, so a reused name
  /// would be rejected at sync time anyway). `boxes` is already filtered to
  /// the active project. [excludeBoxId] skips a box's own row on rename.
  ///
  /// Also consults the cloud name cache (boxes other PCs created in this
  /// project, pulled from PG every sync tick) — empty when sync is off or PG
  /// is unreachable, so the check silently degrades to local-only. The ~30s
  /// refresh window means two PCs can still race the same name; the sink's
  /// ON CONFLICT (project_id, box_name) merges rather than duplicates.
  bool boxNameExists(String details, {int? excludeBoxId}) {
    final wanted = details.trim().toLowerCase();
    final local = boxes.any(
      (e) =>
          e.box.id != excludeBoxId && e.box.boxDetails.toLowerCase() == wanted,
    );
    if (local) return true;
    // renameBox's same-name early return keeps a box's own cloud row from
    // false-positiving here.
    return CloudBoxNames.instance
        .namesFor(auth.activeProject.value?.key)
        .contains(wanted);
  }

  /// Re-reads the shared users store so a template edited on another PC (or
  /// by SuperAdmin mid-shift) is picked up BEFORE a new box snapshots it —
  /// without this, an operator logged in all day would keep stamping the
  /// template from their last login. Best-effort: offline/NAS-down keeps the
  /// session's current copy (refresh never throws).
  Future<void> refreshActiveProjectTemplate() async {
    final store = auth.usersStore;
    final key = activeProjectKey;
    if (store == null || key == null) return;
    await store.refresh();
    final fresh = store.projects.firstWhereOrNull((p) => p.key == key);
    if (fresh != null) auth.activeProject.value = fresh;
  }

  /// Creates a box and returns it (see [boxNameExists] for the duplicate
  /// rule — the New Box dialog checks it up front too, before the metadata
  /// form; this is the backstop).
  Future<CaptureBox> createBox(String boxDetails) async {
    final details = boxDetails.trim();
    if (boxNameExists(details)) {
      throw StateError(
        'A group named "$details" already exists in this project.',
      );
    }
    final projectKey = activeProjectKey;
    // Best-effort live PG check — shrinks the race window the ~30s
    // CloudBoxNames cache leaves open. Fails open to the cache above when
    // sync is off, PG is unreachable, or no SyncService is registered.
    if (projectKey != null && Get.isRegistered<SyncService>()) {
      final fresh = await Get.find<SyncService>().fetchFreshBoxNames(
        projectKey,
      );
      if (fresh != null &&
          fresh
              .map((n) => n.trim().toLowerCase())
              .contains(details.toLowerCase())) {
        throw StateError(
          'A group named "$details" already exists in this project.',
        );
      }
    }
    // Always stamp a snapshot (even the standard template) so a box's
    // semantics are frozen at creation regardless of later project/template
    // edits — see MetadataTemplate.fromJsonStringOrStandard for the read side.
    final templateJson = jsonEncode(liveProjectTemplate.toJson());
    final id = await _db.insertCaptureBox(
      deviceId: deviceId,
      boxDetails: details,
      scanningOpr: operatorName,
      projectKey: projectKey,
      projectId: auth.activeProject.value?.projectId,
      templateJson: templateJson,
    );
    if (projectKey != null) {
      // Best-effort advisory stamp on the shared store — never blocks box
      // creation (markProjectHasData swallows its own failures).
      unawaited(
        auth.usersStore?.markProjectHasData(projectKey: projectKey) ??
            Future.value(),
      );
    }
    await loadBoxes();
    await _auditOrNull?.log(AuditActions.boxCreate, details: {'box': details});
    return (await _db.getCaptureBoxById(deviceId: deviceId, boxId: id))!;
  }

  /// Corrects a box's details (e.g. a typo at creation), refusing a name
  /// that duplicates ANY other box in the project (same rule as createBox).
  /// Folder names are computed from box_details at transfer, so this one
  /// edit fixes every folder's destination name.
  Future<void> renameBox(CaptureBox box, String newDetails) async {
    final details = newDetails.trim();
    if (details.isEmpty) {
      throw StateError('Group Details cannot be empty.');
    }
    // Same name (case-insensitively) is a no-op, not a duplicate — without
    // this, the box's own row in the cloud name cache would block it.
    if (details.toLowerCase() == box.boxDetails.trim().toLowerCase()) {
      return;
    }
    if (boxNameExists(details, excludeBoxId: box.id)) {
      throw StateError(
        'A group named "$details" already exists in this project.',
      );
    }
    final previousDetails = box.boxDetails;
    await _db.updateCaptureBoxDetails(
      deviceId: deviceId,
      boxId: box.id,
      boxDetails: details,
    );
    // Keep any live active-box reference in sync so an open capture session
    // reflects the new name immediately.
    if (activeBox.value?.id == box.id) {
      final refreshed = await _db.getCaptureBoxById(
        deviceId: deviceId,
        boxId: box.id,
      );
      if (refreshed != null) activeBox.value = refreshed;
    }
    await loadBoxes();
    await _auditOrNull?.log(
      AuditActions.boxRename,
      details: {'from': previousDetails, 'to': details},
    );
  }

  /// Deletes an empty box. Refuses (throws) when any image is assigned to it
  /// or an unresolved orphan still targets it — an orphan IS a captured image
  /// whose assignment write failed, so a box with one is not empty.
  Future<void> deleteBox(CaptureBox box) async {
    if (activeBox.value?.id == box.id) {
      throw StateError('Close the group before deleting it.');
    }
    final orphans = (await orphanStore.list(
      deviceId,
    )).where((e) => e.boxId == box.id).length;
    if (orphans > 0) {
      throw StateError(
        '$orphans unresolved image(s) still belong to this group — '
        'resolve them under Unresolved Images first.',
      );
    }
    final deleted = await _db.deleteCaptureBox(
      deviceId: deviceId,
      boxId: box.id,
    );
    if (!deleted) {
      throw StateError('This group has images and cannot be deleted.');
    }
    final projectKey = box.projectKey;
    if (projectKey != null) {
      CloudBoxNames.instance.remove(projectKey, box.boxDetails);
    }
    await loadBoxes();
    await _auditOrNull?.log(
      AuditActions.boxDelete,
      details: {'box': box.boxDetails},
    );
  }

  /// Deletes an empty folder of the active box. Refuses (throws) when it is the
  /// active folder, when an unresolved orphan still targets it, or when any
  /// image is assigned to it.
  ///
  /// Refusing on "active" also keeps a box from reaching zero folders: every
  /// capture would then have no assignment destination and stash as an orphan.
  /// [openBox] always makes some folder active when the box has any, so a
  /// box's last folder is necessarily the active one.
  ///
  /// folder_seq is deliberately NOT renumbered afterwards: cloud identity is
  /// (box, folder_seq) and insertCaptureFolder takes MAX+1, so a gap is
  /// correct and renumbering would repoint live cloud rows.
  Future<void> deleteFolder(CaptureFolder folder) async {
    if (activeFolder.value?.id == folder.id) {
      throw StateError('Make another folder active before deleting this one.');
    }
    // An orphan IS a captured image whose assignment write failed, so a folder
    // with one is not empty. healOrphans would demote it to unknown rather than
    // lose the bytes, but silently -- the operator should decide instead.
    final orphans = (await orphanStore.list(
      deviceId,
    )).where((e) => e.folderId == folder.id).length;
    if (orphans > 0) {
      throw StateError(
        '$orphans unresolved image(s) still belong to this folder - '
        'resolve them under Unresolved Images first.',
      );
    }
    // The DB layer counts inside its transaction, so this is the race-safe
    // gate; the UI's own image count is only an optimistic hint.
    final deleted = await _db.deleteCaptureFolder(
      deviceId: deviceId,
      folderId: folder.id,
    );
    if (!deleted) {
      throw StateError('This folder has images and cannot be deleted.');
    }
    final box = activeBox.value;
    if (box != null) {
      // Only the gallery's folder list is stale; loadBoxes() would rebuild the
      // whole box list and re-hit PostgreSQL for rework counts.
      foldersOfActiveBox.value = await _db.getCaptureFolders(
        deviceId: deviceId,
        boxId: box.id,
      );
    }
    await _auditOrNull?.log(
      AuditActions.folderDelete,
      details: {'box': box?.boxDetails, 'seq': folder.folderSeq},
    );
  }

  // ── Active box / folders ─────────────────────────────────────────────────

  /// Loads a box's folders + assignments and makes it active. Resumes to the
  /// operator's last active folder (persisted per box — folders can be
  /// freely re-activated, not just the most recently created) when it still
  /// exists; falls back to the last-created folder otherwise (first open,
  /// or the remembered folder was somehow removed). Does NOT navigate — the
  /// caller decides.
  Future<void> openBox(CaptureBox box) async {
    // Heal first so any recovered assignment shows up in the load below.
    await healOrphans();
    // Staged rework belongs to one box; opening a different one discards it
    // (reopening the SAME box keeps it — that is the whole point).
    if (reworkStagedBoxId != null && reworkStagedBoxId != box.id) {
      await clearReworkStaging();
    }
    activeBox.value = box;
    foldersOfActiveBox.value = await _db.getCaptureFolders(
      deviceId: deviceId,
      boxId: box.id,
    );
    _folderIdByFilename
      ..clear()
      ..addAll(
        await _db.getAssignmentsForBox(deviceId: deviceId, boxId: box.id),
      );
    final remembered = box.lastActiveFolderId == null
        ? null
        : foldersOfActiveBox.firstWhereOrNull(
            (f) => f.id == box.lastActiveFolderId,
          );
    activeFolder.value =
        remembered ??
        (foldersOfActiveBox.isEmpty ? null : foldersOfActiveBox.last);
    _refreshActiveFolderCount();
  }

  /// Inserts a new folder (draft allowed) and makes it the active one.
  Future<CaptureFolder> createFolder(CaptureFolder draft) async {
    final box = activeBox.value;
    if (box == null) throw StateError('No active group.');
    final id = await _db.insertCaptureFolder(
      deviceId: deviceId,
      folder: draft,
      isComplete: templateForBox(box).isCompleteOf(draft),
      captureOperatorName: operatorName,
    );
    foldersOfActiveBox.value = await _db.getCaptureFolders(
      deviceId: deviceId,
      boxId: box.id,
    );
    final created = foldersOfActiveBox.firstWhere((f) => f.id == id);
    await setActiveFolder(created);
    await _auditOrNull?.log(
      AuditActions.folderCreate,
      details: {'box': box.boxDetails, 'seq': created.folderSeq},
    );
    return created;
  }

  /// Makes [folder] (any folder of the active box) the active one — new
  /// captures are assigned to whichever folder is active, regardless of
  /// creation order. Existing assignments are never moved. Persisted so
  /// reopening the box resumes here.
  Future<void> setActiveFolder(CaptureFolder folder) async {
    activeFolder.value = folder;
    _refreshActiveFolderCount();
    final box = activeBox.value;
    if (box == null) return;
    try {
      await _db.setBoxActiveFolder(
        deviceId: deviceId,
        boxId: box.id,
        folderId: folder.id,
      );
    } catch (e) {
      print('⚠️ Failed to persist active folder ${folder.id}: $e');
    }
  }

  /// Persists edited metadata for an existing folder of the active box.
  Future<void> updateFolder(CaptureFolder folder) async {
    final box = activeBox.value;
    final isComplete =
        (box == null ? MetadataTemplate.standard() : templateForBox(box))
            .isCompleteOf(folder);
    await _db.updateCaptureFolderMetadata(
      deviceId: deviceId,
      folder: folder,
      isComplete: isComplete,
    );
    if (box != null) {
      foldersOfActiveBox.value = await _db.getCaptureFolders(
        deviceId: deviceId,
        boxId: box.id,
      );
      if (activeFolder.value?.id == folder.id) {
        activeFolder.value = foldersOfActiveBox.firstWhereOrNull(
          (f) => f.id == folder.id,
        );
      }
    }
    await _auditOrNull?.log(
      AuditActions.folderUpdate,
      details: {'box': box?.boxDetails ?? '', 'seq': folder.folderSeq},
    );
  }

  /// Durable per-box local image store: box transfers stage from here (after
  /// verifying against the device) so the whole box needn't be re-pulled.
  /// Deleted after a fully successful transfer.
  ///
  /// Lives under the app-support folder (AppData) — hidden by default, so
  /// operators browsing their profile can't accidentally delete or edit
  /// staged box images (deliberate access by the same Windows user is still
  /// possible; this is tamper-resistance, not encryption). Keyed by device ID
  /// as well as box id: box ids auto-increment per device DB, so two Device
  /// IDs on one PC would otherwise collide on the same `box_<id>` folder.
  Future<Directory> _boxImagesDir(int boxId) =>
      integrity.boxImagesDir(deviceId, boxId);

  /// Assigns a newly captured device image to the ACTIVE folder. No-op when
  /// the name is already mapped (cache short-circuit; the DB UNIQUE
  /// constraint is the real guard). When [localFile] is given (the live-sync's
  /// freshly pulled copy) it is persisted into the box's durable local store —
  /// best-effort, transfer re-pulls anything missing.
  ///
  /// Capture-integrity: the DB write is retried (transient WAL locks clear on
  /// a short backoff); if it still throws, or there's no active folder to
  /// file into, the pulled bytes are stashed to the orphan ledger with the
  /// recovery intent so healOrphans/an admin can re-file them — the count can
  /// never silently diverge. Operators see nothing (no DB prompts).
  Future<void> assignNewImage(String deviceFilename, {File? localFile}) async {
    final box = activeBox.value;
    final folder = activeFolder.value;
    if (box == null || folder == null) {
      // A capture with nowhere to file it (zero-folder box). Preserve the
      // bytes + whatever intent we have rather than dropping it silently.
      await _stashOrphan(
        localFile,
        deviceFilename,
        boxId: box?.id,
        folderId: null,
        reason: 'no-active-folder',
      );
      return;
    }
    if (_folderIdByFilename.containsKey(deviceFilename)) return;

    ColorBinding? binding;
    final bool ok;
    try {
      binding = await ColorCaptureSession.bindingFor(deviceId, deviceFilename);
      ok = await retrying(
        () => _db.assignImageToFolder(
          deviceId: deviceId,
          boxId: box.id,
          folderId: folder.id,
          deviceFilename: deviceFilename,
          colorBinding: binding?.toJson(),
        ),
      );
    } catch (e) {
      // Retries exhausted — stash with full intent for silent heal later.
      await _stashOrphan(
        localFile,
        deviceFilename,
        boxId: box.id,
        folderId: folder.id,
        reason: 'db-error: $e',
        colorBinding: binding?.toJson(),
      );
      return;
    }

    // ok == false is a UNIQUE conflict (already assigned / stale cache) — not
    // an orphan, so it stays a silent no-op.
    if (ok) {
      _folderIdByFilename[deviceFilename] = folder.id;
      _refreshActiveFolderCount();
      if (localFile != null && await localFile.exists()) {
        try {
          final dir = await _boxImagesDir(box.id);
          await safeCopy(localFile, p.join(dir.path, deviceFilename));
        } catch (e) {
          print('ℹ️ Local persist skipped for $deviceFilename: $e');
        }
      }
    }
  }

  /// Copies the pulled bytes into the orphan ledger with recovery intent so
  /// the capture is never lost when its assignment can't be written. Skips
  /// (with a print) when there are no local bytes to stash — the only caller
  /// always passes the freshly pulled file, so that's purely defensive.
  Future<void> _stashOrphan(
    File? localFile,
    String deviceFilename, {
    int? boxId,
    int? folderId,
    required String reason,
    Map<String, dynamic>? colorBinding,
  }) async {
    if (localFile == null || !await localFile.exists()) {
      print('⚠️ Orphan $deviceFilename has no local bytes to stash ($reason).');
      return;
    }
    final entry = await orphanStore.stash(
      source: localFile,
      deviceId: deviceId,
      deviceFilename: deviceFilename,
      boxId: boxId,
      folderId: folderId,
      reason: reason,
      colorBinding: colorBinding,
    );
    if (entry != null) {
      await _auditOrNull?.log(
        AuditActions.orphanStashed,
        details: {
          'file': deviceFilename,
          'box': boxId ?? '',
          'folder': folderId ?? '',
          'reason': reason,
        },
      );
    }
  }

  /// Removes the mapping for a deleted device photo (any folder of the box),
  /// plus its durable local copy.
  Future<void> unassignImage(String deviceFilename) async {
    try {
      final removed = await _db.unassignImage(
        deviceId: deviceId,
        deviceFilename: deviceFilename,
      );
      if (!removed) return; // transferred — refused; only QC may delete it
      _folderIdByFilename.remove(deviceFilename);
      _refreshActiveFolderCount();
      final box = activeBox.value;
      if (box != null) {
        final copy = File(
          p.join((await _boxImagesDir(box.id)).path, deviceFilename),
        );
        if (await copy.exists()) await copy.delete();
      }
      await _auditOrNull?.log(
        AuditActions.imageUnassigned,
        details: {'file': deviceFilename, 'box': box?.boxDetails ?? ''},
      );
    } catch (e) {
      print('⚠️ unassignImage($deviceFilename) failed: $e');
    }
  }

  /// filename → folderId snapshot for the active box (used by the box-mode
  /// gallery sections and transfer prep).
  Map<String, int> get assignments => Map.unmodifiable(_folderIdByFilename);

  /// Replaces the durable local copy of an already-assigned image.
  ///
  /// A swap recapture changes the BYTES under an existing filename, and every
  /// later reader prefers this store over the phone: the gallery copies from it
  /// when reopening a box, and stageBoxFiles reuses it at transfer time when
  /// its size matches the device's. Leaving it holding the superseded photo
  /// meant reopening the box showed the old image again - and, if the two
  /// photos happened to be the same size, that the OLD one transferred.
  ///
  /// Best-effort like the capture-time persist above: the phone still has the
  /// swapped file, so a failure here costs a re-pull, not the image.
  Future<void> replaceDurableImage(String deviceFilename, File source) async {
    final box = activeBox.value;
    if (box == null || !await source.exists()) return;
    try {
      final dir = await _boxImagesDir(box.id);
      await safeCopy(source, p.join(dir.path, deviceFilename));
    } catch (e) {
      print('ℹ️ Durable replace skipped for $deviceFilename: $e');
    }
  }

  /// Public accessor to the active box's durable local image store (see
  /// [_boxImagesDir]) — lets the gallery prefer an already-pulled copy over
  /// a fresh ADB pull when (re)loading the box's assigned images. Null when
  /// no box is active.
  Future<Directory?> get activeBoxImagesDir async {
    final box = activeBox.value;
    if (box == null) return null;
    return _boxImagesDir(box.id);
  }

  void _refreshActiveFolderCount() {
    final folder = activeFolder.value;
    activeFolderImageCount.value = folder == null
        ? 0
        : _folderIdByFilename.values.where((id) => id == folder.id).length;
  }

  /// Clears the active box (leaving the gallery back to the list).
  void closeActiveBox() {
    activeBox.value = null;
    activeFolder.value = null;
    foldersOfActiveBox.clear();
    _folderIdByFilename.clear();
    activeFolderImageCount.value = 0;
    // Refresh list counts in the background.
    loadBoxes();
  }

  // ── Transfer (gate → plan → stage) ────────────────────────────────────────

  /// Folders that block a box's transfer: metadata-incomplete or zero images.
  /// Template resolved from THIS box's own snapshot — [box] need not be the
  /// active one (the box-list Transfer action can gate any box).
  Future<List<FolderIssue>> folderIssues(CaptureBox box) async {
    final folders = await _db.getCaptureFolders(
      deviceId: deviceId,
      boxId: box.id,
    );
    final counts = await _db.countImagesPerFolder(
      deviceId: deviceId,
      boxId: box.id,
    );
    final template = templateForBox(box);
    return [
      for (final f in folders)
        if (!template.isCompleteOf(f) || (counts[f.id] ?? 0) == 0)
          FolderIssue(
            folder: f,
            missingFields: template.missingMandatoryFieldsOf(f),
            imageCount: counts[f.id] ?? 0,
          ),
    ];
  }

  /// Replicates the transfer engine's generated base name for a device
  /// filename (deviceId_IMG_YYYYMMDD_HHMMSS) so already-recorded files can be
  /// skipped — the "only NEW images" retry story.
  String _baseNameForDeviceFilename(String name) =>
      integrity.baseNameForDeviceFilename(deviceId, name);

  /// Computes + persists the destination folder names (each folder's Volume —
  /// see computeFolderNames) and builds the transfer plan. Pure DB work
  /// — no ADB. Call this before showing the confirmation dialog. Template
  /// resolved from THIS box's own snapshot (not necessarily the active box).
  Future<BoxTransferPlan> buildBoxTransferPlan(CaptureBox box) async {
    // Re-file any healable orphans first so this plan sees the full box.
    await healOrphans();
    final template = templateForBox(box);
    final folders = await _db.getCaptureFolders(
      deviceId: deviceId,
      boxId: box.id,
    );
    if (folders.isEmpty) throw StateError('This group has no folders.');

    // Names are computed against the box's CURRENT folder set and persisted so
    // retries stay stable. The Volume itself is NEVER rewritten here any more:
    // prep used to substitute "(unknown file [n])" into a numberless folder's
    // Volume, so what the operator keyed and what was exported could differ.
    // The folder name is now just the Volume (see computeFolderNames).
    // Names taken by other groups are reserved too: the destination day folder
    // is shared across groups, so a repeated name is a merged directory.
    var reserved = await _db.reservedFolderNames(
      deviceId: deviceId,
      excludeBoxId: box.id,
    );
    var names = computeFolderNames(box.boxDetails, folders, reserved: reserved);
    // A folder on the LWIP input share may already carry ANOTHER box's marker
    // (two capture PCs, same day, same Volume): that is not in this PC's DB, so
    // reserve those names too and take the suffixed one instead of merging.
    final dayDir = TransferDestinationService.isDayDirectory(box.transferredTo)
        ? box.transferredTo!.trim()
        : Get.isRegistered<SettingsController>() &&
              Get.find<SettingsController>().destinationPath.value.trim().isNotEmpty
        ? TransferDestinationService.directoryForDate(
            Get.find<SettingsController>().destinationPath.value.trim(),
            DateTime.now(),
          ).path
        : null;
    if (dayDir != null) {
      final boxKeys = await _db.boxNaturalKeys(deviceId: deviceId, boxId: box.id);
      for (var round = 0; round < 5; round++) {
        final foreign = await foreignMarkerFolderNames(
          dayDir: dayDir,
          boxKeys: boxKeys,
          folderSeqByName: {
            for (var i = 0; i < folders.length; i++) names[i]: folders[i].folderSeq,
          },
        );
        if (foreign.isEmpty) break;
        reserved = {...reserved, ...foreign};
        names = computeFolderNames(box.boxDetails, folders, reserved: reserved);
      }
    }
    final finalized = <CaptureFolder>[];
    for (var i = 0; i < folders.length; i++) {
      final f = folders[i];
      await _db.updateCaptureFolderName(
        deviceId: deviceId,
        folderId: f.id,
        folderName: names[i],
      );
      // Persist every template-DERIVED effective value onto the folder row —
      // the cloud capture_folders carries them as real columns, and the sync
      // payload snapshots the ROW, not the template. A mapped Start Date
      // (derived from Title) used to exist only in the CSV: the row stayed
      // NULL, so QC and the export saw no dates at all.
      await _db.updateCaptureFolderEffectiveValues(
        deviceId: deviceId,
        folderId: f.id,
        startDate: template.effectiveValueOf(kStartDateFieldId, f),
        endDate: template.effectiveValueOf(kEndDateFieldId, f),
        recordType: template.effectiveValueOf(kRecordTypeFieldId, f),
        place: template.fixedCsvValueOf('place', f),
        language: template.fixedCsvValueOf('language', f),
        recordCustodian: template.fixedCsvValueOf('record_custodian', f),
        digitizingEntity: template.fixedCsvValueOf('digitizing_entity', f),
        captureOperatorId: template.fixedCsvValueOf('capture_operator_id', f),
        captureOperatorName: template.fixedCsvValueOf(
          'capture_operator_name',
          f,
        ),
      );
      finalized.add(f.copyWith(folderName: names[i]));
    }

    // Values are EFFECTIVE per the box's template: a disabled field exports
    // null, a fixed field exports its constant, a mapped field is derived
    // from its main field, and an editable field exports what was keyed.
    // Fixed-field values are resolved PER FOLDER (not once for the whole
    // box) because a §8.3 field can be MAPPED from a keyed field (e.g.
    // Language mapped from Title) and so can vary folder-to-folder.
    final infoByFolderId = <int, BoxFolderInfo>{
      for (final f in finalized)
        f.id: BoxFolderInfo(
          folderName: f.folderName!,
          coverTag: template.effectiveValueOf(kCoverTagFieldId, f),
          imageTags: template.effectiveValueOf(kImageTagsFieldId, f),
          title: template.effectiveValueOf(kTitleFieldId, f),
          volume: template.effectiveValueOf(kVolumeFieldId, f),
          startDate: template.effectiveValueOf(kStartDateFieldId, f),
          endDate: template.effectiveValueOf(kEndDateFieldId, f),
          archivalRefNo: template.effectiveValueOf(kArchivalRefNoFieldId, f),
          recordType: template.effectiveValueOf(kRecordTypeFieldId, f),
          fixedFieldValues: {
            for (final column in kFixedFieldCsvColumns)
              column: template.fixedCsvValueOf(column, f),
          },
        ),
    };

    final assignments = await _db.getAssignmentsForBox(
      deviceId: deviceId,
      boxId: box.id,
    );

    // Order: folder_seq, then filename within each folder.
    final orderedNames = <String>[];
    final infoBySourceName = <String, BoxFolderInfo>{};
    for (final f in finalized) {
      final filesOfFolder =
          assignments.entries
              .where((e) => e.value == f.id)
              .map((e) => e.key)
              .toList()
            ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      for (final name in filesOfFolder) {
        orderedNames.add(name);
        infoBySourceName[name] = infoByFolderId[f.id]!;
      }
    }

    // "Only NEW images": drop files whose generated base name is already in
    // upload_records — records are written only AFTER a verified copy, so an
    // interrupted/corrupted file is never in this set and always re-stages.
    final uploadedBaseNames = (await _db.getUploadedBaseNames(
      deviceId,
    )).toSet();
    final recordedFilenames = await _db.getUploadedFilenames(deviceId);
    final toStage = <String>[];
    var skipped = 0;
    for (final name in orderedNames) {
      final base = _baseNameForDeviceFilename(name);
      if (base.isNotEmpty && uploadedBaseNames.contains(base)) {
        final reconciled = await _db.reconcileCaptureImageTransferName(
          deviceId: deviceId,
          deviceName: name,
          recordedFilenames: recordedFilenames,
        );
        if (!reconciled) {
          throw StateError(
            'The transfer record for $name has no unique final filename. '
            'The group remains retryable.',
          );
        }
        skipped++;
      } else {
        toStage.add(name);
      }
    }

    final perFolderCounts = <String, int>{};
    for (final name in toStage) {
      final folderName = infoBySourceName[name]!.folderName;
      perFolderCounts[folderName] = (perFolderCounts[folderName] ?? 0) + 1;
    }

    return BoxTransferPlan(
      box: box,
      context: BoxTransferContext(
        boxId: box.id,
        boxDetails: box.boxDetails,
        infoBySourceName: infoBySourceName,
      ),
      orderedSourceNames: toStage,
      totalAssigned: orderedNames.length,
      skippedAlreadyUploaded: skipped,
      perFolderCounts: perFolderCounts,
    );
  }

  /// Stages the plan's files, mostly from the box's durable local store —
  /// but the PHONE IS THE SOURCE OF TRUTH and must be connected: every
  /// assigned file is verified against the device listing first. Missing on
  /// device → abort; local copy present with the device's size → used as-is;
  /// otherwise (no/stale local copy, e.g. a swap recapture changed the bytes)
  /// → re-pulled fresh. Overlay replacements are materialized UNDER the slot
  /// name from the preserved replacement copy (or pulled). Throws if any
  /// assigned file cannot be produced — a partial box must never transfer
  /// silently.
  ///
  /// Each call gets its OWN stage dir (`Directory.systemTemp.createTemp`
  /// already guarantees uniqueness) — callers (the background transfer
  /// queue) own the returned [StagedBox] and are responsible for deleting
  /// its `stageDir` once done with it.
  Future<StagedBox> stageBoxFiles(
    BoxTransferPlan plan, {
    void Function(int done, int total)? onProgress,
  }) async {
    final adb = AdbDeviceService();

    // Device verification — hard requirement, not best-effort.
    final deviceNames = (await adb.listDeviceImageNames())?.toSet();
    if (deviceNames == null) {
      throw StateError(
        'The phone is not reachable. Connect the capture device — it is '
        'verified before every group transfer.',
      );
    }
    final deviceSizes =
        await adb.listDeviceImageSizes() ?? const <String, int>{};

    // original slot name → active replacement record (overlay or swap).
    final replacementRows = await _db.getReplacementRecords(deviceId);
    final replacementByOriginal = <String, Map<String, dynamic>>{
      for (final r in replacementRows) (r['original_filename'] as String): r,
    };

    // ponytail: phone stays authoritative whenever it HAS the file; the
    // durable box_images copy is trusted only when the phone no longer does
    // (a healed/admin-resolved orphan whose device file is gone). Without
    // this fallback such a file could never transfer — the box would loop
    // "reopen to refresh" forever and eventually lose the bytes.
    final localStore = await _boxImagesDir(plan.box.id);

    // Overlay slots are verified against their REPLACEMENT device file; all
    // others against the slot name itself.
    final missingOnDevice = <String>[];
    for (final name in plan.orderedSourceNames) {
      final replacement = replacementByOriginal[name];
      final isOverlay =
          replacement != null &&
          (replacement['replacement_type']?.toString() ?? '') !=
              'recapture-swap';
      final verifyName = isOverlay
          ? replacement['replacement_filename'] as String
          : name;
      // An overlay's preserved local replacement copy is acceptable even if
      // the replacement file was later cleaned off the device.
      final localReplacement = isOverlay
          ? replacement['replacement_local_path']?.toString()
          : null;
      final hasLocalReplacement =
          localReplacement != null &&
          localReplacement.isNotEmpty &&
          File(localReplacement).existsSync();
      // Non-overlay durable-store fallback (see the note above).
      final hasLocalDurable =
          !isOverlay && File(p.join(localStore.path, name)).existsSync();
      if (!deviceNames.contains(verifyName) &&
          !hasLocalReplacement &&
          !hasLocalDurable) {
        missingOnDevice.add(name);
      }
    }
    if (missingOnDevice.isNotEmpty) {
      throw StateError(
        '${missingOnDevice.length} assigned image(s) are no longer on the '
        'device (e.g. ${missingOnDevice.take(3).join(', ')}). The phone is '
        'the source of truth — reopen the group to refresh its contents, then '
        'try again.',
      );
    }

    final stageDir = await Directory.systemTemp.createTemp(
      'box_transfer_stage',
    );

    final staged = <File>[];
    final failed = <String>[];
    var done = 0;
    var reused = 0;
    var pulled = 0;
    for (final name in plan.orderedSourceNames) {
      File? file;
      final slotTarget = File(p.join(stageDir.path, name));
      final replacement = replacementByOriginal[name];
      final isOverlay =
          replacement != null &&
          (replacement['replacement_type']?.toString() ?? '') !=
              'recapture-swap';

      if (isOverlay) {
        // Overlay: the corrected bytes are the replacement, staged under the
        // slot name.
        final localPath = replacement['replacement_local_path']?.toString();
        if (localPath != null &&
            localPath.isNotEmpty &&
            File(localPath).existsSync()) {
          await safeCopy(File(localPath), slotTarget.path);
          file = slotTarget;
        } else {
          final fresh = await adb.pullSingleFile(
            replacement['replacement_filename'] as String,
            targetDir: stageDir,
          );
          if (fresh != null) file = await fresh.rename(slotTarget.path);
          pulled++;
        }
      } else {
        final localCopy = File(p.join(localStore.path, name));
        final deviceSize = deviceSizes[name];
        if (!deviceNames.contains(name) && await localCopy.exists()) {
          // Phone no longer has it (healed/admin-resolved orphan) — the
          // durable copy is now authoritative; a pull would be doomed.
          await safeCopy(localCopy, slotTarget.path);
          file = slotTarget;
          reused++;
        } else if (await localCopy.exists() &&
            deviceSize != null &&
            await localCopy.length() == deviceSize) {
          // Local-first: reuse the capture-time copy when its size matches the
          // device's (size unknown → don't trust it, re-pull).
          await safeCopy(localCopy, slotTarget.path);
          file = slotTarget;
          reused++;
        } else {
          file = await adb.pullSingleFile(name, targetDir: stageDir);
          pulled++;
          // Refresh the durable copy for a later retry.
          if (file != null && await file.exists()) {
            try {
              await safeCopy(file, localCopy.path);
            } catch (_) {}
          }
        }
      }

      if (file == null || !file.existsSync()) {
        failed.add(name);
      } else {
        staged.add(file);
      }
      done++;
      onProgress?.call(done, plan.orderedSourceNames.length);
    }

    print(
      '📦 Box staging: $reused reused from local store, $pulled pulled fresh.',
    );

    if (failed.isNotEmpty) {
      try {
        await stageDir.delete(recursive: true);
      } catch (e) {
        print('⚠️ Could not delete box staging dir: $e');
      }
      throw StateError(
        '${failed.length} assigned image(s) could not be read from the device '
        '(e.g. ${failed.take(3).join(', ')}). Check the connection and try again.',
      );
    }
    return StagedBox(stageDir: stageDir, files: staged);
  }

  /// Persists a 512px thumbnail for every image assigned to [box] so the
  /// read-only transferred-box view still has something to show once
  /// [markTransferred] deletes the full-resolution durable store. Call this
  /// BEFORE that deletion — per assigned filename, prefer [stagedDir] (the
  /// just-finished job's stage dir — the exact transferred bytes, including
  /// any replacement overlay), falling back to the durable box_images copy
  /// (covers files skipped this batch as already-uploaded on an earlier
  /// retry). Best-effort per file and as a whole: a thumbnail failure must
  /// never block the transfer result.
  Future<void> persistBoxThumbnails(
    CaptureBox box, {
    Directory? stagedDir,
  }) async {
    try {
      final assignments = await _db.getAssignmentsForBox(
        deviceId: deviceId,
        boxId: box.id,
      );
      if (assignments.isEmpty) return;
      final thumbsDir = await ThumbnailService.boxThumbsDir(deviceId, box.id);
      final localStore = await _boxImagesDir(box.id);
      for (final name in assignments.keys) {
        try {
          File? source;
          if (stagedDir != null) {
            final staged = File(p.join(stagedDir.path, name));
            if (await staged.exists()) source = staged;
          }
          source ??= File(p.join(localStore.path, name));
          if (!await source.exists()) continue;
          final bytes = await ThumbnailService.buildPngThumbnail(source);
          if (bytes == null) continue;
          await File(p.join(thumbsDir.path, '$name.png')).writeAsBytes(bytes);
        } catch (e) {
          print('⚠️ Thumbnail persist skipped for $name: $e');
        }
      }
    } catch (e) {
      print('⚠️ persistBoxThumbnails failed for box ${box.id}: $e');
    }
  }

  /// Marks the box transferred (call ONLY on a full-success batch result) and
  /// deletes its durable local image store — the copies exist only to spare
  /// re-pulling; once transferred and verified they are redundant.
  Future<void> markTransferred(CaptureBox box) async {
    // Markers go into the destination day dir fixed on the box's first
    // transfer attempt (capture_boxes.transferred_to); the configured root is
    // only the fallback for boxes copied by an older build.
    final legacyRoot = Get.isRegistered<SettingsController>()
        ? Get.find<SettingsController>().destinationPath.value.trim()
        : '';

    // LWIP's marker is its readiness gate. It must exist in every landed
    // folder before the cloud/local box status becomes TRANSFERRED, otherwise
    // a marker failure makes the box permanently read-only while LWIP never
    // sees the folder.
    final markers = await writeBoxProcessingMarkers(
      db: _db,
      deviceId: deviceId,
      boxId: box.id,
      legacyRoot: legacyRoot,
    );
    if (!markers.isSuccess) {
      throw StateError(
        'Processing markers were not completed for "${box.boxDetails}": '
        '${markers.summary}. Retry the transfer after fixing the destination.',
      );
    }

    await _db.markCaptureBoxTransferred(deviceId: deviceId, boxId: box.id);

    try {
      final dir = await _boxImagesDir(box.id);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      print('ℹ️ Could not delete local box store for box ${box.id}: $e');
    }
    await loadBoxes();
    await _auditOrNull?.log(
      AuditActions.boxTransferred,
      details: {'box': box.boxDetails},
    );
  }
}
