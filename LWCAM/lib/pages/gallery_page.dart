// The capture screen of LWCAM (first stage of the pipeline: capture app ->
// LWIP -> QC -> Upload). It mirrors the phone with scrcpy, pulls new photos
// over ADB into a thumbnail grid, and sends the selected ones to the transfer
// queue. Three modes share the file: the legacy gallery (metadata keying off),
// box mode (Capture view and QC view of the active box and folders), and
// rework mode (re-photographing pages QC rejected, entered from the box list).
// Things to know before editing: every box-mode and rework-mode path is
// guarded by _isBoxMode / _reworkMode, so keying-off behaviour must stay
// untouched; and the phone's DCIM folder is the source of truth for captures,
// with live sync polling it for new files.
// ignore_for_file: avoid_print, unnecessary_brace_in_string_interps, unused_local_variable, non_constant_identifier_names

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:get/get.dart';
import 'package:lwcam/controllers/transfer_controller.dart';
import 'package:lwcam/auth/auth_controller.dart';
import 'package:lwcam/db/upload_stats_db.dart';
import 'package:lwcam/services/transfer_destination_service.dart';
import 'package:window_manager/window_manager.dart';
import '../controllers/box_session_controller.dart';
import '../controllers/gallery_controller.dart';
import '../models/node_config.dart';
import '../services/adb_device_service.dart'
    show AdbDeviceService, ShutterConfig;
import '../services/audit_log_service.dart';
import '../services/box_integrity.dart' show localImageNameForCloudImage;
import '../services/node_config_service.dart';
import '../services/open_rework_cache.dart';
import '../services/processing_marker_service.dart' show setReworkInProgress, updateReworkColorBinding, ensureReworkCaptureMarker;
import '../services/color_capture_session.dart';
import '../services/color_rework_store.dart';
import '../services/pg_statements.dart' as st;
import '../services/fs_probe.dart' show FsProbe;
import '../services/rework_service.dart'
    show ReworkInput, ReworkItem, ReworkService;
import '../services/scrcpy_service.dart';
import '../services/thumbnail_service.dart';
import '../services/shutter_hotkey_service.dart';
import '../services/snackbar_service.dart';
import '../theme/app_colors.dart';
import '../services/transfer_queue_service.dart';
import '../widgets/enlarged_image_dialog.dart';
import '../widgets/transfer_queue_banner.dart';
import '../models/capture_box_models.dart';
import 'box_transfer_flow.dart';
import 'folder_metadata_form_page.dart';
import 'settings_page.dart';
import 'uploader_page.dart';
import 'package:path/path.dart' as p;

/// Decode cap (pixels wide) for full-image inspection viewers. The source
/// photos are ~50MP (~200MB decoded RGBA); capping at 2560 keeps zoom-to-read
/// text sharp at roughly 1/8 the decode/memory cost. Raise if operators need
/// deeper zoom detail.
const int kPreviewCacheWidth = 2560;

/// LEGACY (keying-OFF) gallery only: fixed width of the right-hand grid pane
/// (viewer fills the rest) and the min content width below which it stacks.
const double kGridPaneWidth = 480;
const double kSideBySideMinWidth = 760;

// ── Box-mode Capture/QC view layout (all proportional to the window) ───────
/// Fixed grid columns in box mode (both Capture and QC views); tiles scale
/// with the available width.
const int kBoxGridColumns = 4;

/// Tile shape for image grids, matching what the camera actually produces:
/// 6144x8192, i.e. 3:4 portrait.
///
/// Square tiles cropped or letterboxed every capture and made documents look
/// squashed next to the live preview. Tiles shaped like the photograph show the
/// whole page at its true proportions, which is what an operator is checking
/// for when they glance at the grid.
const double kCaptureAspectRatio = 3 / 4;

/// Box-mode mirror pane sizing. The pane width is ASPECT-FIT: derived from
/// the cropped stream's aspect ratio × the pane height, so the video fills it
/// exactly (no side letterboxing, no oversized native window — big native
/// child windows cost real iGPU composition). These bound the fit:
/// the fallback is used until the aspect is known (mirror still starting),
/// and the max keeps ultra-wide setups from letting the mirror eat the grid.
const double kBoxMirrorFallbackWidthFraction = 0.30;
const double kBoxMirrorMaxWidthFraction = 0.45;

/// QC view: Image Viewer width as a fraction of the RIGHT region (the area
/// beside the mirror). Grid gets the rest → mirror | viewer | grid.
const double kQcViewerWidthFraction = 0.42;

/// Cap on how long the image pull waits for the mirror to finish starting
/// (see the `ensureStarted` call in initState). `ensureStarted` itself can
/// take much longer (up to 3 retries × a 15s window-wait) — this cap lets
/// the grid start populating even if the mirror is still struggling; the
/// mirror pane's own self-heal (auto-retry every 10s) recovers it afterward.
const Duration kMirrorWaitBeforePullCap = Duration(seconds: 1);

/// Expedited detection burst fired right after the app triggers the shutter
/// (box mode): polls this often, up to this many times, instead of waiting
/// for the idle 2s live-sync tick — cuts perceived shutter→grid latency.
/// Stops early once a capture is actually synced.
const Duration kExpeditedSyncInterval = Duration(milliseconds: 350);
const int kExpeditedSyncIterations = 12; // ~4.2s worst case

/// Replacing a rework image retries this many times, this far apart (~6s total)
/// before giving up — see _overwriteReworkFileAtomically. Long enough to outlast
/// an antivirus scan of a ~16MB JPEG or one LWIP read pass over the folder,
/// short enough that a genuinely stuck file still reports promptly.
const int kReworkRenameAttempts = 12;
const Duration kReworkRenameRetryDelay = Duration(milliseconds: 500);

/// Size-stability gate before pulling a newly detected file: the device
/// size is read twice this far apart and must match (and be non-zero)
/// before a pull is attempted, so a fast expedited poll can't grab a JPEG
/// the camera app is still writing. Bounded so a size that never settles
/// (e.g. `ls -l` unsupported) falls through to a normal pull instead of
/// blocking indefinitely.
const Duration kSizeStabilityPollInterval = Duration(milliseconds: 250);
const Duration kSizeStabilityMaxWait = Duration(milliseconds: 1200);

class _TransferSelectionSnapshot {
  final List<String> orderedOriginalNames;
  final String label;

  const _TransferSelectionSnapshot({
    required this.orderedOriginalNames,
    required this.label,
  });
}

class _ReplacementRecordInfo {
  final String originalFilename;
  final String replacementFilename;
  final String? replacementLocalPath;

  /// 'recapture' keeps the erroneous original on the device and overlays the
  /// replacement in the app; 'recapture-swap' means the capture was renamed
  /// over the original on the device, which now holds only the corrected
  /// image.
  final String replacementType;

  const _ReplacementRecordInfo({
    required this.originalFilename,
    required this.replacementFilename,
    required this.replacementLocalPath,
    this.replacementType = 'recapture',
  });

  bool get isSwap => replacementType == 'recapture-swap';
}

// ── Rework helpers (pure, top-level so they are testable without a widget,
// ADB or a database — this page itself is not unit-testable) ────────────────

/// QC's open requests grouped by the folder they belong to.
///
/// Keyed by folder_seq, NOT by filename: BoxSessionController.assignments is
/// keyed by the DEVICE filename, while rework_logs -> capture_images.image_name
/// and the files in LWIP's input folder carry the FINAL transferred name (see
/// reportCaptureImageTransferName). Matching on names would silently find
/// nothing.
Map<int, List<ReworkItem>> groupReworkByFolderSeq(Iterable<ReworkItem> items) {
  final grouped = <int, List<ReworkItem>>{};
  for (final item in items) {
    (grouped[item.folderSeq] ??= []).add(item);
  }
  return grouped;
}

/// The folders to render in rework mode: the box's LOCAL folders that have open
/// requests (in the box's own order), followed by PLACEHOLDERS for request
/// folders this station has no local row for.
///
/// The placeholders exist for SEPARATION CHILDREN: QC splits a folder and mints
/// the child rows directly in PG, so they never sync back into LWCAM's local
/// capture_folders. Everything rework actually needs travels in the worklist
/// items themselves (folder_seq, folder_name, folder_path, cloud metadata), so
/// a synthesized CaptureFolder carries them. Its id stays 0 — the "not a local
/// row" marker — and the metadata save skips the local write for those.
List<CaptureFolder> reworkFoldersFor(
  List<CaptureFolder> localFolders,
  Map<int, List<ReworkItem>> byFolderSeq, {
  required int boxId,
}) {
  final result = localFolders
      .where((f) => byFolderSeq.containsKey(f.folderSeq))
      .toList();
  final localSeqs = result.map((f) => f.folderSeq).toSet();
  final missing = byFolderSeq.keys.where((s) => !localSeqs.contains(s)).toList()
    ..sort();
  for (final seq in missing) {
    final name = byFolderSeq[seq]!.first.folderName.trim();
    result.add(
      CaptureFolder(
        boxId: boxId,
        folderSeq: seq,
        folderName: name.isEmpty ? null : name,
      ),
    );
  }
  return result;
}

/// How one submit settles a request: 'Recapture' when a replacement photo is
/// staged for it, 'Metadata' when the operator marked it fixed by a metadata
/// correction, null when this submit leaves it open.
///
/// A staged recapture always wins — it is the stronger claim, and it is what
/// actually changes the folder's fingerprint.
String? reworkResolutionFor(
  String imageName, {
  required Set<String> staged,
  required Set<String> metadataFixed,
}) {
  if (staged.contains(imageName)) return 'Recapture';
  if (metadataFixed.contains(imageName)) return 'Metadata';
  return null;
}

/// The source file a submit may write for [imageName].
///
/// Only a page staged in THIS session has one. A metadata-only item must never
/// consult a durable intent left behind by an Undo, a box switch or a restart:
/// doing so used to overwrite the page with a photo the operator had abandoned.
/// A staged page still verifies that its durable intent is the same generation.
Future<File?> reworkSourceForItem({
  required File? staged,
  required Future<File?> Function() pending,
}) async {
  if (staged == null) return null;
  final durable = await pending();
  if (durable == null || !p.equals(durable.path, staged.path)) {
    throw StateError('Recapture staging is damaged; retake this page');
  }
  return durable;
}

/// Image names whose closure is already in the local outbox, so a page whose
/// request was submitted before a crash or a partial failure is not offered
/// for a second write. [pendingClosureKeys] uses the outbox entity key
/// `<project>|<box>|<folderSeq>|<image>`.
Set<String> closedReworkImages(
  List<ReworkItem> items,
  Set<String> pendingClosureKeys,
) => {
  for (final item in items)
    if (pendingClosureKeys.contains(
      '${item.projectKey}|${item.boxName}|${item.folderSeq}|${item.imageName}',
    ))
      item.imageName,
};

/// How many OPEN rework items remain unresolved (neither a staged recapture
/// nor a metadata fix, and not already closed).
///
/// LWIP flips a folder's qc_status to PENDING on ANY file change, regardless
/// of how many of the folder's other rejected pages are still bad — so
/// Submit must stay disabled until every item is settled. A partial recapture
/// (2 of 5 rejected pages) would otherwise send the folder back to QC with
/// the other 3 still bad. A page already closed in a partial submit must not
/// be re-counted just because it is still in the page's worklist.
int reworkOpenItemCount(
  List<ReworkItem> items, {
  required Set<String> staged,
  required Set<String> metadataFixed,
  Set<String> closed = const {},
}) => items
    .where((item) =>
        !closed.contains(item.imageName) &&
        reworkResolutionFor(
          item.imageName,
          staged: staged,
          metadataFixed: metadataFixed,
        ) ==
        null)
    .length;

/// Whether a folder's submit should reset qc_status to PENDING itself.
///
/// Only when the folder settled something and NOTHING in it was recaptured: a
/// metadata-only fix changes no file, so the folder's input fingerprint is
/// identical, LWIP will never reprocess it, and nothing else would move it off
/// REWORK. With a recapture the reset belongs to LWIP's report — doing it here
/// too would let QC claim the folder before its new output was verified.
bool reworkShouldResetQcStatus({
  required int closedInFolder,
  required int recapturedInFolder,
}) => closedInFolder > 0 && recapturedInFolder == 0;

/// True when an `adb shell ls -1 <dcim>` result proves the phone ANSWERED, as
/// opposed to not being reachable at all.
///
/// The distinction cannot be read off stdout: an unreachable device and an
/// empty DCIM both return nothing there. It decides whether the live-sync
/// baseline is seeded, and both mistakes are damaging - see
/// `_deviceBaselineSeeded`. adb forwards the remote exit status, so exit 0
/// means the shell ran; "No such file" means it ran but that path is not the
/// camera folder, which the caller retries against the next candidate.
bool deviceAnsweredListing({required int exitCode, required String stdout}) =>
    exitCode == 0 && !stdout.contains('No such file');

class GalleryPage extends StatefulWidget {
  const GalleryPage({super.key});

  @override
  State<GalleryPage> createState() => _GalleryPageState();
}

class _GalleryPageState extends State<GalleryPage> with WidgetsBindingObserver {
  final GalleryController c = Get.put(GalleryController(), permanent: true);
  final SettingsController s = Get.put(SettingsController(), permanent: true);
  final TransferController u = Get.put(TransferController(), permanent: true);
  final AuthController auth = Get.find<AuthController>();

  AuditLogService? get _auditOrNull =>
      Get.isRegistered<AuditLogService>() ? Get.find<AuditLogService>() : null;

  // Box→Folders workflow (metadata keying ON): the BoxSessionController is
  // registered only by the box-list page, so its presence + an active box IS
  // the box-mode signal. Every box-mode behavior in this file is guarded by
  // _isBoxMode — with keying OFF none of it executes.
  BoxSessionController? get _boxSession =>
      Get.isRegistered<BoxSessionController>()
      ? Get.find<BoxSessionController>()
      : null;
  bool get _isBoxMode => _boxSession?.activeBox.value != null;

  /// Box mode only: false = Capture view (mirror band + grid, no viewer),
  /// true = QC view (mirror band + viewer | grid, the pre-transfer review).
  bool _qcMode = false;

  // ── REWORK MODE ───────────────────────────────────────────────────────────
  //
  // A third mode, entered ONLY from the box list's "Rework" button (see
  // BoxSessionController.startInReworkWith, read and cleared in initState).
  // The box is already TRANSFERRED and is never reopened for capture: the grid
  // shows the images QC rejected, sourced from LWIP's INPUT folder rather than
  // the phone (the phone's copies are deleted at transfer), and a recapture
  // replaces one of those files so LWIP reprocesses the folder.
  //
  // Everything here is additive and guarded by [_reworkMode]. The ONE change to
  // an existing hot path is the early return in _startLiveSync — see the
  // comment there; it is what stops a stray shutter press appending an
  // untracked image to a folder QC has already indexed.

  /// QC's open requests for this box, or empty when this is a normal session.
  List<ReworkItem> _reworkItems = const [];

  bool get _reworkMode => _reworkItems.isNotEmpty;

  // Staged recaptures and the "fixed by metadata" marks live on the SESSION
  // CONTROLLER, not on this State. This page is disposed the moment the operator
  // steps back to the box list, and re-photographing is the expensive part of
  // rework: keeping them here meant three recaptures were silently thrown away
  // by a there-and-back navigation (reported 2026-07-30). The controller clears
  // them on a successful submit and when a different box is opened.
  Map<String, File> get _reworkStaged => _boxSession!.reworkStaged;

  Set<String> get _reworkMetadataFixed => _boxSession!.reworkMetadataFixed;

  Directory? get _reworkStagingDir => _boxSession!.reworkStagingDir;
  set _reworkStagingDir(Directory? dir) => _boxSession!.reworkStagingDir = dir;

  /// folder_seq → the operator's edited draft, held until submit. Seeded from
  /// the CLOUD row (QC edits the same columns), never from the local one.
  /// Page-local on purpose: Edit Metadata persists on its own Save, so nothing
  /// is lost when this page goes away — only the "metadata saved" chip.
  final Map<int, CaptureFolder> _reworkEdited = {};

  /// The station's processing roots, needed to map a folder's output path back
  /// to the input file a recapture must replace.
  NodeConfig? _reworkConfig;

  /// The rework image whose name + QC reason the status header is showing.
  String? _reworkFocusedImage;

  bool _reworkSubmitting = false;

  /// Pages whose Undo is discarding a durable intent; the tile's buttons stay
  /// disabled until the operation finishes so a double tap cannot race it.
  final Set<String> _reworkUndoing = {};

  /// Bumped whenever a rework photo is staged, and mixed into the tile image
  /// keys so re-recapturing the same slot repaints. Needed because a repeat
  /// recapture reuses the staged file's PATH with new bytes, which is exactly
  /// what Flutter's image cache keys on. A counter rather than the file length
  /// so `build` does no synchronous IO.
  int _reworkStageEpoch = 0;

  /// Active shutter hotkey label (box mode) — shown as a header chip.
  String _shutterKeybind = '';

  final FocusNode _viewerFocusNode = FocusNode(
    debugLabel: 'gallery_viewer_focus',
    skipTraversal: true,
  );

  late final ScrollController _galleryScrollController = ScrollController();

  final Map<String, GlobalKey> _captureTileKeys = {};
  GlobalKey _captureTileKey(String imageName) =>
      _captureTileKeys.putIfAbsent(imageName, () => GlobalKey());

  final Map<String, GlobalKey> _reworkTileKeys = {};
  GlobalKey _reworkTileKey(String imageName) =>
      _reworkTileKeys.putIfAbsent(imageName, () => GlobalKey());

  /// Scroll targets for folder cards. A GlobalKey rather than the ValueKey the
  /// card used to carry, because Scrollable.ensureVisible needs a
  /// BuildContext and only a GlobalKey exposes one. Still unique per folder,
  /// so widget identity across rebuilds is unchanged.
  final Map<int, GlobalKey> _folderCardKeys = {};
  GlobalKey _folderCardKey(int folderId) =>
      _folderCardKeys.putIfAbsent(folderId, () => GlobalKey());
  int _scrollRequest = 0;

  String deviceModel = '';
  String statusMsg = 'Connecting...';

  // Status-update throttling: during pull/live-sync bursts a status change
  // arrives per FILE, and every setState rebuilds this entire page. Coalesce
  // to at most one rebuild per 200ms with a trailing flush so the final text
  // always lands.
  DateTime _lastStatusRebuild = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _statusFlushTimer;

  // Preview-panel existence cache: the panel rebuilds on every page setState,
  // and it used to existsSync() the preview file each time. Stat once per path.
  String? _previewStatPath;
  bool _previewStatExists = false;

  bool _previewExists(File file) {
    if (_previewStatPath != file.path) {
      _previewStatPath = file.path;
      try {
        _previewStatExists = file.existsSync();
      } catch (_) {
        _previewStatExists = false;
      }
    }
    return _previewStatExists;
  }

  void _setStatus(String msg, {bool force = false}) {
    statusMsg = msg; // always keep the latest text, even when skipping
    if (!mounted) return;
    final now = DateTime.now();
    if (force || now.difference(_lastStatusRebuild).inMilliseconds >= 200) {
      _lastStatusRebuild = now;
      _statusFlushTimer?.cancel();
      _statusFlushTimer = null;
      setState(() {});
    } else {
      _statusFlushTimer ??= Timer(const Duration(milliseconds: 250), () {
        _statusFlushTimer = null;
        _lastStatusRebuild = DateTime.now();
        if (mounted) setState(() {});
      });
    }
  }

  late final String adbPath = _resolveAdbPath();
  Directory? _tempDir;
  Directory? _transferTempDir;
  Timer? _liveSyncTimer;
  bool _cleanedUp = false;
  bool _isPulling = false;
  bool _isSyncingNewCaptures = false;
  bool _isWaitingForRecapture = false;

  /// Set by [_cancelRecapture] so the in-flight wait loop stops instead of
  /// running to its 2-minute timeout, and so the "no new photo" messages -
  /// which describe a FAILURE - are not shown for a deliberate exit.
  bool _recaptureCancelled = false;
  bool _expeditedSyncActive = false;
  String? _recaptureSlotOriginalName;
  final Set<String> _knownDeviceFileNames = <String>{};

  /// False until a device listing has actually succeeded.
  ///
  /// Live sync must never ingest against a baseline that was never seeded. An
  /// unreachable device is indistinguishable from an empty folder on this
  /// page's inline adb listings (both yield an empty list), and an empty
  /// baseline makes the WHOLE camera roll look "new" - assignNewImage then
  /// claims every pre-existing photo, and every other folder's photos, into
  /// the folder being captured. Same bug the rework poller had; there it was
  /// fixed by distinguishing "unreachable" (null) from "no photos" ([]) in
  /// AdbDeviceService.listDeviceImageNames.
  bool _deviceBaselineSeeded = false;

  Future<Uint8List?> _buildThumbnailBytes(
    File file, {
    int targetWidth = 512,
    int? targetHeight,
  }) async {
    try {
      final bytes = await file.readAsBytes();
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      final frame = await codec.getNextFrame();
      final data = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      return data?.buffer.asUint8List();
    } catch (e) {
      print("⚠️ Thumbnail generation failed for ${p.basename(file.path)}: $e");
      return null;
    }
  }

  String _resolveAdbPath() => AdbDeviceService.resolveAdbPath();

  Future<bool> _ensureAdbAvailable() async {
    try {
      final result = await Process.run(adbPath, ['version']);
      final ok = result.exitCode == 0;
      if (!ok) {
        print("⚠️ adb version failed: ${result.stderr}");
      }
      return ok;
    } catch (e) {
      print("⚠️ adb availability check failed: $e");
      return false;
    }
  }

  /// date label -> total files on device for that date
  final Map<String, int> _dateTotals = {};

  /// date label -> ALL filenames on device for that date (not just thumbnails)
  final Map<String, List<String>> _allFileNamesByDate = {};

  /// DCIM working path used by ADB (e.g. /storage/emulated/0/DCIM/Camera)
  String? _workingPath;

  /// When true, any ongoing initial loading should be cancelled ASAP
  bool _cancelLoading = false;

  /// Global "all images" selection flag
  bool _globalFullSelection = false;

  /// If not null, indicates that one specific date is fully selected
  String? _fullDateKeySelection;

  /// True while we're preparing local files for a transfer (pulling from ADB)
  bool _preparingTransfer = false;

  /// original filename -> replacement local file
  final Map<String, File> _replacementFilesByOriginal = {};

  /// original filename -> replacement thumbnail
  final Map<String, Uint8List?> _replacementThumbsByOriginal = {};

  /// original filename -> replacement metadata restored from DB
  final Map<String, _ReplacementRecordInfo> _replacementInfoByOriginal = {};

  /// replacement filename -> original filename
  final Map<String, String> _originalNameByReplacement = {};

  /// original filename -> fixed sequence slot index
  final Map<String, int> _sequenceIndexByName = {};

  /// Esc leaves the recapture state.
  ///
  /// A raw keyboard handler rather than a Shortcuts/Focus wrapper because the
  /// recapture banner owns no focus of its own - the operator's last click was
  /// on a grid tile, and the mirror pane is a native child window that takes
  /// focus away entirely. A handler sees the key wherever it lands.
  ///
  /// Scoped by [_isWaitingForRecapture], so Esc is inert at every other moment
  /// and never swallows the key from a dialog or a text field.
  bool _handleEscapeKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;
    if (!_isWaitingForRecapture) return false;
    _cancelRecapture();
    return true; // handled - do not let it also pop a route
  }

  // --- Lifecycle: init, dispose, temp cleanup ------------------------------

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_handleEscapeKey);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _viewerFocusNode.requestFocus();
      }
    });

    // Box mode may request opening straight into the QC review view (box-list
    // Transfer button). One-shot signal — read and clear it.
    if (_isBoxMode && (_boxSession?.startInQcView ?? false)) {
      _qcMode = true;
    }
    _boxSession?.startInQcView = false;

    // Same one-shot contract for REWORK mode (box-list "Rework" button). Read
    // and clear, so a later normal open of this page can never inherit it.
    if (_isBoxMode) {
      _reworkItems = List.of(_boxSession?.startInReworkWith ?? const []);
    }
    _boxSession?.startInReworkWith = const [];
    if (_reworkMode) {
      // Rework never uses the pre-transfer review view: the box is already
      // transferred and there is nothing here to transfer.
      _qcMode = false;
    }

    final galleryScope = _isBoxMode
        ? '${_reworkMode ? 'rework' : 'box'}:${auth.deviceId.value}:${_boxSession!.activeBox.value!.id}'
        : 'device:${auth.deviceId.value}';
    if (c.galleryScope != galleryScope) {
      c.galleryScope = galleryScope;
      c.groupedImages.clear();
      c.selectedImages.clear();
      c.setPreview(null);
    }

    // Integrated phone mirror — started BEFORE the image pull: the initial
    // load fires up to 8 concurrent `adb pull`s of ~13MB files, and scrcpy's
    // server push/tunnel setup loses that USB/adb contention and dies. When
    // already running (box-list revisits) ensureStarted returns immediately.
    // Explicit orientation both ways so a mode round-trip never inherits a
    // stale value. Never throws; worst case the gallery load starts a few
    // seconds later.
    //
    // The pull is capped to waiting at most kMirrorWaitBeforePullCap for the
    // mirror (ensureStarted itself can take much longer — up to 3 retries ×
    // a 15s window-wait) so a slow/struggling mirror never stalls the grid.
    // ensureStarted keeps running in the background regardless; if the pull
    // starting early knocks the mirror over, ScrcpyPane's self-heal
    // (auto-retry every 10s) brings it back once the pull burst settles.
    Future.any<void>([
      ScrcpyService.instance.ensureStarted(
        adbPath: adbPath,
        // Box mode crops the mirror to the camera-app region; legacy shows
        // the full phone screen as before.
        cropCaptureView: _isBoxMode,
      ),
      Future<void>.delayed(kMirrorWaitBeforePullCap),
    ]).whenComplete(() {
      if (!mounted) return;
      _initGallery();
      // Re-arm the shutter hotkey now the mirror is up.
      //
      // scrcpy's window is created as its own TOP-LEVEL window and only then
      // reparented into ours (ScrcpyService's SetParent). That transient
      // foreground change fires onWindowBlur, which unregisters the hotkey
      // moments after initState armed it - so on a fresh launch Space did
      // nothing. Leaving to the box list and coming back appeared to fix it
      // because ensureStarted then returns immediately, no window is created,
      // and nothing blurs.
      unawaited(_rearmShutterAfterMirror());
    });

    // Box mode: the phone shutter is cropped out of the mirror, so arm the
    // global hotkey that fires it over ADB (config from the shared users
    // store; disarmed in dispose). Legacy mirror is uncropped — no hotkey.
    //
    // NOT in rework mode: the hotkey is global, and a photo taken outside a
    // recapture has nowhere to go on a transferred box. There, starting a
    // recapture on a specific rejected image is what arms it (see
    // _startReworkRecaptureForSlot) — a dead key is better than a photo that
    // silently goes nowhere.
    if (_isBoxMode && !_reworkMode) _armShutterHotkey();
  }

  /// Re-registers the hotkey after the mirror has finished starting.
  ///
  /// Only when we are the foreground window: registering while another app is
  /// in front would steal the key from it, and that case is already handled -
  /// the service stays armed, so its onWindowFocus listener registers as soon
  /// as the operator comes back.
  Future<void> _rearmShutterAfterMirror() async {
    if (!mounted || !_isBoxMode || _reworkMode) return;
    if (!await windowManager.isFocused()) return;
    await _armShutterHotkey();
  }

  Future<void> _armShutterHotkey() async {
    final store = auth.usersStore;
    if (store == null) return;
    _shutterKeybind = store.shutterKeybind;
    await ShutterHotkeyService.instance.arm(
      keybind: _shutterKeybind,
      onTrigger: () async {
        await AdbDeviceService(adbPath: adbPath).triggerShutter(
          ShutterConfig(
            method: store.shutterMethod,
            tapXPercent: store.shutterTapXPercent,
            tapYPercent: store.shutterTapYPercent,
          ),
        );
        // Fires the moment the shutter is confirmed instead of waiting for
        // the idle 2s live-sync tick — see kExpeditedSyncInterval.
        unawaited(_kickExpeditedSync());
      },
    );
    if (mounted) setState(() {}); // show the keybind chip
  }

  /// After the app fires the shutter, polls faster than the idle
  /// `_liveSyncTimer` to cut perceived shutter→grid latency. Bounded
  /// (~4s) and re-entrancy guarded so rapid-fire shutters don't stack
  /// concurrent bursts; stops as soon as a capture is actually synced —
  /// the idle 2s poll takes over from there. Composes with (does not
  /// replace) `_startLiveSync`'s periodic timer.
  Future<void> _kickExpeditedSync() async {
    if (_expeditedSyncActive) return;
    _expeditedSyncActive = true;
    try {
      for (var i = 0; i < kExpeditedSyncIterations; i++) {
        if (!mounted || _cleanedUp) return;
        final synced = await _syncNewDeviceImages(silent: true);
        if (synced) return;
        await Future<void>.delayed(kExpeditedSyncInterval);
      }
    } finally {
      _expeditedSyncActive = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_handleEscapeKey);
    ShutterHotkeyService.instance.disarm(); // no-op if never armed
    _liveSyncTimer?.cancel();
    _statusFlushTimer?.cancel();
    _viewerFocusNode.dispose();
    _galleryScrollController.dispose();
    // Deliberately NOT _cleanupTempFiles(): the gallery cache must survive
    // page disposal (mode switch, box list navigation) so re-entering skips
    // the full device re-pull. Full cleanup still happens on logout
    // (_teardownGallery) and app close (didChangeAppLifecycleState). Only the
    // per-batch transfer staging dir dies with the page.
    _cleanupTransferStagingDir();
    super.dispose();
  }

  Future<void> _cleanupTransferStagingDir() async {
    final dir = _transferTempDir;
    _transferTempDir = null;
    if (dir != null && dir.existsSync()) {
      try {
        await dir.delete(recursive: true);
        print("✅ Transfer staging temp directory deleted: ${dir.path}");
      } catch (e) {
        print("⚠️ Failed cleaning transfer staging dir ${dir.path}: $e");
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      print("🧹 App is closing — cleaning temp files...");
      _cleanupTempFiles();
    }
  }

  Future<void> _cleanupTempFiles() async {
    if (_cleanedUp) return;
    _cleanedUp = true;
    _liveSyncTimer?.cancel();

    if (_isPulling) {
      print("⏳ Waiting briefly for ADB to finish before cleanup...");
      await Future.delayed(const Duration(seconds: 3));
    }

    try {
      PaintingBinding.instance.imageCache.clear();
      PaintingBinding.instance.imageCache.clearLiveImages();
      await Future.delayed(const Duration(milliseconds: 500));

      Future<void> deleteDir(Directory? dir, String label) async {
        if (dir == null || !dir.existsSync()) return;
        try {
          await dir.delete(recursive: true);
          print("✅ $label temp directory deleted: ${dir.path}");
        } catch (e) {
          print("⚠️ Failed cleaning $label temp directory ${dir.path}: $e");
        }
      }

      await deleteDir(_tempDir, 'Gallery cache');
      await deleteDir(_transferTempDir, 'Transfer staging');
      // Rework staging is deliberately NOT deleted here. It is owned by the
      // session controller and must survive this page being disposed — stepping
      // back to the box list used to discard recaptured photos the operator then
      // had to shoot again. BoxSessionController.clearReworkStaging() removes it
      // on a successful submit or when a different box is opened.

      final sysTemp = Directory.systemTemp;
      for (final entity in sysTemp.listSync()) {
        if (entity is Directory &&
            (entity.path.contains('dcim_cache_gallery') ||
                // NOT lwcam_rework_: the session controller owns those and they
                // must outlive this page (see BoxSessionController.reworkStaged)
                // — sweeping them here would delete the operator's staged
                // recaptures the moment they stepped back to the box list, which
                // is the bug this whole arrangement exists to prevent. They are
                // removed by clearReworkStaging(), and any orphan is a few MB in
                // the OS temp dir that Windows reclaims on its own.
                entity.path.contains('dcim_transfer_stage'))) {
          try {
            await entity.delete(recursive: true);
            print("🧹 Cleaned old temp: ${entity.path}");
          } catch (e) {
            print("⚠️ Failed to delete old temp ${entity.path}: $e");
          }
        }
      }
    } catch (e) {
      print("⚠️ Cleanup outer failed: $e");
    } finally {
      _tempDir = null;
      _transferTempDir = null;
    }
  }

  void _scrollOnceTo(
    GlobalKey key, {
    bool fallbackToEnd = false,
    double? fallbackOffset,
  }) {
    final request = ++_scrollRequest;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || request != _scrollRequest) return;
      final tileContext = key.currentContext;
      if (tileContext != null) {
        await Scrollable.ensureVisible(
          tileContext,
          alignment: 0.5,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
        return;
      }
      if (!_galleryScrollController.hasClients ||
          (!fallbackToEnd && fallbackOffset == null)) {
        return;
      }
      final position = _galleryScrollController.position;
      final target = fallbackToEnd
          ? position.maxScrollExtent
          : fallbackOffset!.clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            );
      await _galleryScrollController.animateTo(
        target.toDouble(),
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
      if (!mounted || request != _scrollRequest) return;
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || request != _scrollRequest) return;
      final revealedContext = key.currentContext;
      if (revealedContext == null || !revealedContext.mounted) return;
      await Scrollable.ensureVisible(
        revealedContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    });
  }

  // --- Device image listing and live sync ----------------------------------

  Future<void> _initGallery() async {
    setState(() => statusMsg = 'Detecting device...');

    final adbReady = await _ensureAdbAvailable();
    if (!adbReady) {
      if (!mounted) return;
      setState(() {
        deviceModel = 'ADB Not Found';
        statusMsg =
            'ADB executable not found. Put adb.exe next to the app, in the project root, or in PATH.';
      });
      return;
    }

    await _getDeviceModelViaAdb();
    // Rework mode reads its images from LWIP's input folder, not the phone —
    // after a transfer the phone has no copy of them at all.
    if (_reworkMode) {
      await _loadReworkImages();
    } else {
      await loadDcimImages();
    }
    _startLiveSync();
  }

  Future<void> _getDeviceModelViaAdb() async {
    try {
      final result = await Process.run(adbPath, [
        'shell',
        'getprop',
        'ro.product.model',
      ]);
      setState(() {
        deviceModel = result.stdout.toString().trim();
      });
      print("📱 Device model detected via ADB: $deviceModel");
    } catch (e) {
      setState(() {
        deviceModel = 'Unknown Device';
      });
      print("⚠️ Failed to detect device model via ADB: $e");
    }
  }

  String _monthName(int m) {
    const months = [
      "Jan",
      "Feb",
      "Mar",
      "Apr",
      "May",
      "Jun",
      "Jul",
      "Aug",
      "Sep",
      "Oct",
      "Nov",
      "Dec",
    ];
    return months[m - 1];
  }

  String _dateKeyFromFilename(String name) {
    final reg = RegExp(r'(\d{8})_(\d{6})');
    final match = reg.firstMatch(name);
    if (match == null) return 'Unknown';

    final datePart = match.group(1)!;
    final year = int.parse(datePart.substring(0, 4));
    final month = int.parse(datePart.substring(4, 6));
    final day = int.parse(datePart.substring(6, 8));

    return "$day ${_monthName(month)} $year";
  }

  DateTime _parseDateKey(String dateKey) {
    if (dateKey == 'Unknown') return DateTime(1900);

    final parts = dateKey.split(' ');
    if (parts.length != 3) return DateTime(1900);

    final day = int.tryParse(parts[0]) ?? 1;
    final monthName = parts[1];
    final year = int.tryParse(parts[2]) ?? 1900;

    const monthNames = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];

    final rawIndex = monthNames.indexOf(monthName);
    if (rawIndex == -1) return DateTime(1900);

    final monthIndex = rawIndex >= 12 ? rawIndex - 12 : rawIndex;
    return DateTime(year, monthIndex + 1, day);
  }

  int _getTotalDeviceImageCount() {
    if (_dateTotals.isEmpty) {
      return c.groupedImages.values.fold<int>(
        0,
        (sum, group) => sum + group.length,
      );
    }
    return _dateTotals.values.fold(0, (a, b) => a + b);
  }

  String _canonicalTransferName(String name) {
    return _originalNameByReplacement[name] ?? name;
  }

  List<String> _dedupeTransferableNames(Iterable<String> names) {
    final ordered = <String>[];
    final seen = <String>{};

    for (final rawName in names) {
      final canonicalName = _canonicalTransferName(rawName.trim());
      if (canonicalName.isEmpty) {
        continue;
      }
      if (seen.add(canonicalName)) {
        ordered.add(canonicalName);
      }
    }

    return ordered;
  }

  List<String> _getOrderedTransferSequenceNames() {
    return _dedupeTransferableNames(_getOrderedSequenceNames());
  }

  int _getSelectedCount() {
    if (_globalFullSelection) {
      return _getOrderedTransferSequenceNames().length;
    }

    if (_fullDateKeySelection != null) {
      return _dedupeTransferableNames(
        _allFileNamesByDate[_fullDateKeySelection!] ?? const <String>[],
      ).length;
    }

    return _dedupeTransferableNames(
      c.selectedImages.map((file) => p.basename(file.path)),
    ).length;
  }

  Future<Directory> _ensureGalleryCacheDir() async {
    if (_tempDir != null && _tempDir!.existsSync()) {
      return _tempDir!;
    }
    // Deliberately a STABLE path (not createTemp): the cache must survive
    // page disposal so switching modes / visiting the box list doesn't force
    // a full re-pull — loadDcimImages reuses files already present here. It
    // is deleted on logout, app close, and by the dcim_cache_gallery sweep
    // in _cleanupTempFiles.
    final safeDevice = auth.deviceId.value.trim().replaceAll(
      RegExp(r'[^\w-]'),
      '_',
    );
    _tempDir = Directory(
      p.join(Directory.systemTemp.path, 'dcim_cache_gallery_$safeDevice'),
    );
    if (!_tempDir!.existsSync()) {
      _tempDir!.createSync(recursive: true);
    }
    print("📂 Using gallery cache dir: ${_tempDir!.path}");
    return _tempDir!;
  }

  Future<Directory> _prepareFreshTransferStageDir() async {
    if (_transferTempDir != null && _transferTempDir!.existsSync()) {
      try {
        await _transferTempDir!.delete(recursive: true);
      } catch (e) {
        print('⚠️ Failed resetting transfer staging dir: $e');
      }
    }
    _transferTempDir = await Directory.systemTemp.createTemp(
      'dcim_transfer_stage',
    );
    print("📂 Using transfer staging dir: ${_transferTempDir!.path}");
    return _transferTempDir!;
  }

  /// [reindex] false lets a bulk loop register many names and rebuild the
  /// (O(total)) sequence index ONCE afterwards instead of once per file.
  void _registerDeviceFileName(String name, {bool reindex = true}) {
    if (!_knownDeviceFileNames.add(name)) {
      return;
    }

    final key = _dateKeyFromFilename(name);
    final namesForDate = _allFileNamesByDate.putIfAbsent(key, () => <String>[]);
    if (!namesForDate.contains(name)) {
      namesForDate.add(name);
      namesForDate.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    }
    _dateTotals[key] = namesForDate.length;
    if (reindex) _rebuildSequenceIndexes();
  }

  void _unregisterDeviceFileName(String name, {bool reindex = true}) {
    _knownDeviceFileNames.remove(name);

    // Box mode: a deleted device photo loses its folder assignment.
    if (_isBoxMode) unawaited(_boxSession!.unassignImage(name));

    final key = _dateKeyFromFilename(name);
    final namesForDate = _allFileNamesByDate[key];
    if (namesForDate != null) {
      namesForDate.remove(name);
      if (namesForDate.isEmpty) {
        _allFileNamesByDate.remove(key);
        _dateTotals.remove(key);
      } else {
        _dateTotals[key] = namesForDate.length;
      }
    }

    if (reindex) _rebuildSequenceIndexes();
  }

  void _rebuildSequenceIndexes() {
    final sortedDateKeys = _allFileNamesByDate.keys.toList()
      ..sort((a, b) => _parseDateKey(a).compareTo(_parseDateKey(b)));

    final sortedFileNamesByDate = <String, List<String>>{};
    for (final key in sortedDateKeys) {
      final fileList = [...(_allFileNamesByDate[key] ?? const <String>[])];
      fileList.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      sortedFileNamesByDate[key] = fileList;
      _dateTotals[key] = fileList.length;
    }

    _allFileNamesByDate
      ..clear()
      ..addAll(sortedFileNamesByDate);

    _sequenceIndexByName.clear();
    int sequenceIndex = 0;
    for (final entry in _allFileNamesByDate.entries) {
      for (final name in entry.value) {
        _sequenceIndexByName[name] = sequenceIndex++;
      }
    }
  }

  void _startLiveSync() {
    _liveSyncTimer?.cancel();
    _liveSyncTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      // REWORK MODE: the box is already transferred, so a photo ingested here
      // would be assignNewImage'd into a folder QC has already indexed and LWIP
      // has already processed — with no transfer to carry it and no input file,
      // it would simply never reach QC. So the live ingest is suppressed unless
      // a rework recapture is actually in flight, which makes
      // _startReworkRecaptureForSlot the only way a photo can enter the app in
      // this mode.
      //
      // The _isWaitingForRecapture allowance is nominal: _syncNewDeviceImages
      // itself returns immediately while a recapture is in flight (so a pending
      // recapture is never ingested as a standalone image), which means this
      // ingest path is effectively dead for the whole of rework mode. The
      // condition is written this way to state the intent rather than to rely on
      // that second guard staying where it is.
      if (_reworkMode && !_isWaitingForRecapture) return;
      unawaited(_syncNewDeviceImages(silent: true));
    });
  }

  /// Filename → size (bytes) from one `adb shell ls -l <_workingPath>`.
  /// Mirrors the parsing in AdbDeviceService.listDeviceImageSizes — gallery
  /// keeps its own inline adb calls / `_workingPath` rather than sharing
  /// that service's instance state. Null on failure; unparseable lines are
  /// simply omitted.
  Future<Map<String, int>?> _listDeviceImageSizes() async {
    if ((_workingPath ?? '').isEmpty) return null;
    try {
      final result = await Process.run(adbPath, [
        'shell',
        'ls',
        '-l',
        _workingPath!,
      ]);
      if (result.exitCode != 0) return null;
      final sizes = <String, int>{};
      for (final rawLine in result.stdout.toString().split('\n')) {
        final line = rawLine.trim().replaceAll('\r', '');
        if (line.isEmpty || line.startsWith('total')) continue;
        // toybox ls -l: perms links owner group SIZE date time NAME...
        final tokens = line.split(RegExp(r'\s+'));
        if (tokens.length < 8) continue;
        final size = int.tryParse(tokens[4]);
        if (size == null) continue;
        final name = tokens.sublist(7).join(' ');
        if (name.isNotEmpty) sizes[name] = size;
      }
      return sizes;
    } catch (e) {
      print('⚠️ Failed listing device image sizes: $e');
      return null;
    }
  }

  /// Waits until [name]'s device-side size is stable (unchanged, non-zero,
  /// across two reads) before a pull — see kSizeStabilityMaxWait. Falls
  /// through (returns) the moment the size can't be read at all, so a
  /// device that doesn't support `ls -l` output never blocks a pull.
  Future<void> _waitForStableSize(String name) async {
    final sw = Stopwatch()..start();
    int? lastSize;
    while (sw.elapsed < kSizeStabilityMaxWait) {
      final size = (await _listDeviceImageSizes())?[name];
      if (size == null) return; // can't confirm — don't block the pull
      if (size > 0 && size == lastSize) return; // stable
      lastSize = size;
      await Future<void>.delayed(kSizeStabilityPollInterval);
    }
  }

  /// Returns true if at least one new capture was synced this call. Used by
  /// [_kickExpeditedSync] to know when to stop polling early.
  Future<bool> _syncNewDeviceImages({bool silent = false}) async {
    if (!mounted ||
        _cleanedUp ||
        _isPulling ||
        _cancelLoading ||
        _isWaitingForRecapture ||
        _isSyncingNewCaptures) {
      return false;
    }

    _isSyncingNewCaptures = true;
    try {
      // null = the phone did not answer; [] = it answered with an empty roll.
      // The two must not be conflated here: an unreachable phone must leave
      // the baseline unseeded, while an answered-but-empty roll IS a valid
      // (empty) baseline - otherwise the operator's first capture becomes the
      // baseline on the next tick and is silently never ingested.
      final listed = await _listDeviceImageNamesOrNull();
      if (listed == null) {
        // Pause binding until begin() identifies the phone again; the capture
        // boundary itself survives a transient adb failure.
        ColorCaptureSession.phoneUnavailable();
        return false;
      }
      final currentNames = listed.toSet();

      // First successful listing after a failed scan: adopt it as the baseline
      // and ingest nothing on this tick. Self-healing, so a reconnect recovers
      // without the operator reopening the box - and the roll it just found is
      // pre-existing by definition, not a capture.
      if (!_deviceBaselineSeeded) {
        _knownDeviceFileNames
          ..clear()
          ..addAll(currentNames);
        _deviceBaselineSeeded = true;
        return false;
      }
      if (currentNames.isEmpty) {
        return false;
      }

      final previousNames = Set<String>.from(_knownDeviceFileNames);
      final newNames = currentNames.difference(previousNames).toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      if (_isBoxMode && newNames.isNotEmpty &&
          !await ColorCaptureSession.begin(auth.deviceId.value)) {
        return false;
      }

      // Never import replacement captures as standalone gallery images —
      // the original slot's tile already displays them.
      newNames.removeWhere((name) {
        if (!_originalNameByReplacement.containsKey(name)) {
          return false;
        }
        _knownDeviceFileNames.add(name);
        return true;
      });
      final deletedNames = previousNames.difference(currentNames).toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

      if (newNames.isEmpty && deletedNames.isEmpty) {
        _knownDeviceFileNames
          ..clear()
          ..addAll(currentNames);
        return false;
      }

      if (!silent && mounted) {
        final syncMsg = newNames.isNotEmpty && deletedNames.isNotEmpty
            ? 'Syncing ${newNames.length} new and ${deletedNames.length} removed image(s)...'
            : newNames.isNotEmpty
            ? 'Syncing ${newNames.length} new image(s) from the device...'
            : 'Removing ${deletedNames.length} deleted image(s) from the gallery...';
        _setStatus(syncMsg);
      }

      int syncedCount = 0;
      final syncedNames = <String>[];
      final cacheDir = await _ensureGalleryCacheDir();
      for (final name in newNames) {
        final key = _dateKeyFromFilename(name);

        // Optimistic placeholder: register the name and show a spinner
        // tile immediately (before the pull/decode even starts), so a new
        // capture appears in the grid right away. Swapped for the real
        // thumbnail below, or rolled back on failure.
        _registerDeviceFileName(name, reindex: false);
        c.addThumbnail(
          key,
          File(p.join(cacheDir.path, name)),
          null,
          refresh: true,
        );

        // Size-stability gate: a fast expedited poll can otherwise catch
        // the camera app mid-write and pull a truncated JPEG.
        await _waitForStableSize(name);

        final file = await _pullSingleFile(name, targetDir: cacheDir);
        if (file == null || !file.existsSync()) {
          // Rolls back both the placeholder tile and the registration
          // above (date/sequence bookkeeping) via the shared helper.
          _removeDeletedImagesFromGallery([name]);
          // Drop it from this tick's baseline so the next live-sync tick
          // re-detects and RETRIES the pull — otherwise the :992 baseline
          // rewrite would remember it as "seen" and the capture would be
          // silently lost (invisible after restart via the assigned-only
          // filter).
          currentNames.remove(name);
          continue;
        }

        // Cache-aware so this freshly captured thumbnail is decoded once and
        // reused if the box is later reopened this session.
        // Width only. instantiateImageCodec scales to targetWidth AND
        // targetHeight when both are given, without preserving aspect ratio, so
        // passing 512x512 squashed every 6144x8192 capture into a square and
        // baked the distortion into the thumbnail bytes. With height omitted the
        // codec keeps the 3:4 shape (512x683).
        final thumb = await c.thumbnailFor(file, targetWidth: 512);
        if (thumb != null) {
          _replaceTileThumbnail(name, thumb);
        }

        // Box mode: a newly captured photo belongs to the active folder
        // (auto-by-capture-order); the freshly pulled copy is also persisted
        // into the box's durable local store so transfer needn't re-pull it.
        // Replacement overlays never reach this loop (filtered above); swap
        // recaptures reuse the original filename, so slot inheritance needs
        // no code here.
        // Never in rework mode: that would add an image to an already
        // transferred folder. _startLiveSync's guard normally stops this loop
        // running at all there; this is the belt to its braces, because a wrong
        // assignment is the one capture-integrity mistake that cannot be undone
        // from the UI.
        if (_isBoxMode && !_reworkMode) {
          await _boxSession!.assignNewImage(name, localFile: file);
        }
        syncedNames.add(name);

        if (_globalFullSelection || _fullDateKeySelection == key) {
          final updatedSelection = c.selectedImages.toSet()..add(file);
          c.selectedImages.assignAll(updatedSelection.toList());
        }

        syncedCount++;
      }
      if (syncedNames.isNotEmpty) {
        _rebuildSequenceIndexes(); // covers registrations made in the loop
      }

      int removedCount = 0;
      if (deletedNames.isNotEmpty) {
        removedCount = _removeDeletedImagesFromGallery(deletedNames);
      }

      if (syncedCount == 0 && removedCount == 0) {
        _knownDeviceFileNames
          ..clear()
          ..addAll(currentNames);
        return false;
      }

      _sortGroupedImagesByFilename();
      if (syncedNames.isNotEmpty) {
        _previewLatestLoadedImage(preferredNames: syncedNames);
        _scrollOnceTo(_captureTileKey(syncedNames.last), fallbackToEnd: true);
      } else {
        _ensurePreviewSelection();
      }

      _knownDeviceFileNames
        ..clear()
        ..addAll(currentNames);

      final parts = <String>[];
      if (syncedCount > 0) {
        parts.add('synced $syncedCount new');
      }
      if (removedCount > 0) {
        parts.add('removed $removedCount deleted');
      }
      _setStatus(
        '✅ ${parts.join(' and ')} image(s). Total: ${_getTotalDeviceImageCount()} images.',
        force: true,
      );
      return syncedCount > 0;
    } catch (e) {
      print('⚠️ Live sync failed: $e');
      return false;
    } finally {
      _isSyncingNewCaptures = false;
    }
  }

  Future<void> loadDcimImages() async {
    print("🔎 Starting DCIM scan via ADB...");
    _cancelLoading = false;
    _replacementFilesByOriginal.clear();
    _replacementThumbsByOriginal.clear();
    _replacementInfoByOriginal.clear();
    _originalNameByReplacement.clear();
    _sequenceIndexByName.clear();
    setState(() => statusMsg = "Scanning DCIM/Camera on device...");
    _isPulling = true;

    final possiblePaths = [
      '/storage/emulated/0/DCIM/Camera',
      '/sdcard/DCIM/Camera',
    ];

    _workingPath = null;
    List<String> files = [];

    // Did the phone actually answer? An unreachable device and a genuinely
    // empty DCIM both produce an empty listing, and this loop used to read
    // only stdout - so it could not tell them apart. Both matter, in opposite
    // directions: treating "unreachable" as "empty" leaves an unseeded
    // baseline that claims the whole camera roll on reconnect, while treating
    // "empty" as "unreachable" swallows the operator's first capture as the
    // baseline instead of ingesting it. adb forwards the remote exit status,
    // so exitCode 0 is the discriminator.
    bool deviceAnswered = false;

    for (final path in possiblePaths) {
      print("🔍 Checking DCIM path: $path");
      final result = await Process.run(adbPath, ['shell', 'ls', '-1', path]);
      final output = result.stdout.toString().trim();
      if (deviceAnsweredListing(exitCode: result.exitCode, stdout: output)) {
        // Reachable. Remember the path even when the folder is empty, so the
        // later inline listings prefer it over re-probing the candidates.
        deviceAnswered = true;
        _workingPath = path;
      }
      if (output.isNotEmpty && !output.contains("No such file")) {
        files = output
            .split('\n')
            .map((f) => f.trim().replaceAll('\r', ''))
            .where((f) => f.isNotEmpty)
            .where((f) {
              final name = f.toLowerCase();
              return name.endsWith('.jpg') ||
                  name.endsWith('.jpeg') ||
                  name.endsWith('.png') ||
                  name.endsWith('.heic') ||
                  name.endsWith('.heif') ||
                  name.endsWith('.webp');
            })
            .toList();
        _workingPath = path;
        print("✅ DCIM path in use: $_workingPath (${files.length} files)");
        break;
      }
    }

    if (_workingPath == null || files.isEmpty) {
      setState(() => statusMsg = "No images found in DCIM/Camera");
      c.groupedImages.clear();
      c.selectedImages.clear();
      c.setPreview(null);
      _knownDeviceFileNames.clear();
      // An empty baseline is CORRECT and seeded when the phone answered with
      // an empty DCIM - the next capture is then a real one. Only an
      // unreachable device leaves it unseeded.
      _deviceBaselineSeeded = deviceAnswered;
      _dateTotals.clear();
      _allFileNamesByDate.clear();
      _replacementFilesByOriginal.clear();
      _replacementThumbsByOriginal.clear();
      _replacementInfoByOriginal.clear();
      _originalNameByReplacement.clear();
      _sequenceIndexByName.clear();
      _globalFullSelection = false;
      _fullDateKeySelection = null;
      _isPulling = false;
      print("⚠️ No images found in DCIM/Camera.");
      return;
    }

    files = files.reversed.toList();

    // Sort files by filename in ascending order for consistent display
    files.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    // Full device listing — always the live-sync baseline, independent of
    // the box-mode scoping below, so pre-existing/other-box images are
    // never mistaken for a "new" capture by _syncNewDeviceImages's diff.
    _knownDeviceFileNames
      ..clear()
      ..addAll(files);
    _deviceBaselineSeeded = true;

    // Restore replacement records before filtering so replacement captures
    // on the device are excluded from the QC grid — the original slot's
    // tile already displays them.
    if (_boxSession != null) {
      for (final name in _boxSession!.assignments.keys) {
        final recovered = await ColorReworkStore.recoverCaptureSlot(
          auth.deviceId.value, name, dateKey: _dateKeyFromFilename(name),
          username: auth.username.value);
        if (recovered != null) await _boxSession!.replaceDurableImage(name, recovered);
      }
    }
    await _restoreReplacementStateFromDb();
    files = files
        .where((name) => !_originalNameByReplacement.containsKey(name))
        .toList();

    // Box mode: only the box's ASSIGNED images are pulled/displayed — a
    // pre-existing camera roll or another box's captures are neither shown
    // nor pulled (they're still seeded into _knownDeviceFileNames above, so
    // live-sync won't re-surface them as new either).
    if (_isBoxMode) {
      final assignedNames = _boxSession!.assignments.keys.toSet();
      files = files.where(assignedNames.contains).toList();

      // Assigned images whose bytes exist ONLY in the durable local store
      // (a healed/admin-resolved orphan whose device file is gone) are still
      // part of the box and WILL transfer (stageBoxFiles' durable-store
      // fallback) — show them in the grid too, sourced from the store by the
      // pull pipeline below. Added AFTER the _knownDeviceFileNames seeding
      // above on purpose: they are not on the device, so they must never
      // enter the live-sync baseline (the deleted-names diff would otherwise
      // unassign them on the next tick).
      final onDevice = files.toSet();
      final storeDir = await _boxSession!.activeBoxImagesDir;
      final localOnly = storeDir == null
          ? const <String>[]
          : assignedNames
                .where(
                  (n) =>
                      !onDevice.contains(n) &&
                      File(p.join(storeDir.path, n)).existsSync(),
                )
                .toList();
      if (localOnly.isNotEmpty) {
        print(
          '📦 ${localOnly.length} assigned image(s) shown from the local '
          'store (no longer on the device): $localOnly',
        );
        files = [...files, ...localOnly];
      }
    }

    _dateTotals.clear();
    _allFileNamesByDate.clear();
    for (final name in files) {
      final key = _dateKeyFromFilename(name);
      _dateTotals[key] = (_dateTotals[key] ?? 0) + 1;
      _allFileNamesByDate.putIfAbsent(key, () => []).add(name);
    }
    print("📅 Per-date totals on device: $_dateTotals");

    // Sort date groups chronologically
    final sortedDateKeys = _allFileNamesByDate.keys.toList()
      ..sort((a, b) => _parseDateKey(a).compareTo(_parseDateKey(b)));
    final sortedFileNamesByDate = <String, List<String>>{};
    for (final key in sortedDateKeys) {
      final fileList = _allFileNamesByDate[key]!;
      // Sort files within each date group by filename
      fileList.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      sortedFileNamesByDate[key] = fileList;
    }
    _allFileNamesByDate.clear();
    _allFileNamesByDate.addAll(sortedFileNamesByDate);
    _rebuildSequenceIndexes();

    final totalAvailable = files.length;
    final totalToLoad = files.length;

    final cacheDir = await _ensureGalleryCacheDir();
    print("📂 Using temp dir: ${cacheDir.path}");
    final wantedNames = files.toSet();
    final retained = <String, List<ImageEntry>>{};
    final retainedNames = <String>{};
    for (final entries in c.groupedImages.values) {
      for (final entry in entries) {
        final name = p.basename(entry.file.path);
        if (entry.thumb == null ||
            !wantedNames.contains(name) ||
            _replacementInfoByOriginal.containsKey(name)) {
          continue;
        }
        retained.putIfAbsent(_dateKeyFromFilename(name), () => []).add(entry);
        retainedNames.add(name);
      }
    }
    c.groupedImages.value = retained;
    c.selectedImages.removeWhere(
      (file) => !wantedNames.contains(p.basename(file.path)),
    );
    final preview = c.previewFile.value;
    if (preview != null &&
        !wantedNames.contains(
          _canonicalTransferName(p.basename(preview.path)),
        )) {
      c.setPreview(null);
    }

    setState(
      () => statusMsg =
          "Total: $totalAvailable images | Loaded ${retainedNames.length} / $totalToLoad images…",
    );
    print(
      "📱 Found $totalAvailable images on $deviceModel. Displaying all $totalToLoad images for QC.",
    );

    // Box mode: prefer the box's durable local store over a fresh ADB pull —
    // assignNewImage already persisted a copy of every assigned image there,
    // so reopening a box needn't re-pull anything still present locally.
    final Directory? boxLocalStoreDir = _isBoxMode
        ? await _boxSession!.activeBoxImagesDir
        : null;

    const maxConcurrent = 8;
    int completed = retainedNames.length;
    final filesToLoad = files
        .where((name) => !retainedNames.contains(name))
        .toList();

    Future<void> pullBatch(List<String> batch) async {
      await Future.wait(
        batch.map((name) async {
          if (_cancelLoading) {
            print("⏹ Skipping pull for $name due to cancel request.");
            return;
          }

          final remoteFile = "$_workingPath/$name";
          final localPath = "${cacheDir.path}/$name";

          try {
            // Reuse a previously pulled copy when present (the cache dir is
            // stable across mode switches). A replacement slot never reuses the
            // CACHE - a swap changes the bytes under the same filename - but it
            // may still come from the durable store below, which the swap now
            // keeps current (BoxSessionController.replaceDurableImage).
            final cached = File(localPath);
            final canReuse =
                cached.existsSync() &&
                cached.lengthSync() > 0 &&
                !_replacementInfoByOriginal.containsKey(name);

            if (!canReuse) {
              var copiedFromLocalStore = false;
              if (boxLocalStoreDir != null) {
                final localCopy = File(p.join(boxLocalStoreDir.path, name));
                if (localCopy.existsSync() && localCopy.lengthSync() > 0) {
                  try {
                    await localCopy.copy(localPath);
                    copiedFromLocalStore = true;
                  } catch (e) {
                    print("⚠️ Failed to copy $name from box local store: $e");
                  }
                }
              }
              if (!copiedFromLocalStore) {
                print("⬇️ Pulling $remoteFile -> $localPath");
                final pull = await Process.run(adbPath, [
                  'pull',
                  remoteFile,
                  localPath,
                ]);
                if (pull.exitCode != 0) {
                  print(
                    "⚠️ adb pull failed for $name (exitCode: ${pull.exitCode})",
                  );
                }
              }
            }

            final file = File(localPath);
            if (file.existsSync()) {
              final key = _dateKeyFromFilename(p.basename(file.path));
              // Cache-aware decode: a same-session box reopen reuses the
              // already-decoded thumbnail instead of re-reading+decoding
              // every ~13MB file. Replacement slots bypass the cache (bytes
              // can change under a stable filename — same rule as the
              // file-reuse `canReuse` check above).
              // Width only - see the note on the capture path above: giving
              // both dimensions squashes the image rather than scaling it.
              final thumbBytes = await c.thumbnailFor(
                file,
                bypassCache: _replacementInfoByOriginal.containsKey(name),
                targetWidth: 512,
              );

              c.addThumbnail(key, file, thumbBytes, refresh: false);
            } else {
              print("⚠️ Pulled file not found locally: $localPath");
            }
          } catch (e) {
            print("⚠️ Failed to pull $name: $e");
          }

          completed++;
          final msg =
              "Total: $totalAvailable images | Loaded $completed / $totalToLoad images…";
          if (!_cancelLoading) {
            _setStatus(msg); // throttled — fires per file otherwise
          }
          print(msg);
        }),
      );

      c.groupedImages.refresh();
      _ensurePreviewSelection();
      await Future.delayed(const Duration(milliseconds: 80));
    }

    for (int i = 0; i < filesToLoad.length; i += maxConcurrent) {
      if (_cancelLoading) {
        print("⏹ Loading cancelled before processing next batch.");
        break;
      }
      final batch = filesToLoad.skip(i).take(maxConcurrent).toList();
      print(
        "📦 Processing batch ${i ~/ maxConcurrent + 1} with ${batch.length} files",
      );
      await pullBatch(batch);
    }

    _isPulling = false;

    _sortGroupedImagesByFilename();

    // Generous decoded-image cache: the preview (cacheWidth-capped ~25MB) and
    // the visible thumbnails must all stay resident. The previous 40MB clamp
    // was smaller than ONE decoded preview, forcing a full re-decode on every
    // preview click.
    PaintingBinding.instance.imageCache.maximumSize = 1000;
    PaintingBinding.instance.imageCache.maximumSizeBytes = 512 << 20;
    _ensurePreviewSelection(preferLatest: true);

    if (_cancelLoading) {
      final msg = "⏹ Loading cancelled.";
      _setStatus(msg, force: true);
      print(msg);
    } else {
      final doneMsg =
          "✅ Total: $totalAvailable images | Finished loading $totalToLoad images.";
      _setStatus(doneMsg, force: true);
      print(doneMsg);
    }
  }

  List<String> _getOrderedSequenceNames() {
    final ordered = <String>[];
    for (final entry in _allFileNamesByDate.entries) {
      ordered.addAll(entry.value);
    }
    return ordered;
  }

  void _sortGroupedImagesByFilename() {
    // Order groups by date (chronological)
    final sortedDateKeys = c.groupedImages.keys.toList()
      ..sort((a, b) => _parseDateKey(a).compareTo(_parseDateKey(b)));

    final sortedGroups = <String, List<ImageEntry>>{};
    for (final key in sortedDateKeys) {
      final group = List<ImageEntry>.from(c.groupedImages[key] ?? []);
      group.sort((a, b) {
        final an = p.basename(a.file.path).toLowerCase();
        final bn = p.basename(b.file.path).toLowerCase();
        return an.compareTo(bn);
      });
      sortedGroups[key] = group;
    }

    c.groupedImages.value = sortedGroups;
    c.groupedImages.refresh();
  }

  int _removeDeletedImagesFromGallery(List<String> deletedNames) {
    if (deletedNames.isEmpty) {
      return 0;
    }

    final deletedSet = deletedNames.toSet();
    final removedFiles = <File>[];

    final updatedGroups = <String, List<ImageEntry>>{};
    for (final entry in c.groupedImages.entries) {
      final remaining = entry.value.where((imageEntry) {
        final name = p.basename(imageEntry.file.path);
        final shouldKeep = !deletedSet.contains(name);
        if (!shouldKeep) {
          removedFiles.add(imageEntry.file);
        }
        return shouldKeep;
      }).toList();

      if (remaining.isNotEmpty) {
        updatedGroups[entry.key] = remaining;
      }
    }

    for (final name in deletedNames) {
      _unregisterDeviceFileName(name, reindex: false);
    }
    _rebuildSequenceIndexes(); // batched — once for the whole delete set

    if (removedFiles.isNotEmpty) {
      final removedPaths = removedFiles.map((f) => f.path).toSet();
      c.selectedImages.removeWhere((file) => removedPaths.contains(file.path));

      final preview = c.previewFile.value;
      if (preview != null && removedPaths.contains(preview.path)) {
        c.setPreview(null);
      }
    }

    c.groupedImages
      ..clear()
      ..addAll(updatedGroups);
    c.groupedImages.refresh();
    return removedFiles.length;
  }

  /// Replacement captures stay on the device next to the originals, but the
  /// QC grid must not show them as standalone tiles: the original slot's
  /// tile already displays the replacement. Strip them from the date and
  /// sequence bookkeeping and from the visible grid, while keeping them in
  /// [_knownDeviceFileNames] so live sync does not re-import them.
  void _purgeReplacementCapturesFromGallery() {
    final replacementNames = _originalNameByReplacement.keys.toSet();
    if (replacementNames.isEmpty) return;

    var namesChanged = false;
    final updatedNamesByDate = <String, List<String>>{};
    for (final entry in _allFileNamesByDate.entries) {
      final remaining = entry.value
          .where((name) => !replacementNames.contains(name))
          .toList();
      if (remaining.length != entry.value.length) namesChanged = true;
      if (remaining.isNotEmpty) {
        updatedNamesByDate[entry.key] = remaining;
      }
    }
    if (namesChanged) {
      _allFileNamesByDate
        ..clear()
        ..addAll(updatedNamesByDate);
      _rebuildSequenceIndexes();
    }

    final removedFiles = <File>[];
    final updatedGroups = <String, List<ImageEntry>>{};
    for (final entry in c.groupedImages.entries) {
      final remaining = entry.value.where((imageEntry) {
        final keep = !replacementNames.contains(
          p.basename(imageEntry.file.path),
        );
        if (!keep) removedFiles.add(imageEntry.file);
        return keep;
      }).toList();
      if (remaining.isNotEmpty) {
        updatedGroups[entry.key] = remaining;
      }
    }
    if (removedFiles.isNotEmpty) {
      final removedPaths = removedFiles.map((f) => f.path).toSet();
      c.selectedImages.removeWhere((file) => removedPaths.contains(file.path));

      // A replaced slot previews the replacement's local file, which shares
      // its path with the removed tile — keep that preview alive.
      final activeReplacementPaths = _replacementFilesByOriginal.values
          .map((f) => f.path)
          .toSet();
      final preview = c.previewFile.value;
      if (preview != null &&
          removedPaths.contains(preview.path) &&
          !activeReplacementPaths.contains(preview.path)) {
        c.setPreview(null);
      }

      c.groupedImages
        ..clear()
        ..addAll(updatedGroups);
      c.groupedImages.refresh();
    }
  }

  // --- Replacement (recapture) bookkeeping and preview navigation ----------

  Future<void> _restoreReplacementStateFromDb() async {
    try {
      final rows = await UploadStatsDB().getReplacementRecords(
        auth.deviceId.value,
      );
      _replacementInfoByOriginal.clear();
      _originalNameByReplacement.clear();
      _replacementFilesByOriginal.clear();
      _replacementThumbsByOriginal.clear();

      final supersededRecords = <_ReplacementRecordInfo>[];
      for (final row in rows) {
        final originalFilename = (row['original_filename'] as String? ?? '')
            .trim();
        final replacementFilename =
            (row['replacement_filename'] as String? ?? '').trim();
        if (originalFilename.isEmpty || replacementFilename.isEmpty) {
          continue;
        }

        final info = _ReplacementRecordInfo(
          originalFilename: originalFilename,
          replacementFilename: replacementFilename,
          replacementLocalPath: row['replacement_local_path'] as String?,
          replacementType: (row['replacement_type'] as String? ?? 'recapture')
              .trim(),
        );

        final previousInfo = _replacementInfoByOriginal[originalFilename];
        if (previousInfo != null) {
          supersededRecords.add(previousInfo);
          _originalNameByReplacement.remove(previousInfo.replacementFilename);
        }

        _replacementInfoByOriginal[originalFilename] = info;
        _originalNameByReplacement[replacementFilename] = originalFilename;
      }

      for (final info in supersededRecords) {
        final latestInfo = _replacementInfoByOriginal[info.originalFilename];
        if (latestInfo?.replacementFilename == info.replacementFilename) {
          continue;
        }

        // Swapped records have no standalone capture file: the capture was
        // renamed over the original, and their local path points at the
        // slot's own cache file, which must stay.
        if (!info.isSwap) {
          await _deleteDeviceImageByName(info.replacementFilename);
          _removeDeletedImagesFromGallery([info.replacementFilename]);

          final localPath = info.replacementLocalPath;
          if (localPath != null && localPath.trim().isNotEmpty) {
            await _deleteLocalFileIfExists(File(localPath));
          }
        }

        await UploadStatsDB().markReplacementRecordSuperseded(
          deviceId: auth.deviceId.value,
          originalFilename: info.originalFilename,
          replacementFilename: info.replacementFilename,
        );
        await _auditOrNull?.logReplacement(
          event: 'superseded',
          originalFilename: info.originalFilename,
          replacementFilename: info.replacementFilename,
          replacementType: info.replacementType,
          boxDetails: _boxSession?.activeBox.value?.boxDetails ?? '',
          extra: const {'reason': 'stale_restore'},
        );
      }

      for (final info in _replacementInfoByOriginal.values) {
        // Swapped slots need no overlay: the device and the cache hold the
        // corrected image under the original's own filename.
        if (info.isSwap) {
          continue;
        }

        final localPath = info.replacementLocalPath;

        File? file;
        if (localPath != null && localPath.trim().isNotEmpty) {
          final candidate = File(localPath);
          if (candidate.existsSync()) {
            file = candidate;
          }
        }

        // The temp copy from a previous session is wiped on app close;
        // pull the capture from the device again so the slot still
        // previews the replacement image.
        file ??= await _pullSingleFile(info.replacementFilename);
        if (file == null || !file.existsSync()) {
          continue;
        }

        _replacementFilesByOriginal[info.originalFilename] = file;
        _replacementThumbsByOriginal[info.originalFilename] =
            await _buildThumbnailBytes(file);
      }

      _purgeReplacementCapturesFromGallery();

      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      print('⚠️ Failed restoring replacement records from DB: $e');
    }
  }

  Map<String, File> _loadedFilesByOriginalName() {
    final map = <String, File>{};
    for (final group in c.groupedImages.values) {
      for (final entry in group) {
        map[p.basename(entry.file.path)] = entry.file;
      }
    }
    return map;
  }

  bool _navigatePreviewByArrow(int delta) {
    final orderedNames = _getOrderedSequenceNames();
    if (orderedNames.isEmpty) return false;

    final loadedByName = _loadedFilesByOriginalName();
    final availableNames = orderedNames
        .where((name) => loadedByName.containsKey(name))
        .toList();

    if (availableNames.isEmpty) return false;

    final currentPreview = c.previewFile.value;
    int currentIndex = currentPreview == null
        ? -1
        : availableNames.indexWhere((name) {
            final originalFile = loadedByName[name]!;
            final displayFile = _displayFileForSlot(name, originalFile);
            return displayFile.path == currentPreview.path;
          });

    if (currentIndex == -1) {
      currentIndex = delta > 0 ? -1 : 0;
    }

    final targetIndex = (currentIndex + delta).clamp(
      0,
      availableNames.length - 1,
    );
    if (targetIndex < 0 || targetIndex >= availableNames.length) return false;

    final targetName = availableNames[targetIndex];
    final targetOriginalFile = loadedByName[targetName]!;
    c.setPreview(_displayFileForSlot(targetName, targetOriginalFile));

    if (mounted) {
      setState(() {});
    }
    _viewerFocusNode.requestFocus();
    return true;
  }

  KeyEventResult _handleViewerKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      return _navigatePreviewByArrow(1)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      return _navigatePreviewByArrow(-1)
          ? KeyEventResult.handled
          : KeyEventResult.ignored;
    }

    return KeyEventResult.ignored;
  }

  int _getReplacementCount() {
    return _replacementInfoByOriginal.values.where((info) {
      return _knownDeviceFileNames.contains(info.originalFilename) ||
          _knownDeviceFileNames.contains(info.replacementFilename);
    }).length;
  }

  _ReplacementRecordInfo? _replacementInfoForTile(String name) {
    final direct = _replacementInfoByOriginal[name];
    if (direct != null) {
      return direct;
    }

    final originalName = _originalNameByReplacement[name];
    if (originalName != null) {
      return _replacementInfoByOriginal[originalName];
    }

    return null;
  }

  bool _isReplacementPrimaryTile(String name) {
    return _replacementInfoByOriginal.containsKey(name);
  }

  String _linkedLabelForTile(String name) {
    final direct = _replacementInfoByOriginal[name];
    if (direct != null) {
      return '$name → ${direct.replacementFilename}';
    }

    final originalName = _originalNameByReplacement[name];
    if (originalName != null) {
      return '$originalName → $name';
    }

    return name;
  }

  Future<void> _deleteDeviceImageByName(String name) async {
    if ((_workingPath ?? '').isEmpty || name.trim().isEmpty) {
      return;
    }

    final remoteFile = '$_workingPath/$name';
    try {
      final delete = await Process.run(adbPath, [
        'shell',
        'rm',
        '-f',
        remoteFile,
      ]);
      if (delete.exitCode == 0) {
        print('Deleted superseded recapture from device: $remoteFile');
      } else {
        print(
          'Failed deleting superseded recapture $remoteFile: ${delete.stderr}',
        );
      }
    } catch (e) {
      print('Failed deleting superseded recapture $remoteFile: $e');
    }
  }

  Future<void> _deleteLocalFileIfExists(File? file) async {
    if (file == null || !file.existsSync()) {
      return;
    }

    try {
      await file.delete();
      print('Deleted superseded local recapture: ${file.path}');
    } catch (e) {
      print('Failed deleting superseded local recapture ${file.path}: $e');
    }
  }

  Future<void> _discardPreviousReplacementForSlot(String originalName) async {
    final previousInfo = _replacementInfoByOriginal[originalName];
    final previousFile = _replacementFilesByOriginal[originalName];

    if (previousInfo == null && previousFile == null) {
      await UploadStatsDB().markReplacementRecordsSuperseded(
        deviceId: auth.deviceId.value,
        originalFilename: originalName,
      );
      return;
    }

    final previousName =
        previousInfo?.replacementFilename ??
        (previousFile == null ? '' : p.basename(previousFile.path));

    // A swapped replacement no longer exists under its own filename on the
    // device (it was renamed over the original), so there is no standalone
    // capture file to clean up.
    final isLegacyOverlay = !(previousInfo?.isSwap ?? false);
    if (previousName.isNotEmpty && isLegacyOverlay) {
      await _deleteDeviceImageByName(previousName);
      _removeDeletedImagesFromGallery([previousName]);
    }
    _originalNameByReplacement.remove(previousName);

    if (isLegacyOverlay) {
      final previousLocalPath = previousInfo?.replacementLocalPath;
      await _deleteLocalFileIfExists(previousFile);
      if (previousLocalPath != null &&
          previousFile?.path != previousLocalPath) {
        await _deleteLocalFileIfExists(File(previousLocalPath));
      }

      final preview = c.previewFile.value;
      if (preview != null &&
          (preview.path == previousFile?.path ||
              preview.path == previousLocalPath)) {
        c.setPreview(null);
      }
    }

    _replacementFilesByOriginal.remove(originalName);
    _replacementThumbsByOriginal.remove(originalName);
    _replacementInfoByOriginal.remove(originalName);

    // Keep the audit trail: superseded records stay in the DB.
    await UploadStatsDB().markReplacementRecordsSuperseded(
      deviceId: auth.deviceId.value,
      originalFilename: originalName,
    );
    await _auditOrNull?.logReplacement(
      event: 'discarded',
      originalFilename: originalName,
      replacementFilename: previousName,
      replacementType: previousInfo?.replacementType ?? 'recapture',
      boxDetails: _boxSession?.activeBox.value?.boxDetails ?? '',
    );
  }

  /// Replaces the erroneous original on the device with the new capture by
  /// renaming the capture over the original's filename. The original is
  /// parked as a `.bak` sidecar until the swap succeeds, so a failure midway
  /// can never lose both images. Returns true when the device holds the
  /// corrected image under the original's name and the erroneous original
  /// is gone.
  Future<bool> _swapReplacementIntoOriginalSlot({
    required String originalName,
    required String replacementName,
  }) async {
    final workingPath = _workingPath ?? '';
    if (workingPath.isEmpty) {
      return false;
    }

    // Renaming across container formats would mislabel the file contents;
    // fall back to overlay behavior in that (unlikely) case.
    if (p.extension(originalName).toLowerCase() !=
        p.extension(replacementName).toLowerCase()) {
      print(
        '⚠️ Extension mismatch between $originalName and $replacementName '
        '— keeping original on device, using overlay replacement.',
      );
      return false;
    }

    final originalPath = '$workingPath/$originalName';
    final replacementPath = '$workingPath/$replacementName';
    final backupPath = '$originalPath.lifetrans_bak';

    Future<bool> runShell(List<String> args) async {
      try {
        final result = await Process.run(adbPath, ['shell', ...args]);
        return result.exitCode == 0;
      } catch (e) {
        print('⚠️ Device command failed (${args.join(' ')}): $e');
        return false;
      }
    }

    if (!await runShell(['mv', originalPath, backupPath])) {
      return false;
    }
    if (!await runShell(['mv', replacementPath, originalPath])) {
      // Roll back so the slot is never left without an image.
      await runShell(['mv', backupPath, originalPath]);
      return false;
    }
    await runShell(['rm', backupPath]);
    print(
      '🔁 Swapped $replacementName over $originalName on device — '
      'erroneous original deleted.',
    );
    return true;
  }

  /// Rebuilds the stored thumbnail of the gallery tile whose file matches
  /// [fileName] (used after the file's bytes were replaced in place).
  void _replaceTileThumbnail(String fileName, Uint8List? thumb) {
    for (final entry in c.groupedImages.entries) {
      final group = entry.value;
      for (var i = 0; i < group.length; i++) {
        if (p.basename(group[i].file.path) == fileName) {
          group[i] = ImageEntry(group[i].file, thumb);
          c.groupedImages.refresh();
          return;
        }
      }
    }
  }

  // --- Recapture: launching the phone camera and swapping the new photo in -

  // Known camera packages, launched WITHOUT ever force-stopping. The old
  // force-stop-before-each-attempt + fall-through retry loop is what made
  // the camera flash in and out several times before settling on HyperOS.
  static const List<String> _cameraPackages = [
    'com.android.camera',
    'com.sec.android.app.camera',
  ];
  static const String _cameraUiDumpPath = '/sdcard/life_transfer_camera_ui.xml';
  // HyperOS / MIUI Pro-mode UI markers — their presence in the live view
  // hierarchy confirms Pro mode (read via uiautomator, not logcat).
  static const List<String> _proModeResourceIds = [
    'com.android.camera:id/pro_viewpager',
    'com.android.camera:id/manually_recycler_view',
    'com.android.camera:id/reset_manually_parameter_tip',
  ];

  Future<bool> _isPackageInstalled(String packageName) async {
    final result = await Process.run(adbPath, [
      'shell',
      'pm',
      'path',
      packageName,
    ]);
    return result.exitCode == 0 && result.stdout.toString().trim().isNotEmpty;
  }

  Future<String?> _foregroundCameraPackage() async {
    try {
      final result = await Process.run(adbPath, [
        'shell',
        'dumpsys',
        'activity',
        'activities',
      ]);
      if (result.exitCode != 0) return null;
      final resumed = result.stdout
          .toString()
          .split('\n')
          .where(
            (l) =>
                l.contains('topResumedActivity=') ||
                l.contains('mResumedActivity'),
          )
          .join('\n');
      for (final pkg in _cameraPackages) {
        if (resumed.contains(pkg)) return pkg;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Fire-and-forget Pro-mode verification. The uiautomator dump takes ~2s
  /// on-device and its result only ever produces a status-bar hint — it never
  /// gates the recapture flow — so it must not sit on the critical path
  /// (awaiting it used to delay arming the new-capture detector by that
  /// long). [warning] is shown if Pro mode can't be confirmed, but only while
  /// the recapture is still in flight, so a late result can never clobber the
  /// final "Replacement saved" status.
  void _verifyProModeInBackground(String warning) {
    unawaited(
      _isCameraInProMode().then((isPro) {
        if (isPro) {
          print('📷 Camera verified in Pro mode.');
        } else if (mounted && _isWaitingForRecapture) {
          setState(() => statusMsg = warning);
        }
      }),
    );
  }

  /// True when the live camera UI shows Pro-mode controls, read by dumping
  /// the current view hierarchy with uiautomator (matching the 1.0.x build
  /// that ran cleanly on the Xiaomi 14 Ultra).
  Future<bool> _isCameraInProMode() async {
    try {
      final dump = await Process.run(adbPath, [
        'shell',
        'uiautomator',
        'dump',
        _cameraUiDumpPath,
      ]);
      if (dump.exitCode != 0) return false;
      final xml = await Process.run(adbPath, [
        'shell',
        'cat',
        _cameraUiDumpPath,
      ]);
      if (xml.exitCode != 0) return false;
      final content = xml.stdout.toString();
      return _proModeResourceIds.any(content.contains);
    } catch (_) {
      return false;
    }
  }

  /// Launches the device camera for a recapture. Returns exit code 0 once a
  /// known camera package is on screen, non-zero if it could not be brought
  /// up at all. Deliberately NEVER force-stops and NEVER kills-and-retries:
  /// the camera is launched at most once (the HyperOS
  /// `micamera://…module=167` deep link lands directly in Pro mode) and Pro
  /// mode is verified by reading the live UI. If Pro can't be confirmed the
  /// operator is asked to switch via [statusMsg] — the camera is left as is.
  /// This restores the smooth behavior of the 1.0.x build on the Xiaomi 14
  /// Ultra; the previous force-stop + multi-attempt loop made it flash.
  Future<ProcessResult> _launchCameraForRecapture() async {
    // Already on screen? Never relaunch — just verify/guide the mode
    // (in the background: the ~2s uiautomator dump must not hold up the
    // new-capture detector).
    if (await _foregroundCameraPackage() != null) {
      _verifyProModeInBackground(
        'Camera is already open, but Pro mode could not be verified. Please switch the Camera app to Pro mode.',
      );
      return ProcessResult(0, 0, 'camera-already-foreground', '');
    }

    final hasMi = await _isPackageInstalled('com.android.camera');
    final hasSamsung = await _isPackageInstalled('com.sec.android.app.camera');

    final attempts = <List<String>>[
      if (hasMi) ...[
        // Primary on HyperOS: deep link straight into Pro (module 167).
        [
          'shell',
          'am',
          'start',
          '-a',
          'android.intent.action.VIEW',
          '-d',
          'micamera://open?mode=MANUAL&module=167&camera_mode=167',
          '--ei',
          'android.intent.extra.CAMERA_MODE',
          '167',
        ],
        // Fallback: clean launcher start via monkey — no explicit component,
        // no force-stop — if the deep link isn't honoured.
        [
          'shell',
          'monkey',
          '-p',
          'com.android.camera',
          '-c',
          'android.intent.category.LAUNCHER',
          '1',
        ],
      ],
      if (hasSamsung)
        [
          'shell',
          'monkey',
          '-p',
          'com.sec.android.app.camera',
          '-c',
          'android.intent.category.LAUNCHER',
          '1',
        ],
      ['shell', 'am', 'start', '-a', 'android.media.action.STILL_IMAGE_CAMERA'],
    ];

    if (attempts.isEmpty) {
      return ProcessResult(
        0,
        1,
        '',
        'No Camera app launch attempt was available.',
      );
    }

    for (final args in attempts) {
      final result = await Process.run(adbPath, args);
      if (result.exitCode != 0) {
        print('Camera launch attempt failed: adb ${args.join(' ')}');
        continue;
      }
      // Wait for the (possibly cold-starting) camera to foreground — polling
      // only, no force-stop between polls — so a slow start is never misread
      // as a failure and never triggers a flashing relaunch.
      for (var i = 0; i < 12; i++) {
        await Future.delayed(const Duration(milliseconds: 600));
        if (await _foregroundCameraPackage() != null) {
          _verifyProModeInBackground(
            'Camera launched, but Pro mode could not be verified. Please switch the Camera app to Pro mode.',
          );
          return result;
        }
      }
      print(
        'Camera launch did not bring a known Camera package to the foreground: adb ${args.join(' ')}',
      );
    }

    return ProcessResult(0, 1, '', 'Camera could not be launched.');
  }

  /// Leaves the recapture state without taking a photo - the Esc key or the
  /// banner's X.
  ///
  /// There is no confirmation dialog in front of a recapture any more: the
  /// operator still has to physically press the shutter key for anything to be
  /// replaced, so the dialog only stood between them and the camera. This is
  /// the other half of that trade - having removed the way OUT of the flow, the
  /// flow needs one.
  ///
  /// Clears the visible state immediately rather than waiting for the flow to
  /// unwind: a camera launch already in progress holds its own ~7s of foreground
  /// polling, and a banner that lingers after the X reads as a stuck app. The
  /// `finally` clears the same fields again when the flow does unwind, which is
  /// idempotent.
  ///
  /// Deliberately NOT a way to undo a replacement: once the photo has been
  /// detected the swap runs to completion. This cancels waiting, not work.
  void _cancelRecapture() {
    if (!_isWaitingForRecapture) return;
    _recaptureCancelled = true;
    setState(() {
      _isWaitingForRecapture = false;
      _recaptureSlotOriginalName = null;
      statusMsg = 'Recapture cancelled.';
    });
  }

  Future<void> _bringAppToFront() async {
    try {
      if (await windowManager.isMinimized()) {
        await windowManager.restore();
      }
      await windowManager.show();
      await windowManager.focus();
    } catch (e) {
      print('⚠️ Failed to focus app window: $e');
    }
  }

  File _displayFileForSlot(String originalName, File fallback) {
    return _replacementFilesByOriginal[originalName] ?? fallback;
  }

  Uint8List? _thumbForSlot(String originalName, ImageEntry entry) {
    return _replacementThumbsByOriginal[originalName] ?? entry.thumb;
  }

  void _openPreviewForSlot(String originalName, File originalFile) {
    final displayFile = _displayFileForSlot(originalName, originalFile);
    c.setPreview(displayFile);
    print("🔎 Previewing image: ${displayFile.path}");
  }

  void _previewLatestLoadedImage({Iterable<String>? preferredNames}) {
    final loadedByName = _loadedFilesByOriginalName();
    if (loadedByName.isEmpty) {
      c.setPreview(null);
      return;
    }

    final orderedNames = preferredNames == null
        ? _getOrderedSequenceNames()
        : _dedupeTransferableNames(preferredNames);

    for (final name in orderedNames.reversed) {
      final file = loadedByName[name];
      if (file == null || !file.existsSync()) continue;

      c.setPreview(_displayFileForSlot(name, file));
      print("Auto-previewing latest image: ${file.path}");
      return;
    }
  }

  void _ensurePreviewSelection({bool preferLatest = false}) {
    final current = c.previewFile.value;
    if (!preferLatest && current != null && current.existsSync()) {
      return;
    }

    if (preferLatest) {
      _previewLatestLoadedImage();
      if (c.previewFile.value != null) {
        return;
      }
    }

    for (final group in c.groupedImages.values) {
      if (group.isEmpty) continue;
      final firstEntry = group.first;
      final originalName = p.basename(firstEntry.file.path);
      c.setPreview(_displayFileForSlot(originalName, firstEntry.file));
      return;
    }

    c.setPreview(null);
  }

  void _toggleSelectionFor(File file) {
    _globalFullSelection = false;
    _fullDateKeySelection = null;
    c.toggleSelection(file);
    if (c.selectedImages.contains(file)) {
      print("✅ Image selected: ${file.path}");
    } else {
      print("❎ Image deselected: ${file.path}");
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// Deletes the image in [slotOriginalName] from the phone and the gallery.
  /// Handles replaced slots too: any recapture overlay/records for the slot
  /// are discarded (audit-preserving) first, then the slot's current device
  /// file is removed and the tile drops out of the grid. Reuses the same
  /// cleanup the live-sync uses when a photo is deleted directly on the
  /// device, so counts/selection/preview stay consistent.
  Future<void> _confirmDeleteImage(
    String slotOriginalName,
    String groupKey,
  ) async {
    final seq = (_sequenceIndexByName[slotOriginalName] ?? 0) + 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete this image?'),
        content: Text(
          'Slot #$seq ($slotOriginalName) will be permanently deleted from '
          'the phone and removed from the gallery. This cannot be undone — '
          're-take the photo if you still need it.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Theme.of(ctx).colorScheme.error,
              foregroundColor: Theme.of(ctx).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      // Discard any recapture overlay/records for the slot (this supersedes
      // the DB records and removes an overlay's standalone device file).
      await _discardPreviousReplacementForSlot(slotOriginalName);
      // Remove the slot's canonical file from the device.
      await _deleteDeviceImageByName(slotOriginalName);
      _removeDeletedImagesFromGallery([slotOriginalName]);
      await _auditOrNull?.log(
        AuditActions.imageDeleted,
        details: {
          'file': slotOriginalName,
          'box': _boxSession?.activeBox.value?.boxDetails ?? '',
        },
      );

      if (mounted) {
        setState(() {
          statusMsg = '🗑️ Deleted slot #$seq.';
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted slot #$seq from the phone.')),
        );
      }
    } catch (e) {
      print('⚠️ Delete failed for $slotOriginalName: $e');
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
      }
    }
  }

  Future<void> _startRecaptureForSlot(
    String originalName,
    String dateKey,
  ) async {
    if (!mounted) return;

    if (_isBoxMode && !await ColorCaptureSession.begin(auth.deviceId.value)) return;
    final beforeNames = (await _listDeviceImageNames()).toSet();

    setState(() {
      _recaptureCancelled = false;
      _isWaitingForRecapture = true;
      _recaptureSlotOriginalName = originalName;
      statusMsg =
          'Recapture in progress for slot #${(_sequenceIndexByName[originalName] ?? 0) + 1}. Waiting for the new image from the device camera…';
    });

    try {
      // Poll for the new capture CONCURRENTLY with the camera launch checks:
      // beforeNames was snapshotted above, so a photo taken while the launch
      // verification runs is detected the moment it lands instead of only
      // after the checks finish (measured ~2s of a fast operator's photo
      // sitting undetected on the phone).
      //
      // 350ms, not the 2s default: a recapture cannot use the shutter-triggered
      // expedited sync (_syncNewDeviceImages returns early while
      // _isWaitingForRecapture), so this poll IS the detection latency.
      var launchFailed = false;
      final newNameFuture = _waitForNewCapture(
        beforeNames,
        pollInterval: kExpeditedSyncInterval,
        isCancelled: () => launchFailed || _recaptureCancelled,
      );

      final launch = await _launchCameraForRecapture();
      if (launch.exitCode != 0) {
        launchFailed = true;
        await newNameFuture; // let the poll loop notice and exit
        throw Exception(
          'Failed to launch camera for recapture: ${launch.stderr}'.trim(),
        );
      }

      final newName = await newNameFuture;
      if (newName == null) {
        // Cancelled deliberately: _cancelRecapture already said so, and a
        // failure message on top of it would read as something going wrong.
        if (mounted && !_recaptureCancelled) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'No new captured image was detected on the device.',
              ),
            ),
          );
        }
        return;
      }

      final replacementFile = await _pullSingleFile(newName);
      if (replacementFile == null || !replacementFile.existsSync()) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Replacement image could not be pulled from the device.',
              ),
            ),
          );
        }
        return;
      }

      final replacementFilename = p.basename(replacementFile.path);
      final replacementBinding = _boxSession == null ? null :
          await ColorCaptureSession.bindingFor(auth.deviceId.value, replacementFilename);
      File? durableReplacement;
      if (replacementBinding != null) {
        durableReplacement = await ColorReworkStore.stage(auth.deviceId.value,
            'capture-slot:$originalName', replacementFile, replacementBinding);
        await ColorReworkStore.beginApply(auth.deviceId.value, 'capture-slot:$originalName');
        await UploadStatsDB().markColorReplacementPending(auth.deviceId.value, originalName);
      }
      await _discardPreviousReplacementForSlot(originalName);

      // Delete the erroneous original from the device by renaming the new
      // capture over it; the DB record below preserves the audit trail.
      final swapped = await _swapReplacementIntoOriginalSlot(
        originalName: originalName,
        replacementName: replacementFilename,
      );

      var slotDisplayFile = durableReplacement ?? replacementFile;
      if (swapped) {
        // Mirror the device state locally: the corrected pixels now live
        // under the original's filename, so the existing tile and preview
        // pick them up from the original's cache path.
        final cacheDir = await _ensureGalleryCacheDir();
        final slotFile = File(p.join(cacheDir.path, originalName));
        await replacementFile.copy(slotFile.path);
        await FileImage(slotFile).evict();
        await ResizeImage.resizeIfNeeded(
          512,
          null,
          FileImage(slotFile),
        ).evict();
        // The preview panel decodes the same path at kPreviewCacheWidth; its
        // cache entry holds the superseded pixels too and must go as well.
        await ResizeImage.resizeIfNeeded(
          kPreviewCacheWidth,
          null,
          FileImage(slotFile),
        ).evict();
        // The durable box store too, not just the gallery cache. Reopening a
        // box copies from that store in preference to re-pulling, and
        // stageBoxFiles reuses it at transfer time - so leaving it holding the
        // superseded photo showed the old image again after a restart, and
        // could transfer it.
        if (_isBoxMode) {
          await _boxSession?.replaceDurableImage(originalName, slotFile);
        }
        if (replacementFile.path != slotFile.path) {
          await _deleteLocalFileIfExists(replacementFile);
        }
        slotDisplayFile = slotFile;
      }

      if (swapped) {
        _replacementFilesByOriginal.remove(originalName);
        _replacementThumbsByOriginal.remove(originalName);
      } else {
        // Swap not possible on this device — keep the original and overlay
        // the replacement, as before.
        _replacementFilesByOriginal[originalName] = slotDisplayFile;
        _knownDeviceFileNames.add(replacementFilename);
      }

      final replacementType = swapped ? 'recapture-swap' : 'recapture';
      _replacementInfoByOriginal[originalName] = _ReplacementRecordInfo(
        originalFilename: originalName,
        replacementFilename: replacementFilename,
        replacementLocalPath: slotDisplayFile.path,
        replacementType: replacementType,
      );
      _originalNameByReplacement[replacementFilename] = originalName;

      // Show the pulled JPEG now. Image.file downsamples it for the tile and
      // avoids the old full JPEG decode -> PNG encode -> PNG decode round trip.
      if (mounted) {
        setState(() => statusMsg = 'Replacement loaded; saving…');
      }

      await UploadStatsDB().insertReplacementRecord(
        deviceId: auth.deviceId.value,
        sequenceIndex: _sequenceIndexByName[originalName] ?? -1,
        dateKey: dateKey,
        originalFilename: originalName,
        replacementFilename: replacementFilename,
        replacementLocalPath: slotDisplayFile.path,
        scanningOpr: auth.username.value,
        replacementType: replacementType,
      );
      if (replacementBinding != null) {
        await UploadStatsDB().saveColorBinding(auth.deviceId.value, originalName, replacementBinding.toJson());
        await ColorReworkStore.complete(
          auth.deviceId.value,
          'capture-slot:$originalName',
          staged: durableReplacement,
        );
      }
      await _auditOrNull?.logReplacement(
        event: 'created',
        originalFilename: originalName,
        replacementFilename: replacementFilename,
        replacementType: replacementType,
        boxDetails: _boxSession?.activeBox.value?.boxDetails ?? '',
      );

      await _bringAppToFront();

      if (mounted) {
        _openPreviewForSlot(
          originalName,
          File(p.join(_tempDir?.path ?? '', originalName)),
        );
        setState(() {
          statusMsg =
              '✅ Replacement saved for slot #${(_sequenceIndexByName[originalName] ?? 0) + 1}.';
        });
      }
    } catch (e) {
      print('⚠️ Recapture flow failed: $e');
      await _bringAppToFront();
      if (mounted) {
        setState(() {
          statusMsg = 'Recapture failed for $originalName.';
        });
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Recapture failed: $e')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isWaitingForRecapture = false;
          _recaptureSlotOriginalName = null;
        });
      }
    }
  }

  Future<List<String>> _listDeviceImageNames() async =>
      (await _listDeviceImageNamesOrNull()) ?? const [];

  /// Like [_listDeviceImageNames], but null when the phone did not answer on
  /// any candidate path, so callers can tell "unreachable" from "empty".
  Future<List<String>?> _listDeviceImageNamesOrNull() async {
    final possiblePaths = [
      _workingPath,
      '/storage/emulated/0/DCIM/Camera',
      '/sdcard/DCIM/Camera',
    ].whereType<String>().toList();

    for (final path in possiblePaths) {
      try {
        final result = await Process.run(adbPath, ['shell', 'ls', '-1', path]);
        final output = result.stdout.toString().trim();
        if (!deviceAnsweredListing(exitCode: result.exitCode, stdout: output)) {
          continue;
        }

        _workingPath = path;
        return output
            .split('\n')
            .map((f) => f.trim().replaceAll('\r', ''))
            .where((f) => f.isNotEmpty)
            .where((f) {
              final name = f.toLowerCase();
              return name.endsWith('.jpg') ||
                  name.endsWith('.jpeg') ||
                  name.endsWith('.png') ||
                  name.endsWith('.heic') ||
                  name.endsWith('.heif') ||
                  name.endsWith('.webp');
            })
            .toList();
      } catch (e) {
        print('⚠️ Failed listing device images from $path: $e');
      }
    }

    return null;
  }

  Future<String?> _waitForNewCapture(
    Set<String> beforeNames, {
    Duration timeout = const Duration(minutes: 2),
    Duration pollInterval = const Duration(seconds: 2),
    bool Function()? isCancelled,
  }) async {
    final sw = Stopwatch()..start();

    while (sw.elapsed < timeout) {
      if (isCancelled?.call() ?? false) return null;
      final current = await _listDeviceImageNames();
      final added = current
          .where((name) => !beforeNames.contains(name))
          .toList();
      if (added.isNotEmpty) {
        added.sort();
        final newest = added.last;
        print('✅ New capture detected: $newest');
        return newest;
      }
      await Future.delayed(pollInterval);
    }

    print('⚠️ Timed out waiting for new capture on device.');
    return null;
  }

  Future<File?> _pullSingleFile(String name, {Directory? targetDir}) async {
    if (!AdbDeviceService.isSafeDeviceName(name)) {
      print('⚠️ Refusing to pull unsafe device file name: $name');
      return null;
    }
    if ((_workingPath ?? '').isEmpty) {
      final names = await _listDeviceImageNames();
      if (names.isEmpty || (_workingPath ?? '').isEmpty) {
        return null;
      }
    }

    final resolvedTargetDir = targetDir ?? await _ensureGalleryCacheDir();
    final localPath = p.join(resolvedTargetDir.path, name);
    final remoteFile = '$_workingPath/$name';

    try {
      final pull = await Process.run(adbPath, ['pull', remoteFile, localPath]);
      if (pull.exitCode != 0) {
        print('⚠️ adb pull failed for $name: ${pull.stderr}');
        return null;
      }

      final file = File(localPath);
      if (!file.existsSync()) {
        print('⚠️ Pulled replacement file missing locally: $localPath');
        return null;
      }
      return file;
    } catch (e) {
      print('⚠️ Failed to pull replacement file $name: $e');
      return null;
    }
  }

  // --- Transfer preparation: replacements, original copies, selection ------

  Future<File> _materializeReplacementForSlot(
    String originalName,
    File replacementFile, {
    required Directory targetDir,
  }) async {
    final slotFile = File(p.join(targetDir.path, originalName));
    if (slotFile.existsSync()) {
      await slotFile.delete();
    }
    await replacementFile.copy(slotFile.path);
    return slotFile;
  }

  Future<List<File>> _resolveOrderedFilesForTransfer(
    List<String> orderedOriginalNames,
    Map<String, File> loadedByName, {
    required String contextLabel,
    required Directory targetDir,
  }) async {
    final originalsToLoad = orderedOriginalNames
        .where((name) => !_replacementFilesByOriginal.containsKey(name))
        .toList();

    final originals = await _pullFilesForNames(
      originalsToLoad,
      loadedByName,
      contextLabel: contextLabel,
      targetDir: targetDir,
    );

    final originalsByName = <String, File>{};
    for (final file in originals) {
      originalsByName[p.basename(file.path)] = file;
    }

    final resolved = <File>[];
    for (final originalName in orderedOriginalNames) {
      final replacement = _replacementFilesByOriginal[originalName];
      if (replacement != null) {
        resolved.add(
          await _materializeReplacementForSlot(
            originalName,
            replacement,
            targetDir: targetDir,
          ),
        );
        continue;
      }
      final original =
          originalsByName[originalName] ?? loadedByName[originalName];
      if (original != null) {
        resolved.add(original);
      }
    }

    if (resolved.length != orderedOriginalNames.length) {
      throw Exception(
        'Sequence mismatch during prepare: expected ${orderedOriginalNames.length}, got ${resolved.length}.',
      );
    }
    return resolved;
  }

  String _baseNameForOriginalFilename(String name) {
    final reg = RegExp(r'(\d{8})_(\d{6})');
    final match = reg.firstMatch(name);
    if (match == null) return "";

    final datePart = match.group(1)!;
    final timePart = match.group(2)!;
    final year = datePart.substring(0, 4);
    final month = datePart.substring(4, 6);
    final day = datePart.substring(6, 8);
    final hour = timePart.substring(0, 2);
    final minute = timePart.substring(2, 4);
    final second = timePart.substring(4, 6);

    final formatted = "${year}${month}${day}_${hour}${minute}${second}";
    return "${auth.deviceId.value}_IMG_${formatted}";
  }

  Future<List<File>> _pullFilesForNames(
    List<String> names,
    Map<String, File> loadedByName, {
    required String contextLabel,
    required Directory targetDir,
  }) async {
    final result = <File>[];
    final seen = <String>{};

    if (_workingPath == null) {
      print("⚠️ _workingPath is null. Cannot pull files for $contextLabel.");
      return result;
    }

    if (!await targetDir.exists()) {
      await targetDir.create(recursive: true);
    }

    final toPull = <String>[];
    int alreadyLoaded = 0;

    for (final name in names) {
      if (!seen.add(name)) continue;

      if (loadedByName.containsKey(name)) {
        result.add(loadedByName[name]!);
        alreadyLoaded++;
      } else {
        toPull.add(name);
      }
    }

    print(
      "📦 [$contextLabel] ${result.length} already loaded, ${toPull.length} need pulling.",
    );

    final totalPreparing = alreadyLoaded + toPull.length;
    if (totalPreparing > 0) {
      u.updatePreparing(
        total: totalPreparing,
        current: alreadyLoaded,
        label: "Preparing files for upload…",
      );
    }

    if (toPull.isEmpty) {
      print(
        "📦 [$contextLabel] total files prepared for transfer: ${result.length}",
      );
      return result;
    }

    const maxConcurrentPull = 4;
    int preparedCount = alreadyLoaded;

    for (int i = 0; i < toPull.length; i += maxConcurrentPull) {
      final batch = toPull.skip(i).take(maxConcurrentPull).toList();

      await Future.wait(
        batch.map((name) async {
          final remoteFile = '$_workingPath/$name';
          final localPath = '${targetDir.path}/$name';

          try {
            print(
              "⬇️ [$contextLabel] pulling extra file $remoteFile -> $localPath",
            );
            final pull = await Process.run(adbPath, [
              'pull',
              remoteFile,
              localPath,
            ]);

            if (pull.exitCode == 0) {
              final f = File(localPath);
              if (f.existsSync()) {
                result.add(f);
                print(
                  "✅ [$contextLabel] extra file ready for transfer: $localPath",
                );
              } else {
                print(
                  "⚠️ [$contextLabel] pulled file missing locally: $localPath",
                );
              }
            } else {
              print(
                "⚠️ [$contextLabel] adb pull failed ($name), exitCode=${pull.exitCode}",
              );
            }
          } catch (e) {
            print("⚠️ [$contextLabel] error pulling $name: $e");
          } finally {
            preparedCount++;
            u.updatePreparing(current: preparedCount);
          }
        }),
      );
    }

    print(
      "📦 [$contextLabel] total files prepared for transfer: ${result.length}",
    );
    return result;
  }

  Future<File> _uniqueOriginalCopyTarget(
    Directory originalsDir,
    String name,
  ) async {
    final candidate = File(p.join(originalsDir.path, name));
    if (!await candidate.exists()) {
      return candidate;
    }

    final base = p.basenameWithoutExtension(name);
    final ext = p.extension(name);
    int counter = 1;
    while (true) {
      final suffix = counter.toString().padLeft(3, '0');
      final next = File(
        p.join(originalsDir.path, '${base}_original_$suffix$ext'),
      );
      if (!await next.exists()) {
        return next;
      }
      counter++;
    }
  }

  Future<void> _preserveOriginalCopiesForTransfer(
    List<String> orderedOriginalNames,
    Map<String, File> loadedByName, {
    required Directory stagingDir,
  }) async {
    if (s.destinationPath.value.isEmpty) {
      return;
    }

    final originalsToPreserve =
        orderedOriginalNames
            .where((name) => _replacementFilesByOriginal.containsKey(name))
            .toSet()
            .toList()
          ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    if (originalsToPreserve.isEmpty) {
      return;
    }

    final dailyDestination =
        await TransferDestinationService.ensureDirectoryForDate(
          s.destinationPath.value,
          DateTime.now(),
        );
    final originalsDir = Directory(
      p.join(dailyDestination.path, 'original_images'),
    );
    if (!await originalsDir.exists()) {
      await originalsDir.create(recursive: true);
    }

    u.updatePreparing(
      total: originalsToPreserve.length,
      current: 0,
      label: 'Preserving original copies for replaced images…',
    );

    final originals = await _pullFilesForNames(
      originalsToPreserve,
      loadedByName,
      contextLabel: 'Preserve originals',
      targetDir: stagingDir,
    );

    int copied = 0;
    for (final file in originals) {
      final target = await _uniqueOriginalCopyTarget(
        originalsDir,
        p.basename(file.path),
      );
      await file.copy(target.path);
      copied++;
      u.updatePreparing(
        total: originalsToPreserve.length,
        current: copied,
        label: 'Preserving original copies for replaced images…',
      );
    }
  }

  _TransferSelectionSnapshot _createTransferSelectionSnapshot() {
    if (_globalFullSelection) {
      return _TransferSelectionSnapshot(
        orderedOriginalNames: _getOrderedTransferSequenceNames(),
        label: 'All dates',
      );
    }

    if (_fullDateKeySelection != null) {
      final dateKey = _fullDateKeySelection!;
      return _TransferSelectionSnapshot(
        orderedOriginalNames: _dedupeTransferableNames(
          _allFileNamesByDate[dateKey] ?? const <String>[],
        ),
        label: dateKey,
      );
    }

    final selectedOriginalNames = _dedupeTransferableNames(
      c.selectedImages.map((file) => p.basename(file.path)),
    ).toSet();
    return _TransferSelectionSnapshot(
      orderedOriginalNames: _getOrderedTransferSequenceNames()
          .where((name) => selectedOriginalNames.contains(name))
          .toList(),
      label: 'Manual selection',
    );
  }

  Future<List<File>> _prepareFilesForTransfer(
    _TransferSelectionSnapshot snapshot,
  ) async {
    _preparingTransfer = true;
    try {
      final transferStageDir = await _prepareFreshTransferStageDir();
      final uploadedBaseNames = s.includeUploaded.value
          ? <String>{}
          : await UploadStatsDB().getUploadedBaseNames(auth.deviceId.value);

      bool shouldSkipOriginalName(String originalName) {
        if (s.includeUploaded.value) return false;
        final base = _baseNameForOriginalFilename(originalName);
        return base.isNotEmpty && uploadedBaseNames.contains(base);
      }

      final loadedByName = <String, File>{};
      for (final group in c.groupedImages.values) {
        for (final entry in group) {
          loadedByName[p.basename(entry.file.path)] = entry.file;
        }
      }

      final orderedNames = snapshot.orderedOriginalNames
          .where((name) => !shouldSkipOriginalName(name))
          .toList();

      print(
        "📤 Preparing transfer snapshot (${snapshot.label}) with ${snapshot.orderedOriginalNames.length} item(s); "
        "${orderedNames.length} remain after skipping previously uploaded files.",
      );

      if (orderedNames.isEmpty) {
        u.finishPreparing();
        return const <File>[];
      }

      await _preserveOriginalCopiesForTransfer(
        orderedNames,
        loadedByName,
        stagingDir: transferStageDir,
      );

      u.updatePreparing(
        total: orderedNames.length,
        current: 0,
        label: 'Preparing ${snapshot.label.toLowerCase()} for upload…',
      );

      return await _resolveOrderedFilesForTransfer(
        orderedNames,
        loadedByName,
        contextLabel: snapshot.label,
        targetDir: transferStageDir,
      );
    } finally {
      _preparingTransfer = false;
    }
  }

  void _selectAllForAllDates() {
    print("✅ Global 'Select All' requested (no pulling at this stage).");
    _globalFullSelection = true;
    _fullDateKeySelection = null;

    final visibleFiles = c.groupedImages.values
        .expand((group) => group.map((entry) => entry.file))
        .toList();
    c.selectedImages.assignAll(visibleFiles);

    print(
      "📦 Global select-all highlighted ${visibleFiles.length} visible image(s). "
      "Logical total for transfer: ${_getTotalDeviceImageCount()}",
    );
  }

  void _selectAllForDate(String dateKey) {
    print("✅ 'Select All For This Date' requested for $dateKey.");

    final visibleGroup = c.groupedImages[dateKey] ?? [];
    final groupFiles = visibleGroup.map((e) => e.file).toSet();
    final currentlySelected = c.selectedImages.toSet();
    final allSelected =
        groupFiles.isNotEmpty &&
        groupFiles.every((file) => currentlySelected.contains(file));

    _globalFullSelection = false;

    if (allSelected) {
      c.selectedImages.removeWhere((file) => groupFiles.contains(file));
      _fullDateKeySelection = null;
      print(
        "📅 Date $dateKey: deselected ${visibleGroup.length} visible image(s).",
      );
    } else {
      final newSelection = currentlySelected.union(groupFiles);
      c.selectedImages.assignAll(newSelection.toList());
      _fullDateKeySelection = dateKey;
      print(
        "📅 Date $dateKey: selected ${visibleGroup.length} visible image(s).",
      );
    }

    final selectedForDate = c.selectedImages
        .where((f) => groupFiles.contains(f))
        .length;
    final logicalTotal = _dateTotals[dateKey] ?? visibleGroup.length;
    print(
      "📅 Date $dateKey: $selectedForDate/${visibleGroup.length} visible image(s) selected. "
      "Logical total for transfer: $logicalTotal",
    );

    if (mounted) {
      setState(() {});
    }
  }

  bool _areAllSelectedForDate(String dateKey) {
    final visibleGroup = c.groupedImages[dateKey] ?? [];
    if (visibleGroup.isEmpty) return false;

    final groupFiles = visibleGroup.map((e) => e.file).toSet();
    final currentlySelected = c.selectedImages.toSet();
    return groupFiles.every((file) => currentlySelected.contains(file));
  }

  Future<bool?> _askIncludeUploadedDialog() async {
    return showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('Previously uploaded images'),
          content: const Text(
            'Some of the selected images may have been uploaded before.\n\n'
            'How would you like to proceed?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('ALL Images'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Only NEW images'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _onSendSelectedPressed() async {
    var selectedLogicalCount = _getSelectedCount();
    print(
      "📤 'Transfer Selected' pressed with logical selection of $selectedLogicalCount image(s).",
    );

    if (selectedLogicalCount == 0 && _getTotalDeviceImageCount() > 0) {
      print("No manual selection; auto-selecting all images for transfer.");
      _selectAllForAllDates();
      selectedLogicalCount = _getSelectedCount();
      if (mounted) {
        setState(() {});
      }
    }

    if (selectedLogicalCount == 0) {
      print("⚠️ No images selected. Transfer aborted.");
      return;
    }

    if (u.isUploading.value) {
      print("⚠️ Upload already in progress. Ignoring new transfer request.");
      return;
    }

    final includeUploaded = await _askIncludeUploadedDialog();

    if (includeUploaded == null) {
      print("ℹ️ User cancelled transfer after include/exclude dialog.");
      return;
    }

    s.includeUploaded.value = includeUploaded;
    print(
      "⚙️ includeUploaded flag set to $includeUploaded "
      "(true = include existing, false = only NEW).",
    );

    final snapshot = _createTransferSelectionSnapshot();
    print(
      "📦 Opening UploaderPage with deferred file preparation for ${snapshot.label}.",
    );
    Get.dialog(
      UploaderPage(prepareFiles: () => _prepareFilesForTransfer(snapshot)),
      barrierDismissible: false,
      barrierColor: Colors.black.withOpacity(0.25),
    );
  }

  // --- Logout, teardown and folder management ------------------------------

  Future<void> _confirmLogout(BuildContext context) async {
    print("🚪 Logout requested.");
    final shouldLogout = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Logout'),
        content: const Text(
          'Are you sure you want to logout? This will stop loading images and clear the cache.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Logout'),
          ),
        ],
      ),
    );

    if (shouldLogout == true) {
      print("✅ User confirmed logout. Cancelling loads & cleaning temp...");
      await _teardownGallery(deleteCache: true);
      print("🧹 Gallery state cleared. Logging out.");
      // auth.logout() clears the session (currentUser, deviceId) and
      // navigates to the login page — this also re-evaluates the users store.
      await auth.logout();
    } else {
      print("ℹ️ Logout cancelled.");
    }
  }

  /// Cancels loading and clears gallery state. Shared by logout and
  /// mode-switch. [deleteCache] controls the pulled-image cache: logout
  /// removes it (next operator/device must not inherit it); a mode switch
  /// keeps it so returning to Normal Mode skips the full device re-pull.
  Future<void> _teardownGallery({required bool deleteCache}) async {
    // Box mode: leaving the gallery ends the active box session (state is
    // DB-backed; reopening the box resumes it).
    _boxSession?.closeActiveBox();
    _cancelLoading = true;
    _liveSyncTimer?.cancel();
    _globalFullSelection = false;
    _fullDateKeySelection = null;
    _replacementFilesByOriginal.clear();
    _replacementThumbsByOriginal.clear();
    _replacementInfoByOriginal.clear();
    _originalNameByReplacement.clear();
    c.groupedImages.clear();
    c.selectedImages.clear();
    c.setPreview(null);

    while (_preparingTransfer) {
      print("⏳ Waiting for transfer-prep to finish before cleanup...");
      await Future.delayed(const Duration(milliseconds: 200));
    }

    if (deleteCache) {
      await _cleanupTempFiles();
    } else {
      await _cleanupTransferStagingDir();
    }
  }

  /// Box mode: closes the current folder and starts the next one. Pending
  /// device photos are force-synced FIRST so anything captured up to this
  /// moment is assigned to the OLD folder (kills the live-sync poll race).
  /// Makes [folder] the active one — new captures land there from now on.
  /// Drains any in-flight capture into the CURRENT active folder first
  /// (same reasoning as _onNewFolderPressed below): a shutter fired just
  /// before switching is detected asynchronously by live-sync, so without
  /// this drain it could otherwise land in the newly-active folder instead
  /// of the one that was active when the shutter actually fired.
  Future<void> _activateFolder(CaptureFolder folder) async {
    final session = _boxSession;
    if (session == null || session.activeFolder.value?.id == folder.id) return;
    await _syncNewDeviceImages(silent: true);
    await session.setActiveFolder(folder);
    if (mounted) setState(() {});
  }

  Future<void> _onNewFolderPressed() async {
    final session = _boxSession;
    if (session == null || !_isBoxMode) return;
    await _syncNewDeviceImages(silent: true);

    final box = session.activeBox.value!;
    // Modal dialog, NOT a page route: pushing a page animated the heavy
    // gallery on open and close.
    // Release the shutter hotkey while the form is open so its key (Space,
    // Delete, …) types normally into the text fields instead of firing the
    // shutter; re-armed in the finally.
    CaptureFolder? draft;
    await ShutterHotkeyService.instance.suspend();
    try {
      draft = await Get.dialog<CaptureFolder>(
        FolderMetadataDialog(
          // Carry-over is deliberately OFF: every new folder starts blank, so
          // nothing from the previous folder can be carried into this one by
          // accident. To restore it, read `session.activeFolder.value` back
          // into a `prev` local and pass `prev?.<field>` here again.
          initial: CaptureFolder(boxId: box.id),
          heading: 'Folder ${session.foldersOfActiveBox.length + 1} metadata',
          boxDetails: box.boxDetails,
          template: session.activeTemplate,
        ),
        barrierDismissible: false,
      );
    } finally {
      await ShutterHotkeyService.instance.resume();
    }
    if (draft == null) return; // cancelled — keep capturing into the old folder

    try {
      final created = await session.createFolder(draft);
      if (mounted) {
        setState(() {});
        // Same treatment a new capture gets: a folder created below the fold is
        // invisible until the operator scrolls, and it is now the active one -
        // every following shutter press lands in it, so it is exactly what they
        // need to be looking at.
        _scrollOnceTo(_folderCardKey(created.id), fallbackToEnd: true);
      }
    } catch (e) {
      showAppSnackBar(
        'Error',
        'Could not create the folder: $e',
        backgroundColor: Get.theme.colorScheme.error,
        colorText: Get.theme.colorScheme.onError,
        width: null,
      );
    }
  }

  /// Box mode: re-opens the metadata form for any folder of the open box
  /// (metadata is editable any time while the box is open; destination names
  /// are computed at transfer, so edits never go stale).
  Future<void> _editFolder(CaptureFolder folder) async {
    final session = _boxSession;
    if (session == null || session.activeBox.value == null) return;
    // Release the shutter hotkey while editing so its key types normally into
    // the form's text fields instead of firing the shutter (see
    // _onNewFolderPressed); re-armed in the finally.
    CaptureFolder? edited;
    await ShutterHotkeyService.instance.suspend();
    try {
      edited = await Get.dialog<CaptureFolder>(
        FolderMetadataDialog(
          initial: folder,
          heading: 'Edit folder ${folder.folderSeq}',
          boxDetails: session.activeBox.value!.boxDetails,
          template: session.activeTemplate,
        ),
        barrierDismissible: false,
      );
    } finally {
      await ShutterHotkeyService.instance.resume();
    }
    if (edited == null) return;
    try {
      await session.updateFolder(edited);
      if (mounted) setState(() {});
    } catch (e) {
      showAppSnackBar(
        'Error',
        'Could not save the folder: $e',
        backgroundColor: Get.theme.colorScheme.error,
        colorText: Get.theme.colorScheme.onError,
        width: null,
      );
    }
  }

  /// Box mode: deletes an empty, non-active folder after confirmation. The
  /// button that reaches this is disabled unless the folder looks empty; the
  /// controller and the DB layer re-check, so this is only the operator's
  /// confirmation step.
  Future<void> _deleteFolder(CaptureFolder folder) async {
    final session = _boxSession;
    if (session == null) return;
    final volumeText = (folder.volume ?? '').trim().isEmpty
        ? '(no volume)'
        : folder.volume!.trim();
    // Same reason as _editFolder: the dialog takes focus, and an un-suspended
    // shutter key would fire the phone while it is up.
    bool? confirmed;
    await ShutterHotkeyService.instance.suspend();
    try {
      confirmed = await Get.dialog<bool>(
        AlertDialog(
          title: const Text('Delete this folder?'),
          content: Text(
            'Folder ${folder.folderSeq} - $volumeText\n\n'
            'It has no images. Its metadata is removed too. '
            'This cannot be undone.',
          ),
          actions: [
            TextButton(
              onPressed: () => Get.back(result: false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Get.back(result: true),
              style: FilledButton.styleFrom(
                backgroundColor: Get.theme.colorScheme.error,
                foregroundColor: Get.theme.colorScheme.onError,
              ),
              child: const Text('Delete'),
            ),
          ],
        ),
        barrierDismissible: false,
      );
    } finally {
      await ShutterHotkeyService.instance.resume();
    }
    if (confirmed != true) return;
    try {
      await session.deleteFolder(folder);
      if (mounted) setState(() {});
      showAppSnackBar('Deleted', 'Folder ${folder.folderSeq} is gone.');
    } catch (e) {
      showAppSnackBar(
        'Not deleted',
        e is StateError ? e.message : 'Could not delete the folder: $e',
        backgroundColor: Get.theme.colorScheme.error,
        colorText: Get.theme.colorScheme.onError,
        width: null,
      );
    }
  }

  // --- Widgets: preview panel, image tiles, grids and folder sections ------

  Widget _buildPreviewPanel() {
    return Obx(() {
      final previewFile = c.previewFile.value;
      // Part of the image keys below: a swap recapture changes the BYTES under
      // a stable path, so the key must change too or the (path-keyed) Image
      // widget keeps showing the superseded pixels from its resolved stream.
      final previewReplacement = previewFile == null
          ? ''
          : (_replacementInfoByOriginal[_canonicalTransferName(
                  p.basename(previewFile.path),
                )]?.replacementFilename ??
                '');

      return Container(
        decoration: BoxDecoration(
          // Grid sits to the RIGHT of the viewer now (mirror pane to the left).
          border: Border(
            right: BorderSide(
              color: Theme.of(context).colorScheme.outlineVariant,
            ),
          ),
          color: Theme.of(context).colorScheme.surfaceContainerLow,
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: previewFile == null || !_previewExists(previewFile)
              ? const Center(
                  child: Text(
                    'Select an image to inspect it in detail.',
                    textAlign: TextAlign.center,
                  ),
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Image Viewer',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 8),
                    if (_isWaitingForRecapture &&
                        _recaptureSlotOriginalName != null) ...[
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        backgroundColor: Theme.of(
                          context,
                        ).colorScheme.surfaceContainerHighest,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Waiting for device capture to finish for $_recaptureSlotOriginalName',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          width: double.infinity,
                          color: Colors.black,
                          child: InteractiveViewer(
                            minScale: 0.5,
                            maxScale: 6,
                            child: Center(
                              // Two decodes of the same file: the 512px layer
                              // paints in a few hundred ms; the sharp
                              // kPreviewCacheWidth decode of the ~50MP source
                              // takes seconds and simply replaces it on top
                              // when ready. Without the fast layer the panel
                              // sat on the previous image for the whole sharp
                              // decode after a recapture.
                              child: Stack(
                                fit: StackFit.passthrough,
                                children: [
                                  Image.file(
                                    previewFile,
                                    key: ValueKey(
                                      '${previewFile.path}:$previewReplacement:lo',
                                    ),
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.medium,
                                    cacheWidth: 512,
                                    errorBuilder: (_, __, ___) =>
                                        const SizedBox.shrink(),
                                  ),
                                  Image.file(
                                    previewFile,
                                    key: ValueKey(
                                      '${previewFile.path}:$previewReplacement:hi',
                                    ),
                                    fit: BoxFit.contain,
                                    filterQuality: FilterQuality.high,
                                    // Cap the decode: the source photos are
                                    // ~50MP (~200MB decoded). 2560px keeps
                                    // zoomed text readable at ~1/8 the
                                    // memory/decode cost.
                                    cacheWidth: kPreviewCacheWidth,
                                    errorBuilder: (_, __, ___) => const Center(
                                      child: Text(
                                        'Unable to load image preview.',
                                        style: TextStyle(color: Colors.white),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
        ),
      );
    });
  }

  Widget _buildImageTile(String groupKey, ImageEntry imageEntry, int i) {
    final cs = Theme.of(context).colorScheme;
    final lw = LifewoodColors.of(context);
    final file = imageEntry.file;
    final originalName = p.basename(file.path);
    final slotOriginalName = _canonicalTransferName(originalName);
    final replacementInfo = _replacementInfoForTile(originalName);
    final thumb = _thumbForSlot(slotOriginalName, imageEntry);
    final isSelected = c.selectedImages.contains(file);
    final isReplaced = replacementInfo != null;
    final isPrimaryReplacementTile = _isReplacementPrimaryTile(originalName);
    final displayFile = _displayFileForSlot(slotOriginalName, file);
    final isPreviewed = c.previewFile.value?.path == displayFile.path;
    final sequenceLabel = ((_sequenceIndexByName[slotOriginalName] ?? i) + 1)
        .toString();

    return GestureDetector(
      key: _captureTileKey(originalName),
      onTap: () {
        // In capture view (no inline viewer) this only marks the tile as
        // selected/VIEWING — the image shows in the viewer once in QC view.
        _openPreviewForSlot(slotOriginalName, file);
        _viewerFocusNode.requestFocus();
        if (mounted) setState(() {});
      },
      // Box mode: selection has no purpose (transfer is box-level).
      onDoubleTap: _isBoxMode ? null : () => _toggleSelectionFor(file),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: isSelected
              ? lw.selectedContainer
              : isPreviewed
              ? lw.viewingContainer
              : Colors.transparent,
          border: Border.all(
            color: isSelected
                ? lw.selected
                : isPreviewed
                ? lw.viewing
                : cs.outline,
            width: isSelected ? 3 : (isPreviewed ? 2 : 1),
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (isReplaced)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.file(
                  displayFile,
                  key: ValueKey(
                    '${displayFile.path}:${replacementInfo.replacementFilename}',
                  ),
                  cacheWidth: 512,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                  errorBuilder: (_, __, ___) =>
                      const Center(child: Icon(Icons.broken_image_outlined)),
                ),
              )
            else if (thumb != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Image.memory(
                  thumb,
                  fit: BoxFit.cover,
                  filterQuality: FilterQuality.medium,
                ),
              )
            else
              const Center(child: CircularProgressIndicator(strokeWidth: 1.5)),
            Positioned(
              top: 6,
              left: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '#$sequenceLabel',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            if (isReplaced)
              Positioned(
                top: 6,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: lw.warning,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    isPrimaryReplacementTile ? 'REPLACED' : 'REPLACEMENT',
                    style: TextStyle(
                      color: lw.onWarning,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            if (isPreviewed)
              Positioned(
                top: isReplaced ? 34 : 6,
                right: 6,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: lw.viewing.withOpacity(0.9),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    'VIEWING',
                    style: TextStyle(
                      color: lw.onInfo,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            Positioned(
              left: 6,
              right: 6,
              bottom: 6,
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _linkedLabelForTile(originalName),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Delete-then-select order matches Rework Mode's tile layout.
                  Material(
                    color: Colors.white70,
                    borderRadius: BorderRadius.circular(20),
                    child: IconButton(
                      tooltip: 'Delete this image from the phone',
                      icon: Icon(Icons.delete_outline, color: cs.error),
                      onPressed: (_isWaitingForRecapture || _isPulling)
                          ? null
                          : () =>
                                _confirmDeleteImage(slotOriginalName, groupKey),
                    ),
                  ),
                  const SizedBox(width: 6),
                  // Box mode: no per-image selection — transfer is box-level.
                  if (!_isBoxMode) ...[
                    Material(
                      color: Colors.white70,
                      borderRadius: BorderRadius.circular(20),
                      child: IconButton(
                        tooltip: isSelected
                            ? 'Remove from selection'
                            : 'Select for transfer',
                        icon: Icon(
                          isSelected
                              ? Icons.check_circle
                              : Icons.radio_button_unchecked,
                          // Castleton (not Saffron) for the icon: Saffron
                          // on the white pill fails icon contrast (1.9:1).
                          color: isSelected ? cs.primary : Colors.black87,
                        ),
                        onPressed: () => _toggleSelectionFor(file),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Material(
                    color: Colors.white70,
                    borderRadius: BorderRadius.circular(20),
                    child: IconButton(
                      tooltip: 'Recapture and replace this slot',
                      icon: const Icon(Icons.camera_alt),
                      onPressed: _isWaitingForRecapture
                          ? null
                          : () => _startRecaptureForSlot(
                              slotOriginalName,
                              groupKey,
                            ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGalleryList() {
    return Obx(() {
      final _ = c.selectedImages.length;
      final __ = c.previewFile.value?.path;

      if (c.groupedImages.isEmpty) {
        return const Center(child: Text("No images found"));
      }
      return ListView.builder(
        controller: _galleryScrollController,
        itemCount: c.groupedImages.length,
        itemBuilder: (context, index) {
          final entry = c.groupedImages.entries.elementAt(index);
          final groupKey = entry.key;
          final groupList = entry.value
              .where(
                (imageEntry) => !_originalNameByReplacement.containsKey(
                  p.basename(imageEntry.file.path),
                ),
              )
              .toList();
          final totalForDate = _dateTotals[groupKey] ?? groupList.length;

          return Card(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Padding(
              padding: const EdgeInsets.all(8.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        "$groupKey (Total: $totalForDate images)",
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _selectAllForDate(groupKey),
                        icon: Icon(
                          _areAllSelectedForDate(groupKey)
                              ? Icons.check_circle
                              : Icons.check_circle_outline,
                          size: 18,
                        ),
                        label: Text(
                          _areAllSelectedForDate(groupKey)
                              ? 'Deselect All For This Date'
                              : 'Select All For This Date',
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  GridView.builder(
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: groupList.length,
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          // Width-adaptive: ~4 columns in the narrower
                          // right-hand grid, more on wide monitors. Scaled with
                          // kBoxGridColumns (220 * 3/4) so a thumbnail is the
                          // same size in both grids - they sit on the same
                          // screen and a size difference reads as a bug.
                          maxCrossAxisExtent: 165,
                          crossAxisSpacing: 12,
                          mainAxisSpacing: 12,
                          childAspectRatio: kCaptureAspectRatio,
                        ),
                    itemBuilder: (context, i) =>
                        _buildImageTile(groupKey, groupList[i], i),
                  ),
                ],
              ),
            ),
          );
        },
      );
    });
  }

  /// Box mode: the gallery grouped into one clearly separated SECTION per
  /// folder (folder_seq order) instead of date cards — each with a rich
  /// header (file number, image count, Complete/Draft chip, per-folder Edit,
  /// "Capturing here" marker, and a "Make Active" action for any inactive
  /// folder so operators can freely choose where new captures land). Images
  /// that predate the box or belong to another box are never loaded at all
  /// (see loadDcimImages' box-mode scoping), so there is nothing else to
  /// show here. The legacy date-grouped builder above is untouched (keying
  /// OFF renders exactly as today).
  Widget _buildBoxGalleryList() {
    return Obx(() {
      final session = _boxSession!;
      final folders = session.foldersOfActiveBox.toList();
      final activeFolderId = session.activeFolder.value?.id;
      // Rx reads that must trigger rebuilds: assignment changes bump the
      // image counter; thumbnails/preview arrive via the gallery controller.
      final _ = session.activeFolderImageCount.value;
      final __ = c.previewFile.value?.path;
      final ___ = c.groupedImages.length;

      // Loaded tiles by device filename (replacement overlays excluded, same
      // rule as the date builder).
      final entriesByName = <String, ImageEntry>{};
      for (final group in c.groupedImages.values) {
        for (final e in group) {
          final name = p.basename(e.file.path);
          if (_originalNameByReplacement.containsKey(name)) continue;
          entriesByName[name] = e;
        }
      }

      final assignments = session.assignments; // filename → folderId
      final assignedCountByFolder = <int, int>{};
      for (final id in assignments.values) {
        assignedCountByFolder[id] = (assignedCountByFolder[id] ?? 0) + 1;
      }

      // Every name reaching this point was loaded because it's assigned to
      // the box (see loadDcimImages' box-mode scoping) or was just captured
      // and is about to be (assignNewImage runs right after the tile is
      // added) — so an unmapped name here is a brief in-flight-assignment
      // gap, not a foreign image; it simply doesn't render until the
      // assignment completes moments later (self-heals via the Obx above).
      final entriesByFolder = <int, List<ImageEntry>>{};
      final sortedNames = entriesByName.keys.toList()
        ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
      for (final name in sortedNames) {
        final folderId = assignments[name];
        if (folderId != null) {
          entriesByFolder
              .putIfAbsent(folderId, () => [])
              .add(entriesByName[name]!);
        }
      }

      if (folders.isEmpty && entriesByName.isEmpty) {
        return const Center(child: Text("No images found"));
      }

      return ListView(
        controller: _galleryScrollController,
        children: [
          for (final f in folders)
            _buildFolderSection(
              f,
              entriesByFolder[f.id] ?? const <ImageEntry>[],
              assignedCount: assignedCountByFolder[f.id] ?? 0,
              isActive: f.id == activeFolderId,
            ),
        ],
      );
    });
  }

  Widget _buildFolderSection(
    CaptureFolder folder,
    List<ImageEntry> entries, {
    required int assignedCount,
    required bool isActive,
  }) {
    final complete = _boxSession!.activeTemplate.isCompleteOf(folder);
    final volumeText = (folder.volume ?? '').trim().isEmpty
        ? '(no volume)'
        : folder.volume!.trim();
    return Card(
      key: _folderCardKey(folder.id),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: isActive
            ? BorderSide(
                color: Theme.of(context).colorScheme.primary,
                width: 3.5,
              )
            : BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(8.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      Text(
                        "Folder ${folder.folderSeq} · $volumeText · $assignedCount images",
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: complete
                              ? LifewoodColors.of(context).successContainer
                              : LifewoodColors.of(context).warningContainer,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: complete
                                ? LifewoodColors.of(context).success
                                : LifewoodColors.of(context).warning,
                          ),
                        ),
                        child: Text(
                          complete
                              ? 'Metadata Complete'
                              : 'Draft — missing: ${_boxSession!.activeTemplate.missingMandatoryFieldsOf(folder).join(', ')}',
                          style: TextStyle(
                            fontSize: 12,
                            color: complete
                                ? LifewoodColors.of(context).onSuccessContainer
                                : LifewoodColors.of(context).onWarningContainer,
                          ),
                        ),
                      ),
                      if (isActive)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.tertiary,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Text(
                            '● Active Capture',
                            style: TextStyle(
                              fontSize: 12,
                              color: Theme.of(context).colorScheme.onTertiary,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (!isActive)
                  TextButton.icon(
                    onPressed: () => _activateFolder(folder),
                    icon: const Icon(Icons.play_circle_outline, size: 18),
                    label: const Text('Make Active'),
                  ),
                TextButton.icon(
                  onPressed: () => _editFolder(folder),
                  icon: const Icon(Icons.edit_note, size: 18),
                  label: const Text('Edit Metadata'),
                ),
                // Folder structure is not edited from QC mode (same rule as
                // "New Folder"). Greyed rather than hidden when it cannot be
                // deleted, so the rule is visible where it bites.
                if (!_qcMode)
                  IconButton(
                    tooltip: isActive
                        ? 'Delete folder (active - make another active first)'
                        : assignedCount > 0
                        ? 'Delete folder (has images)'
                        : 'Delete folder',
                    onPressed: isActive || assignedCount > 0
                        ? null
                        : () => _deleteFolder(folder),
                    icon: const Icon(Icons.delete_outline, size: 18),
                    color: Theme.of(context).colorScheme.error,
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
            const SizedBox(height: 6),
            if (entries.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(
                  isActive
                      ? 'No images yet — new captures land in this folder.'
                      : 'No images in this folder.',
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              )
            else
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: entries.length,
                // Box mode: fixed columns (kBoxGridColumns) so tiles scale with the window.
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: kBoxGridColumns,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: kCaptureAspectRatio,
                ),
                // Tiles need their REAL date key — delete/recapture handlers
                // key off it, and it differs per file inside a folder.
                itemBuilder: (context, i) => _buildImageTile(
                  _dateKeyFromFilename(p.basename(entries[i].file.path)),
                  entries[i],
                  i,
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// The active folder's file number ("231430") when its volume parses one,
  /// else a fallback by creation order ("Folder 2") — folder *names* aren't
  /// computed until transfer time, so this is the only stable label pre-transfer.
  String _activeFolderLabel(CaptureFolder? folder) {
    if (folder == null) return 'No active folder';
    // The Volume IS the folder's name at transfer, so it is the label too.
    // Untrimmed emptiness included: a folder whose Volume has not been keyed
    // yet has no name to show, and its seq is the only stable thing about it.
    final volume = (folder.volume ?? '').trim();
    return volume.isEmpty ? 'Folder ${folder.folderSeq}' : volume;
  }

  // --- Page build ----------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _viewerFocusNode,
      autofocus: false,
      onKeyEvent: (_, event) => _handleViewerKeyEvent(event),
      child: Scaffold(
        appBar: AppBar(
          // Box mode: the gallery is pushed on top of the box list — offer the
          // way back. (Assignments/metadata live in the DB; nothing is lost.)
          leading: _isBoxMode
              ? IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: _qcMode ? 'Back to capture' : 'Back to Group list',
                  // In QC view the arrow returns to Capture view; in Capture
                  // view it leaves the box.
                  onPressed: () =>
                      _qcMode ? setState(() => _qcMode = false) : Get.back(),
                )
              : null,
          title: !_isBoxMode
              ? Text(
                  "DEVICE MODEL: $deviceModel",
                  style: const TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                )
              // One row, two visually distinct chips: a muted "which box"
              // chip and a prominent "where captures land right now" chip —
              // scannable at a glance without the stacked two-line title.
              : Obx(() {
                  final session = _boxSession;
                  final box = session?.activeBox.value;
                  final folder = session?.activeFolder.value;
                  final images = session?.activeFolderImageCount.value ?? 0;
                  // Chips sit on the themed AppBar (Dark Serpent in light
                  // mode), so they derive from its foreground, not black.
                  final barFg =
                      Theme.of(context).appBarTheme.foregroundColor ??
                      Theme.of(context).colorScheme.onSurface;
                  final accent = Theme.of(context).colorScheme.tertiary;
                  return Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: barFg.withOpacity(0.10),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: barFg.withOpacity(0.30)),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.inventory_2_outlined,
                                size: 18,
                                color: barFg.withOpacity(0.75),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                'Group: ',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.w500,
                                  color: barFg.withOpacity(0.75),
                                ),
                              ),
                              Flexible(
                                child: Text(
                                  box?.boxDetails ?? '-',
                                  style: TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w700,
                                    color: barFg,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: accent.withOpacity(0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: accent.withOpacity(0.6)),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.folder, size: 20, color: accent),
                            const SizedBox(width: 6),
                            Text(
                              'Active: ',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                                color: accent,
                              ),
                            ),
                            Text(
                              _activeFolderLabel(folder),
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: barFg,
                              ),
                            ),
                            Text(
                              ' — $images images',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w500,
                                color: accent,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  );
                }),
          actions: [
            Obx(() {
              final totalDeviceImages = _getTotalDeviceImageCount();
              final selectedCount = _getSelectedCount();
              final allSelected = _globalFullSelection;

              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Box mode: no selection — transfer happens per box.
                  if (!_isBoxMode) ...[
                    IconButton(
                      icon: allSelected
                          ? const Icon(Icons.deselect)
                          : const _GradientIcon(Icons.select_all, size: 26),
                      tooltip: allSelected
                          ? 'Unselect All'
                          : 'Select All (All Dates)',
                      onPressed: totalDeviceImages == 0
                          ? null
                          : () {
                              if (allSelected) {
                                print("🧹 Global 'Unselect All' clicked.");
                                _globalFullSelection = false;
                                _fullDateKeySelection = null;
                                c.clearSelection();
                                if (mounted) setState(() {});
                              } else {
                                _selectAllForAllDates();
                                if (mounted) setState(() {});
                              }
                            },
                    ),
                    IconButton(
                      icon: const Icon(Icons.clear_all),
                      tooltip: 'Clear Selection',
                      onPressed: selectedCount == 0
                          ? null
                          : () {
                              print("🧹 'Clear Selection' clicked.");
                              _globalFullSelection = false;
                              _fullDateKeySelection = null;
                              c.clearSelection();
                              if (mounted) setState(() {});
                            },
                    ),
                  ],
                  // Box mode transfers happen from the Box list, not here.
                  if (!_isBoxMode)
                    IconButton(
                      icon: const Icon(Icons.send),
                      tooltip: 'Send selected images',
                      onPressed: totalDeviceImages == 0 || u.isUploading.value
                          ? null
                          : () => _onSendSelectedPressed(),
                    ),
                  if (_reworkMode) _buildReworkModePill(),
                  PopupMenuButton<String>(
                    tooltip: 'More options',
                    onSelected: (value) {
                      if (value == 'logout') {
                        _confirmLogout(context);
                      }
                    },
                    // No Settings entry: station configuration is
                    // SuperAdmin-only, managed from LWCam Admin.
                    itemBuilder: (context) {
                      return [
                        const PopupMenuItem(
                          value: 'logout',
                          child: ListTile(
                            leading: Icon(Icons.logout),
                            title: Text('Logout'),
                          ),
                        ),
                      ];
                    },
                  ),
                ],
              );
            }),
          ],
        ),
        // Box mode uses the Capture/QC two-view layout (landscape mirror as a
        // top band). Legacy keying-OFF keeps the original left-mirror layout
        // (the inline Row below, built verbatim — its `_isBoxMode` branches
        // are inert here).
        body: _isBoxMode
            ? _buildBoxModeBody()
            : Row(
                children: [
                  Expanded(flex: 265, child: ScrcpyPane(adbPath: adbPath)),
                  Expanded(
                    flex: 735,
                    child: Column(
                      children: [
                        Container(
                          color: Theme.of(context).colorScheme.surfaceContainer,
                          padding: const EdgeInsets.symmetric(
                            vertical: 8,
                            horizontal: 16,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      statusMsg,
                                      style: const TextStyle(
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                  Obx(
                                    () => Text(
                                      s.destinationPath.value.isEmpty
                                          ? "No destination selected"
                                          : "Destination: ${s.destinationPath.value}",
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onSurfaceVariant,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  // Destination is fixed by LWCam Admin's Station Setup
                                  // (SuperAdmin-only) — no picker here.
                                ],
                              ),
                              const SizedBox(height: 4),
                              Obx(() {
                                final selectedCount = _getSelectedCount();
                                final totalCount = _getTotalDeviceImageCount();

                                // Box mode: capturing into the active folder — "Transfer
                                // Selected" is replaced by "New Folder" (transfers happen
                                // from the Box list once the whole box is done).
                                if (_isBoxMode) {
                                  final session = _boxSession!;
                                  final box = session.activeBox.value!;
                                  final folder = session.activeFolder.value;
                                  final folderImages =
                                      session.activeFolderImageCount.value;
                                  return Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          "Group: ${box.boxDetails} • Active: ${_activeFolderLabel(folder)}"
                                          " ($folderImages images) • Group Total: $totalCount images",
                                          style: const TextStyle(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                          ),
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      ElevatedButton.icon(
                                        onPressed: u.isUploading.value
                                            ? null
                                            : () => _onNewFolderPressed(),
                                        icon: const Icon(
                                          Icons.create_new_folder_outlined,
                                          size: 16,
                                        ),
                                        label: const Text(
                                          "New Folder",
                                          style: TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    ],
                                  );
                                }

                                return Row(
                                  mainAxisAlignment:
                                      MainAxisAlignment.spaceBetween,
                                  children: [
                                    Text(
                                      "QC Total: $totalCount • Selected: $selectedCount • Replaced: ${_getReplacementCount()}",
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                    ElevatedButton.icon(
                                      onPressed:
                                          totalCount == 0 || u.isUploading.value
                                          ? null
                                          : () => _onSendSelectedPressed(),
                                      icon: const Icon(Icons.send, size: 16),
                                      label: const Text(
                                        "Transfer Selected",
                                        style: TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  ],
                                );
                              }),
                            ],
                          ),
                        ),
                        if (_isWaitingForRecapture) _buildRecaptureBanner(),
                        Expanded(
                          child: LayoutBuilder(
                            builder: (context, constraints) {
                              // RepaintBoundary: isolate the grid and the (large-bitmap)
                              // preview into separate layers so repainting one never
                              // rasterizes the other.
                              final useSideBySide =
                                  constraints.maxWidth >= kSideBySideMinWidth;
                              if (useSideBySide) {
                                // Order: [mirror pane, left] → Image Viewer (middle,
                                // fills all remaining width) → Image Grid (right, fixed
                                // 2-column pane).
                                return Row(
                                  children: [
                                    Expanded(
                                      child: RepaintBoundary(
                                        child: _buildPreviewPanel(),
                                      ),
                                    ),
                                    SizedBox(
                                      width: kGridPaneWidth,
                                      child: RepaintBoundary(
                                        child: _isBoxMode
                                            ? _buildBoxGalleryList()
                                            : _buildGalleryList(),
                                      ),
                                    ),
                                  ],
                                );
                              }

                              return Column(
                                children: [
                                  Expanded(
                                    child: RepaintBoundary(
                                      child: _isBoxMode
                                          ? _buildBoxGalleryList()
                                          : _buildGalleryList(),
                                    ),
                                  ),
                                  SizedBox(
                                    height: 320,
                                    child: RepaintBoundary(
                                      child: _buildPreviewPanel(),
                                    ),
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
      ),
    );
  }

  // ── Box-mode body: landscape mirror TOP BAND + Capture/QC content ─────────

  Widget _buildBoxModeBody() {
    return LayoutBuilder(
      builder: (context, cons) {
        // Aspect-fit: pane width = pane height × the cropped stream's aspect,
        // so the mirror fills its pane with zero letterboxing and the grid gets
        // everything else. Falls back to a fixed fraction until the mirror has
        // started and published its aspect.
        return ValueListenableBuilder<double?>(
          valueListenable: ScrcpyService.instance.captureAspect,
          builder: (context, aspect, _) {
            final mirrorWidth = aspect != null
                ? (cons.maxHeight * aspect).clamp(
                    0.0,
                    cons.maxWidth * kBoxMirrorMaxWidthFraction,
                  )
                : cons.maxWidth * kBoxMirrorFallbackWidthFraction;
            final rightWidth = cons.maxWidth - mirrorWidth;
            return Row(
              children: [
                // Vertical (portrait) mirror as a STABLE left pane, so toggling
                // Capture↔QC (which only changes the right region) never
                // remounts ScrcpyPane / makes the native window flicker. The
                // ValueKey documents that intent.
                SizedBox(
                  width: mirrorWidth,
                  child: ScrcpyPane(
                    key: const ValueKey('scrcpy-mirror'),
                    adbPath: adbPath,
                  ),
                ),
                Expanded(
                  child: Column(
                    children: [
                      _buildBoxStatusHeader(),
                      const TransferQueueBanner(),
                      if (_isWaitingForRecapture) _buildRecaptureBanner(),
                      Expanded(
                        child: _reworkMode
                            ? RepaintBoundary(child: _buildReworkGalleryList())
                            : _qcMode
                            ? _buildQcContent(rightWidth)
                            : RepaintBoundary(child: _buildBoxGalleryList()),
                      ),
                    ],
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// QC view content (right region, beside the mirror): compressed viewer
  /// (left) | image grid (right) → overall mirror | viewer | grid.
  Widget _buildQcContent(double regionWidth) {
    return Row(
      children: [
        SizedBox(
          width: regionWidth * kQcViewerWidthFraction,
          child: RepaintBoundary(child: _buildPreviewPanel()),
        ),
        Expanded(child: RepaintBoundary(child: _buildBoxGalleryList())),
      ],
    );
  }

  Widget _buildBoxStatusHeader() {
    // Rework mode has its own header: the framed status / image / reason block,
    // plus the Submit Rework action. None of the capture header's content (image
    // counts, New Folder, Review & Transfer) applies to a transferred box.
    if (_reworkMode) {
      return Container(
        color: Theme.of(context).colorScheme.surfaceContainer,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(child: _buildReworkStatusBlock()),
            const SizedBox(width: 12),
            if (_shutterKeybind.isNotEmpty) ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withOpacity(0.06),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '📸 Shutter: $_shutterKeybind',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              const SizedBox(width: 8),
            ],
            _buildReworkSubmitButton(),
          ],
        ),
      );
    }
    return Container(
      color: Theme.of(context).colorScheme.surfaceContainer,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  statusMsg,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
              // Destination path deliberately not shown or editable here —
              // it's fixed by LWCam Admin's Station Setup (SuperAdmin-only).
            ],
          ),
          const SizedBox(height: 4),
          Obx(() {
            final session = _boxSession!;
            final box = session.activeBox.value!;
            final folder = session.activeFolder.value;
            final folderImages = session.activeFolderImageCount.value;
            final totalCount = _getTotalDeviceImageCount();
            // Background transfers of OTHER boxes must never block capture
            // work here — only re-gate "Confirm Transfer" against THIS box
            // already being queued/running.
            final thisBoxBusy =
                Get.isRegistered<TransferQueueService>() &&
                Get.find<TransferQueueService>().isBoxQueuedOrRunning(box.id);
            return Row(
              children: [
                Expanded(
                  child: Text(
                    "Group: ${box.boxDetails} • Active: ${_activeFolderLabel(folder)}"
                    " ($folderImages images) • Group Total: $totalCount images",
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Discoverability: which key fires the phone shutter.
                if (_shutterKeybind.isNotEmpty) ...[
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withOpacity(0.06),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '📸 Shutter: $_shutterKeybind',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                if (!_qcMode) ...[
                  ElevatedButton.icon(
                    onPressed: () => _onNewFolderPressed(),
                    icon: const Icon(
                      Icons.create_new_folder_outlined,
                      size: 16,
                    ),
                    label: const Text(
                      "New Folder",
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: () => setState(() {
                      _qcMode = true;
                      _ensurePreviewSelection(preferLatest: true);
                    }),
                    icon: const Icon(Icons.fact_check_outlined, size: 16),
                    label: const Text(
                      "Review & Transfer",
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ] else ...[
                  TextButton.icon(
                    onPressed: () => setState(() => _qcMode = false),
                    icon: const Icon(Icons.arrow_back, size: 16),
                    label: const Text(
                      "Back to capture",
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: thisBoxBusy
                        ? null
                        : () => _onConfirmTransferPressed(),
                    icon: const Icon(Icons.send, size: 16),
                    label: Text(
                      thisBoxBusy ? "Transferring…" : "Confirm Transfer",
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ],
              ],
            );
          }),
        ],
      ),
    );
  }

  /// The one recapture banner. Both the capture grid and the rework screen show
  /// it; it used to be written out twice, which is how the X would have ended up
  /// on one of them only.
  Widget _buildRecaptureBanner() {
    return Container(
      width: double.infinity,
      color: Theme.of(context).colorScheme.tertiaryContainer.withOpacity(0.45),
      padding: const EdgeInsets.only(left: 16, right: 4, top: 10, bottom: 10),
      child: Row(
        children: [
          const SizedBox(
            height: 18,
            width: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Camera launched for slot ${_recaptureSlotOriginalName ?? ''}. '
              'The app will refocus automatically after the new photo is '
              'detected.',
            ),
          ),
          // The way out. Esc does the same thing; this is the discoverable
          // half, since nothing on screen would otherwise say the state can be
          // left at all.
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Exit recapture (Esc)',
            onPressed: _cancelRecapture,
          ),
        ],
      ),
    );
  }

  // ══════════════════════════════════════════════════════════════════════════
  // REWORK MODE
  //
  // Entered only from the box list's "Rework" button. The box is TRANSFERRED
  // and stays that way; this is not a capture session. Images come from LWIP's
  // INPUT folder (the phone's copies are gone after transfer), and a recapture
  // replaces one of those files, which changes the folder's fingerprint and
  // makes LWIP reprocess it — that is the whole return path to QC.
  // ══════════════════════════════════════════════════════════════════════════

  // --- Rework mode: status header, folder cards and tiles ------------------

  Map<int, List<ReworkItem>> get _reworkByFolderSeq =>
      groupReworkByFolderSeq(_reworkItems);

  ReworkItem? get _focusedReworkItem => _reworkFocusedImage == null
      ? null
      : _reworkItems.firstWhereOrNull(
          (i) => i.imageName == _reworkFocusedImage,
        );

  void _focusReworkImage(String imageName) {
    setState(() => _reworkFocusedImage = imageName);
  }

  /// The INPUT file a rework item's recapture must replace, or null when it
  /// cannot be resolved on this station.
  ///
  /// Sync, cache-only (build code calls it): the share is asked, async and
  /// time-bounded, by [_resolveReworkInput].
  File? _reworkInputFileFor(ReworkItem item) =>
      _reworkInputs[_reworkInputKey(item)]?.file;

  final Map<String, ReworkInput> _reworkInputs = {};

  String _reworkInputKey(ReworkItem item) => '${item.folderKey}|${item.imageName}';

  bool _reworkShareUnreachable(ReworkItem item) =>
      _reworkInputs[_reworkInputKey(item)]?.unreachable ?? false;

  static const _kInputShareDown =
      'The LWIP input share is unreachable — try again when it is back.';

  /// Asks the LWIP input share (async, 5 s limit) and caches the answer.
  Future<ReworkInput> _resolveReworkInput(ReworkItem item) async {
    final config = _reworkConfig;
    final result = config == null
        ? ReworkInput.none
        : await ReworkService.inputFileFor(
            config,
            folderPath: item.folderPath,
            imageName: item.imageName,
          );
    if (mounted) setState(() => _reworkInputs[_reworkInputKey(item)] = result);
    return result;
  }

  /// Rework's replacement for loadDcimImages: resolves the rejected images in
  /// LWIP's input folder instead of pulling them from the phone (after a
  /// transfer the phone has no copy at all).
  ///
  /// Deliberately does NOT feed c.groupedImages. The rework tiles read their
  /// files directly, so populating it would decode every image a second time.
  Future<void> _loadReworkImages() async {
    setState(() => statusMsg = 'Loading the images QC sent back…');
    if (Get.isRegistered<NodeConfigService>()) {
      try {
        _reworkConfig = await Get.find<NodeConfigService>().load();
      } catch (e) {
        print('⚠️ Rework: could not read the station config: $e');
      }
    }
    // A closure already in the outbox means that request is submitted even
    // when PG has not drained it yet. Rebuild the session's closed set from
    // the outbox, so a re-entry after a partial submit does not offer the page
    // for a second write.
    final pendingClosures = await UploadStatsDB().pendingReworkClosureKeys(
      auth.deviceId.value,
    );
    final closed = closedReworkImages(_reworkItems, pendingClosures);
    final session = _boxSession;
    if (session != null) {
      session.reworkClosed
        ..clear()
        ..addAll(closed);
      for (final name in closed) {
        session.reworkStaged.remove(name);
        session.reworkMetadataFixed.remove(name);
      }
    }
    final awaiting = _reworkItems
        .where((item) => !closed.contains(item.imageName))
        .toList();
    c.groupedImages.clear();
    final resolved = await Future.wait(awaiting.map(_resolveReworkInput));
    for (var i = 0; i < awaiting.length; i++) {
      final target = resolved[i].file;
      if (target == null || _reworkStaged.containsKey(awaiting[i].imageName)) continue;
      try {
        final recovered = await ColorReworkStore.recoverApplying(auth.deviceId.value, target.path);
        if (recovered != null) _reworkStaged[awaiting[i].imageName] = recovered;
      } catch (e) {
        print('Rework recovery needs attention: $e');
      }
    }
    final missing = resolved.where((r) => r.file == null).length;
    final down = resolved.any((r) => r.unreachable);
    if (!mounted) return;
    setState(() {
      statusMsg = awaiting.isEmpty
          ? 'All rework in this group is submitted — waiting for QC.'
          : down
          ? _kInputShareDown
          : missing == 0
          ? '${awaiting.length} image(s) awaiting rework in this group.'
          : '${awaiting.length} image(s) awaiting rework — $missing source '
                'file(s) could not be found on this PC.';
    });
  }

  /// The "Rework Mode" pill, beside the overflow menu.
  Widget _buildReworkModePill() {
    final lw = LifewoodColors.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: lw.warning,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.replay, size: 18, color: lw.onWarning),
          const SizedBox(width: 6),
          Text(
            'Rework Mode',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: lw.onWarning,
            ),
          ),
        ],
      ),
    );
  }

  /// The whole rework status block: the app's own status message, the focused
  /// image's name, and QC's reason — as three separately framed rows.
  ///
  /// They were one run of text before, which made the app's status
  /// indistinguishable from QC's verdict at a glance. Framing separates
  /// "what LWCAM is doing" from "what QC said about THIS image".
  Widget _buildReworkStatusBlock() {
    final lw = LifewoodColors.of(context);
    final cs = Theme.of(context).colorScheme;
    final item = _focusedReworkItem;

    Widget row(Widget child, {bool last = false}) => Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        border: Border(
          bottom: last
              ? BorderSide.none
              : BorderSide(color: cs.outlineVariant, width: 1),
        ),
      ),
      child: child,
    );

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: cs.outlineVariant, width: 1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          row(
            Text(
              statusMsg,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          row(
            Text(
              item == null
                  ? 'Select an image to see why it was sent back'
                  : [
                      if (item.pageLabel.isNotEmpty) 'Page ${item.pageLabel}',
                      item.imageName,
                    ].join(' · '),
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: item == null ? cs.onSurfaceVariant : cs.onSurface,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          row(
            Text(
              item == null
                  ? 'Reject Reason: —'
                  : 'Reject Reason: '
                        '${item.reason.trim().isEmpty ? '(none given)' : item.reason.trim()}',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: item == null ? cs.onSurfaceVariant : lw.warning,
              ),
              overflow: TextOverflow.ellipsis,
            ),
            last: true,
          ),
        ],
      ),
    );
  }

  Widget _buildReworkGalleryList() {
    return Obx(() {
      // Obx for foldersOfActiveBox; tile state (staged/marked/focused) is
      // plain setState — this mode has no streaming image source to react to.
      final session = _boxSession!;
      final byFolder = _reworkByFolderSeq;
      // Includes synthesized placeholders for QC-created folders (separation
      // children) with no local row, so this list is only empty when the
      // worklist itself is — and rework mode is off then.
      final folders = reworkFoldersFor(
        session.foldersOfActiveBox.toList(),
        byFolder,
        boxId: session.activeBox.value!.id,
      );
      if (folders.isEmpty) {
        return const Center(child: Text('No rework requests to show.'));
      }
      return ListView(
        controller: _galleryScrollController,
        children: [
          for (final f in folders)
            _buildReworkFolderCard(f, byFolder[f.folderSeq]!),
        ],
      );
    });
  }

  Widget _buildReworkFolderCard(CaptureFolder folder, List<ReworkItem> items) {
    final lw = LifewoodColors.of(context);
    final edited = _reworkEdited.containsKey(folder.folderSeq);
    final title = folder.folderName ?? 'Folder ${folder.folderSeq}';
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: lw.warning, width: 2),
      ),
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    '$title · ${items.length} image(s) sent back',
                    style: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (edited)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: Chip(
                      label: const Text(
                        'metadata saved',
                        style: TextStyle(fontSize: 11),
                      ),
                      backgroundColor: lw.warningContainer,
                      labelStyle: TextStyle(color: lw.onWarningContainer),
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                TextButton.icon(
                  onPressed: _reworkSubmitting
                      ? null
                      : () => _editReworkMetadata(folder, items),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text(
                    'Edit Metadata',
                    style: TextStyle(fontSize: 12),
                  ),
                ),
              ],
            ),
            // The metadata values are deliberately NOT listed: Edit Metadata is
            // right there, and dumping 14 fields per folder pushed the images —
            // the thing being reworked — off the screen.
            const SizedBox(height: 8),
            // Same column count as capture mode (kBoxGridColumns), so the tiles
            // scale with the window instead of being fixed thumbnails.
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: items.length,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: kBoxGridColumns,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                // Same shape as the capture grids: these are the same
                // photographs, so a different ratio here would crop or letterbox
                // them differently from where the operator just saw them.
                childAspectRatio: kCaptureAspectRatio,
              ),
              itemBuilder: (context, i) => _buildReworkTile(items[i]),
            ),
          ],
        ),
      ),
    );
  }

  /// A rework tile. Deliberately NOT _buildImageTile: that one is wired to
  /// device filenames, replacement overlays, per-image transfer selection and
  /// phone deletion, none of which apply to a transferred box — and reusing it
  /// would have meant threading rework conditionals through the most
  /// safety-critical widget in this file.
  /// A staged photo is local (cheap to stat); the LWIP input file was already
  /// probed, async, by [_resolveReworkInput] - never stat a UNC path in build.
  bool _reworkSourceReadable(ReworkItem item, File source) =>
      _reworkStaged[item.imageName] != null
      ? source.existsSync()
      : _reworkInputs[_reworkInputKey(item)]?.status == FsProbe.found;

  Widget _buildReworkTile(ReworkItem item) {
    final lw = LifewoodColors.of(context);
    final cs = Theme.of(context).colorScheme;
    final staged = _reworkStaged[item.imageName];
    final marked = _reworkMetadataFixed.contains(item.imageName);
    final closed = _boxSession?.reworkClosed.contains(item.imageName) ?? false;
    final focused = _reworkFocusedImage == item.imageName;
    final busy =
        _isWaitingForRecapture ||
        _reworkSubmitting ||
        _reworkUndoing.contains(item.imageName);
    final source = staged ?? _reworkInputFileFor(item);
    return GestureDetector(
      key: _reworkTileKey(item.imageName),
      onTap: () => _focusReworkImage(item.imageName),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: focused ? lw.viewing : cs.outlineVariant,
            width: focused ? 3 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (source != null && _reworkSourceReadable(item, source))
                    Image.file(
                      source,
                      key: ValueKey('${source.path}:$_reworkStageEpoch'),
                      cacheWidth: 400,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => _reworkTilePlaceholder(
                        'This image could not be read.',
                      ),
                    )
                  else
                    _reworkTilePlaceholder(
                      _reworkConfig == null
                          ? 'This station has no processing folders configured.'
                          : _reworkShareUnreachable(item)
                          ? _kInputShareDown
                          : 'Source file not on this PC — the folder was captured '
                                'on another station.',
                    ),
                  // Page position, top-left. The resolution badges moved to the
                  // bottom to make room — same corner the QC rail uses for its
                  // own NEW pill.
                  if (item.pageLabel.isNotEmpty)
                    Positioned(
                      top: 6,
                      left: 6,
                      child: _reworkBadge(
                        item.pageLabel,
                        Colors.black54,
                        Colors.white,
                      ),
                    ),
                  if (closed)
                    Positioned(
                      bottom: 6,
                      left: 6,
                      child: _reworkBadge(
                        'SUBMITTED',
                        lw.info,
                        lw.onInfo,
                      ),
                    )
                  else if (staged != null)
                    Positioned(
                      bottom: 6,
                      left: 6,
                      child: _reworkBadge(
                        'NEW PHOTO',
                        lw.success,
                        lw.onSuccess,
                      ),
                    )
                  else if (marked)
                    Positioned(
                      bottom: 6,
                      left: 6,
                      child: _reworkBadge(
                        'METADATA FIX',
                        lw.warning,
                        lw.onWarning,
                      ),
                    ),
                  if (focused)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: _reworkBadge(
                        'VIEWING',
                        lw.viewing.withOpacity(0.9),
                        lw.onInfo,
                      ),
                    ),
                  // Enlarge. An overlay rather than a footer button: the footer
                  // already carries Recapture + the metadata-fix icon, and the
                  // tile is ~175px wide at 1366. No onDoubleTap on the tile's
                  // GestureDetector — that would delay every focus tap by
                  // kDoubleTapTimeout, and focusing is the main interaction
                  // here. Only over a real image, never the placeholder.
                  if (source != null && _reworkSourceReadable(item, source))
                    Positioned(
                      bottom: 6,
                      right: 6,
                      child: Tooltip(
                        message: 'Enlarge',
                        child: InkWell(
                          onTap: () => showEnlargedImage(
                            context,
                            source,
                            caption: [
                              if (item.pageLabel.isNotEmpty)
                                'Page ${item.pageLabel}',
                              item.imageName,
                            ].join(' · '),
                          ),
                          customBorder: const CircleBorder(),
                          child: Container(
                            width: 28,
                            height: 28,
                            decoration: const BoxDecoration(
                              color: Colors.black54,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.zoom_in,
                              size: 18,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              color: Colors.black54,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              // Page number leads: the name's head is the same device prefix on
              // every tile and its tail is what ellipsizes away at this width.
              child: Text(
                item.pageLabel.isEmpty
                    ? item.imageName
                    : '${item.pageLabel} · ${item.imageName}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 11),
              ),
            ),
            // No delete and no selection: this image is already transferred,
            // processed and indexed by QC.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: closed
                  ? const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'Submitted — waiting for QC',
                        style: TextStyle(fontSize: 11),
                      ),
                    )
                  : staged != null || marked
                  ? TextButton.icon(
                      onPressed: busy
                          ? null
                          : () => _undoReworkResolution(item),
                      icon: const Icon(Icons.undo, size: 14),
                      label: const Text('Undo', style: TextStyle(fontSize: 11)),
                    )
                  : Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Expanded(
                          child: FilledButton.icon(
                            onPressed: busy
                                ? null
                                : () => _startReworkRecaptureForSlot(item),
                            style: FilledButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                              ),
                              visualDensity: VisualDensity.compact,
                            ),
                            icon: const Icon(Icons.camera_alt, size: 14),
                            label: const Text(
                              'Recapture',
                              style: TextStyle(fontSize: 11),
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        IconButton(
                          tooltip: 'Fixed by metadata — no recapture needed',
                          onPressed: busy
                              ? null
                              : () => _markReworkMetadataFixed(item),
                          icon: const Icon(Icons.edit_note, size: 18),
                          visualDensity: VisualDensity.compact,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reworkTilePlaceholder(String message) => Container(
    color: Theme.of(context).colorScheme.surfaceContainerHighest,
    padding: const EdgeInsets.all(12),
    child: Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(
          Icons.image_not_supported_outlined,
          color: Theme.of(context).colorScheme.outline,
        ),
        const SizedBox(height: 6),
        Text(
          message,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 10),
        ),
      ],
    ),
  );

  Widget _reworkBadge(String text, Color bg, Color fg) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      text,
      style: TextStyle(color: fg, fontSize: 10, fontWeight: FontWeight.bold),
    ),
  );

  Future<void> _undoReworkResolution(ReworkItem item) async {
    if (_reworkUndoing.contains(item.imageName) ||
        _reworkSubmitting ||
        _isWaitingForRecapture ||
        (_boxSession?.reworkClosed.contains(item.imageName) ?? false)) {
      return;
    }
    final staged = _reworkStaged[item.imageName];
    if (staged != null) {
      _reworkUndoing.add(item.imageName);
      if (mounted) setState(() {});
      try {
        // Discard the durable intent BEFORE deleting the photo: a failed
        // discard must leave both in place so the operator can retry, rather
        // than leaving an intent that points at a deleted file.
        await ColorReworkStore.discardStaged(staged);
      } catch (e) {
        _reworkUndoing.remove(item.imageName);
        if (mounted) {
          setState(() {});
          showAppSnackBar('Undo failed', '$e');
        }
        return;
      }
      _reworkUndoing.remove(item.imageName);
      _reworkStaged.remove(item.imageName);
      try {
        await staged.delete();
      } catch (e) {
        print('ℹ️ Could not delete discarded recapture photo: $e');
      }
    }
    _reworkMetadataFixed.remove(item.imageName);
    if (mounted) setState(() {});
  }

  /// Submit lives in the header beside the status block. There is no separate
  /// "save metadata" action: Edit Metadata persists on its own Save (see
  /// _editReworkMetadata), so the only thing left to submit is the images.
  Widget _buildReworkSubmitButton() {
    final lw = LifewoodColors.of(context);
    final closed = _boxSession?.reworkClosed ?? const <String>{};
    final closes = _reworkStaged.length + _reworkMetadataFixed.length;
    final open = reworkOpenItemCount(
      _reworkItems,
      staged: _reworkStaged.keys.toSet(),
      metadataFixed: _reworkMetadataFixed,
      closed: closed,
    );
    return FilledButton.icon(
      onPressed:
          (open > 0 ||
              closes == 0 ||
              _reworkSubmitting ||
              _isWaitingForRecapture ||
              _reworkUndoing.isNotEmpty)
          ? null
          : _onSubmitReworkPressed,
      style: FilledButton.styleFrom(
        backgroundColor: lw.warning,
        foregroundColor: lw.onWarning,
      ),
      icon: const Icon(Icons.check, size: 16),
      label: Text(
        _reworkSubmitting
            ? 'Submitting…'
            : open > 0
            ? '$open page(s) still need rework'
            : 'Submit Rework ($closes)',
        style: const TextStyle(fontSize: 12),
      ),
    );
  }

  // ── Rework metadata ───────────────────────────────────────────────────────

  /// The folder carrying its CLOUD metadata, so the edit form starts from what
  /// QC currently has rather than what was keyed at capture time — otherwise
  /// saving would silently revert QC's own corrections.
  CaptureFolder _reworkCloudFolder(
    CaptureFolder folder,
    List<ReworkItem> items,
  ) {
    final cloud = items.isEmpty
        ? const <String, Object?>{}
        : items.first.folderMetadata;
    if (cloud.isEmpty) return folder;
    String? text(String column) {
      final value = cloud[column];
      if (value == null) return null;
      final s = value is DateTime ? value.toIso8601String() : value.toString();
      return s.trim().isEmpty ? null : s;
    }

    return folder.copyWith(
      coverTag: text('cover_tag'),
      imageTags: text('image_tags'),
      title: text('title'),
      volume: text('volume'),
      startDate: text('start_date'),
      endDate: text('end_date'),
      archivalRefNo: text('archival_ref_no'),
      recordType: text('record_type'),
    );
  }

  /// Edits and PERSISTS a folder's metadata straight away — the dialog's Save
  /// means saved, so there is no separate submit step for metadata.
  ///
  /// Only the columns actually changed are sent (folderMetadataPatchSql via the
  /// capture_folder_rework outbox entity), and the local row is updated with
  /// enqueueSync: false. Doing it the obvious way — a full folderUpsertSql from
  /// LWCAM's local row — would revert QC's own edits to every column the
  /// operator did not touch, because the local row still holds what was keyed at
  /// capture time.
  ///
  /// qc_status is deliberately NOT reset here: the folder still has open image
  /// requests, and it goes back to QC only once those are settled on submit.
  Future<void> _editReworkMetadata(
    CaptureFolder folder,
    List<ReworkItem> items,
  ) async {
    if (_reworkSubmitting || _reworkUndoing.isNotEmpty) return;
    final session = _boxSession!;
    final edited = await showDialog<CaptureFolder>(
      context: context,
      builder: (_) => FolderMetadataDialog(
        initial:
            _reworkEdited[folder.folderSeq] ??
            _reworkCloudFolder(folder, items),
        heading:
            'Rework — ${folder.folderName ?? 'folder ${folder.folderSeq}'}',
        boxDetails: session.activeBox.value!.boxDetails,
        template: session.activeTemplate,
      ),
    );
    if (edited == null) return;
    setState(() => _reworkEdited[folder.folderSeq] = edited);

    final changed = _changedReworkColumns(folder, items);
    if (changed.isEmpty) {
      setState(() => statusMsg = 'No metadata changes to save.');
      return;
    }
    final db = UploadStatsDB();
    try {
      await db.enqueueFolderRework(
        deviceId: auth.deviceId.value,
        projectKey: items.first.projectKey,
        projectId: items.first.projectId,
        boxName: items.first.boxName,
        folderSeq: folder.folderSeq,
        folderName: folder.folderName ?? '',
        changedMetadata: changed,
        resetQcStatus: false,
        isCreatedThumbnail: items.first.isCreatedThumbnail,
      );
      // id == 0 marks a QC-created folder (separation child) with no local row
      // to update — see reworkFoldersFor. The cloud patch above is the whole
      // save for those; PG is the only place that folder exists.
      if (folder.id != 0) {
        await db.updateCaptureFolderMetadata(
          deviceId: auth.deviceId.value,
          folder: edited.copyWith(id: folder.id),
          isComplete: session.activeTemplate.isCompleteOf(edited),
          enqueueSync: false,
        );
      }
      if (!mounted) return;
      setState(
        () => statusMsg =
            'Metadata saved for ${folder.folderName ?? 'folder ${folder.folderSeq}'} '
            '(${changed.length} field(s)).',
      );
    } catch (e) {
      print('⚠️ Rework metadata save failed: $e');
      if (!mounted) return;
      showAppSnackBar('Could not save metadata', '$e');
    }
  }

  /// The columns the operator changed, cloud → edited, as capture_folders
  /// column names. Compared through the template's effective values (the same
  /// resolution the grid and the transfer plan use), so a Title-mapped Record
  /// Type follows a Title edit instead of looking unchanged.
  Map<String, Object?> _changedReworkColumns(
    CaptureFolder folder,
    List<ReworkItem> items,
  ) {
    final edited = _reworkEdited[folder.folderSeq];
    if (edited == null) return const {};
    final template = _boxSession!.activeTemplate;
    final cloud = _reworkCloudFolder(folder, items);
    final changed = <String, Object?>{};
    st.kFolderMetadataColumnByFieldId.forEach((fieldId, column) {
      final before = template.effectiveValueOf(fieldId, cloud);
      final after = template.effectiveValueOf(fieldId, edited);
      if ((before ?? '') != (after ?? '')) changed[column] = after;
    });
    return changed;
  }

  Future<void> _markReworkMetadataFixed(ReworkItem item) async {
    if (_reworkSubmitting ||
        _reworkUndoing.isNotEmpty ||
        (_boxSession?.reworkClosed.contains(item.imageName) ?? false)) {
      return;
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Fixed by metadata?'),
        content: SizedBox(
          width: 420,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.imageName,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 4),
              Text(
                'QC reason: ${item.reason}',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 12),
              const Text(
                'Use this when the problem was the keyed metadata, not the '
                'photograph. The image is left exactly as it is and the request '
                'is closed on submit.',
                style: TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 8),
              const Text(
                'If the photo itself is wrong, recapture it instead — QC will '
                'only send it back again.',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Mark fixed'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _reworkMetadataFixed.add(item.imageName));
  }

  // ── Rework recapture (staging only) ───────────────────────────────────────

  /// Recaptures one rejected image. Reuses this page's own camera/ADB
  /// primitives, but NOT _startRecaptureForSlot: that one renames the new
  /// capture over the original ON THE DEVICE and writes a replacement_records
  /// row, both of which are pre-transfer concepts. Here the original lives in
  /// LWIP's input folder and the phone has no copy at all.
  ///
  /// Staging only — nothing is written until Submit Rework, so LWIP reprocesses
  /// the folder once and QC never sees it half fixed.
  Future<void> _startReworkRecaptureForSlot(ReworkItem item) async {
    if (_reworkSubmitting ||
        _reworkUndoing.isNotEmpty ||
        (_boxSession?.reworkClosed.contains(item.imageName) ?? false)) {
      return;
    }
    final input = await _resolveReworkInput(item);
    final target = input.file;
    if (target == null) {
      showAppSnackBar(
        _reworkConfig == null
            ? 'Not configured'
            : input.unreachable
            ? 'Share unreachable'
            : 'Different station',
        input.unreachable
            ? _kInputShareDown
            : _reworkConfig == null
            ? 'This station has no processing folders configured. Ask an admin '
                  'to complete LWCam Admin → Station Setup.'
            : 'This folder was captured on another station, so its source '
                  'images are not on this PC. Recapture it where it was captured.',
      );
      return;
    }
    if (!await target.parent.exists()) {
      showAppSnackBar(
        'Source folder missing',
        'Cannot find ${target.parent.path}. The folder may have been archived '
            'or moved.',
      );
      return;
    }
    // The row's image_name may no longer match what is actually on disk (QC's
    // replace-image can leave the row saying IMG_0007.png while the folder
    // still holds IMG_0007.jpg). _overwriteReworkFileAtomically's rename would
    // happily CREATE that filename, leaving both the old and new file in the
    // folder for LWIP to publish. Refuse instead of guessing a sibling
    // extension — there is no safe way to pick which file the operator meant.
    if (!await target.exists()) {
      showAppSnackBar(
        'Source file missing',
        'Expected ${p.basename(target.path)} in ${target.parent.path} but did '
            "not find it. QC may have replaced this page with a file of a "
            'different type; ask an admin to resolve it before recapturing.',
      );
      return;
    }
    final recaptureScrollOffset = _galleryScrollController.hasClients
        ? _galleryScrollController.offset
        : null;

    setState(() {
      _recaptureCancelled = false;
      _isWaitingForRecapture = true;
      _recaptureSlotOriginalName = item.imageName;
      _reworkFocusedImage = null;
      statusMsg =
          'Recapture in progress for ${item.imageName}. Waiting for the '
          'new image from the device camera…';
    });
    // The shutter hotkey is armed ONLY for the duration of a recapture — see
    // initState. This is the single path by which a photo can enter the app in
    // rework mode.
    await _armShutterHotkey();

    try {
      if (_boxSession != null && !await ColorCaptureSession.begin(auth.deviceId.value)) return;
      final beforeNames = (await _listDeviceImageNames()).toSet();
      if (beforeNames.isEmpty && (_workingPath ?? '').isEmpty) {
        showAppSnackBar(
          'Phone not connected',
          'Connect the capture device — recapture pulls the new photo over ADB.',
        );
        return;
      }

      // Same 350ms poll as the pre-transfer recapture — see the comment there.
      // Started BEFORE the camera launch checks for the same reason: a photo
      // taken while they run is detected immediately. No cancellation on
      // launch failure — this screen keeps waiting by design (snackbar below).
      final newNameFuture = _waitForNewCapture(
        beforeNames,
        pollInterval: kExpeditedSyncInterval,
        isCancelled: () => _recaptureCancelled,
      );

      final launch = await _launchCameraForRecapture();
      if (launch.exitCode != 0) {
        showAppSnackBar(
          'Camera',
          'Could not open the Camera app. Open it on the phone, then take the '
              'photo — this screen keeps waiting.',
        );
      }

      final newName = await newNameFuture;
      if (newName == null) {
        if (!_recaptureCancelled) {
          showAppSnackBar(
            'Timed out',
            'No new photo appeared on the phone. Nothing was changed.',
          );
        }
        return;
      }

      _reworkStagingDir ??= await Directory.systemTemp.createTemp(
        'lwcam_rework_',
      );
      // Tag the staging with its box so another box's staged photos are never
      // shown, and so openBox knows when it is safe to discard them.
      _boxSession!.reworkStagedBoxId = _boxSession!.activeBox.value?.id;
      final pulled = await _pullSingleFile(
        newName,
        targetDir: _reworkStagingDir!,
      );
      if (pulled == null ||
          !await pulled.exists() ||
          await pulled.length() <= 0) {
        showAppSnackBar(
          'Pull failed',
          'The photo could not be copied from the phone. Nothing was changed.',
        );
        return;
      }

      await _bringAppToFront();
      if (!mounted) return;
      // No confirmation dialog: the new photo simply takes the tile, exactly as
      // the pre-transfer slot recapture behaves. Nothing is written to LWIP's
      // input folder yet, and pressing Recapture again replaces the staged photo,
      // so this is freely repeatable — a confirm step here bought nothing but a
      // click.

      // Under the item's own name inside staging, so submit can find it and a
      // repeat recapture of the same slot overwrites rather than piling up.
      final slotFile = File(p.join(_reworkStagingDir!.path, item.imageName));
      if (pulled.path != slotFile.path) {
        await pulled.copy(slotFile.path);
        await _deleteLocalFileIfExists(pulled);
      }
      final binding = await ColorCaptureSession.bindingFor(auth.deviceId.value, newName);
      final durable = await ColorReworkStore.stage(auth.deviceId.value, target.path, slotFile, binding, folderKey: item.folderKey);
      await FileImage(slotFile).evict();

      setState(() {
        _reworkStaged[item.imageName] = durable;
        _reworkStageEpoch++; // repaint the tile even on a repeat recapture
        // A recapture supersedes a metadata-only claim on the same image.
        _reworkMetadataFixed.remove(item.imageName);
        statusMsg =
            '✅ New photo staged for ${item.imageName}. '
            'Submit to apply it.';
      });
      _scrollOnceTo(
        _reworkTileKey(item.imageName),
        fallbackOffset: recaptureScrollOffset,
      );
    } catch (e) {
      print('⚠️ Rework recapture failed: $e');
      await _bringAppToFront();
      if (mounted) {
        setState(() => statusMsg = 'Recapture failed for ${item.imageName}.');
        showAppSnackBar('Recapture failed', '$e');
      }
    } finally {
      ShutterHotkeyService.instance.disarm();
      if (mounted) {
        setState(() {
          _isWaitingForRecapture = false;
          _recaptureSlotOriginalName = null;
          _shutterKeybind = '';
        });
      }
    }
  }

  // ── Rework submit ─────────────────────────────────────────────────────────

  /// Applies every staged replacement and closes the requests this submit
  /// settled.
  ///
  /// A failure part-way leaves the writes already done in place with their rows
  /// closed. That is safe: rework_logs is append-only, each overwrite is atomic,
  /// and re-submitting only retries what is left.
  Future<void> _onSubmitReworkPressed() async {
    final session = _boxSession!;
    final box = session.activeBox.value!;
    final username = auth.currentUser.value?.username ?? '';
    final deviceId = auth.deviceId.value;
    final db = UploadStatsDB();
    if (_reworkSubmitting ||
        _isWaitingForRecapture ||
        _reworkUndoing.isNotEmpty) {
      return;
    }
    setState(() {
      _reworkSubmitting = true;
      statusMsg = 'Applying rework…';
    });

    final byFolder = _reworkByFolderSeq;
    final failures = <String>[];
    var wrote = 0;
    var closed = 0;

    try {
      for (final folder in reworkFoldersFor(
        session.foldersOfActiveBox.toList(),
        byFolder,
        boxId: box.id,
      )) {
        final items = byFolder[folder.folderSeq]!;
        final verified = <int, File>{};
        final metadataReady = <int>{};
        var folderBlocked = false;
        final recaptured = <int>{}; // reworkIds settled by a new photo
        // Input folders whose completion marker says "rework in progress"
        // while files are being replaced (LWIP holds off until it is cleared).
        final flagged = <String>{};
        final failedFolders = <String>{};

        for (final item in items) {
          if (session.reworkClosed.contains(item.imageName)) continue;
          final staged = _reworkStaged[item.imageName];
          if (staged == null) {
            // Metadata changes no pixels. Never resolve/probe the input share
            // for it; the local recovery check below guards the whole folder.
            if (_reworkMetadataFixed.contains(item.imageName)) {
              metadataReady.add(item.reworkId);
            }
            continue;
          }
          final input = await _resolveReworkInput(item);
          final target = input.file;
          if (target == null) {
            failures.add(
              input.unreachable
                  ? '${item.imageName}: $_kInputShareDown'
                  : '${item.imageName}: could not resolve its source file',
            );
            folderBlocked = true;
            continue;
          }
          try {
            final source = await reworkSourceForItem(
              staged: staged,
              pending: () => ColorReworkStore.pending(deviceId, target.path),
            );
            if (source == null) throw StateError('Missing staged recapture');
            final inputDir = target.parent.path;
            final sidecar = File('${source.path}.color.json');
            if (!await sidecar.exists()) throw StateError('Missing recapture calibration intent; retake the page');
            final binding = ColorBinding.fromJson(Map<String, dynamic>.from(jsonDecode(await sidecar.readAsString()) as Map));
            // Persist locally before even holding the remote marker. After a
            // crash, metadata can detect interrupted work without that share.
            await ColorReworkStore.beginApply(deviceId, target.path);
            if (!flagged.contains(inputDir)) {
              // Fail closed: an unflagged folder could be fingerprinted by LWIP
              // half-replaced, so a failed flag write skips the replacement.
              await ensureReworkCaptureMarker(inputDir, {
                'project_key': item.projectKey, 'project_id': item.projectId,
                'box_name': item.boxName, 'folder_seq': item.folderSeq,
                'folder_name': item.folderName, 'device_id': deviceId,
              });
              await setReworkInProgress(inputDir, true, requireReadable: true);
              flagged.add(inputDir);
            }
            setState(() => statusMsg = 'Replacing ${item.imageName}…');
            await _overwriteReworkFileAtomically(
              source: source,
              target: target,
            );
            await updateReworkColorBinding(inputDir, p.basename(target.path), binding);
            final assignments = await db.getAssignmentsForBox(deviceId: deviceId, boxId: box.id);
            final localName = localImageNameForCloudImage(deviceId, item.imageName, assignments.keys);
            await db.saveColorBinding(deviceId, localName, binding.toJson());
            wrote++;
            recaptured.add(item.reworkId);
            verified[item.reworkId] = target;
            await _refreshSavedBoxThumbnail(box.id, item.imageName, target);
          } catch (e) {
            failedFolders.add(target.parent.path);
            print('⚠️ Rework write failed for ${item.imageName}: $e');
            failures.add('${item.imageName}: $e');
          }
        }

        if (metadataReady.isNotEmpty || recaptured.isNotEmpty) {
          try {
            await ColorReworkStore.assertMetadataSafe(
              deviceId,
              folderKey: items.first.folderKey,
              folderPath: items.first.folderPath,
              completing: [
                for (final item in items)
                  if (recaptured.contains(item.reworkId))
                    _reworkStaged[item.imageName]!,
              ],
            );
          } catch (e) {
            folderBlocked = true;
            failures.add('${items.first.folderName}: $e');
          }
        }

        for (final inputDir in flagged) {
          if (folderBlocked || failedFolders.isNotEmpty) continue;
          try {
            await setReworkInProgress(inputDir, false, requireReadable: true);
          } catch (e) {
            failedFolders.add(inputDir);
            print('⚠️ Rework: could not clear the in-progress flag: $e');
            failures.add('$inputDir: could not mark the rework finished ($e)');
          }
        }

        var closedInFolder = 0;
        final settled = <ReworkItem, String>{};
        final localDb = await db.getDatabase(deviceId);
        await localDb.transaction((txn) async {
          for (final item in items) {
            if (session.reworkClosed.contains(item.imageName)) continue;
            final target = verified[item.reworkId];
            if (folderBlocked || failedFolders.isNotEmpty) continue;
            if (target == null && !metadataReady.contains(item.reworkId)) continue;
            final resolution = recaptured.contains(item.reworkId)
                ? 'Recapture'
                : reworkResolutionFor(
                    item.imageName,
                    staged: const {}, // a staged write that failed must not close
                    metadataFixed: _reworkMetadataFixed,
                  );
            if (resolution == null) continue;
            await db.enqueueReworkClosed(
              transaction: txn,
              deviceId: deviceId,
              projectKey: item.projectKey,
              projectId: item.projectId,
              boxName: item.boxName,
              folderSeq: item.folderSeq,
              folderName: item.folderName,
              imageName: item.imageName,
              assignedUsername: username,
              reworkType: resolution,
              comment: resolution == 'Recapture'
                  ? 'Recaptured in LWCAM (was: ${item.reason})'
                  : 'Metadata corrected in LWCAM (was: ${item.reason})',
            );
            if (resolution == 'Recapture') {
              await ColorReworkStore.recordCommitted(
                txn, _reworkStaged[item.imageName]!,
              );
            }
            closedInFolder++;
            settled[item] = resolution;
          }

          final resetQcStatus = reworkShouldResetQcStatus(
            closedInFolder: closedInFolder,
            recapturedInFolder: recaptured.length,
          );
          // The metadata was already saved by Edit Metadata; it is RE-SENT here
          // rather than sending an empty patch, because the outbox coalesces on
          // (project, box, folder_seq) — a later row with no metadata would
          // REPLACE the undrained patch and silently lose the operator's edits.
          // Recomputed against the same cloud baseline, so this is always a
          // superset of what is already queued.
          final changed = _changedReworkColumns(folder, items);
          if (changed.isNotEmpty || resetQcStatus) {
            await db.enqueueFolderRework(
              transaction: txn,
              deviceId: deviceId,
              projectKey: items.first.projectKey,
              projectId: items.first.projectId,
              boxName: items.first.boxName,
              folderSeq: folder.folderSeq,
              folderName: folder.folderName ?? '',
              changedMetadata: changed,
              resetQcStatus: resetQcStatus,
              isCreatedThumbnail: items.first.isCreatedThumbnail,
            );
          }
        });
        // Only expose completion after closure AND folder update committed.
        for (final entry in settled.entries) {
          final item = entry.key;
          final resolution = entry.value;
          // The request is submitted as soon as its closure is in the outbox.
          // Drop it from the page's worklist (a partial submit must not ask
          // for it again), the open set and the staging map.
          session.reworkClosed.add(item.imageName);
          final staged = _reworkStaged.remove(item.imageName);
          _reworkMetadataFixed.remove(item.imageName);
          _reworkItems.removeWhere(
            (candidate) =>
                candidate.imageName == item.imageName &&
                candidate.folderSeq == item.folderSeq,
          );
          if (resolution == 'Recapture' && verified[item.reworkId] != null) {
            try {
              await ColorReworkStore.complete(
                deviceId,
                verified[item.reworkId]!.path,
                staged: staged,
              );
            } catch (e) {
              // The closure is already in the outbox; an intent-cleanup
              // failure must not abort the rest of the submit.
              print('⚠️ Could not clear recapture intent for ${item.imageName}: $e');
            }
          }
          closed++;
          _auditOrNull?.log(
            'rework_submit',
            details: {
              'image_name': item.imageName,
              'box_name': item.boxName,
              'folder_seq': item.folderSeq,
              'resolution': resolution,
              'qc_reason': item.reason,
            },
          );
        }
      }

      final closedKeys = await db.pendingReworkClosureKeys(deviceId);
      await OpenReworkCache.instance.refresh(
        username,
        alreadyClosedKeys: closedKeys,
      );
      if (!mounted) return;

      if (failures.isNotEmpty) {
        setState(() {
          _reworkSubmitting = false;
          statusMsg = 'Rework partly applied.';
        });
        showAppSnackBar(
          'Partly submitted',
          '${failures.length} item(s) failed: ${failures.first}'
              '${failures.length > 1 ? ' (and ${failures.length - 1} more)' : ''}. '
              'Fix the cause and submit again.',
        );
        return;
      }

      // Everything landed, so the staged photos have served their purpose.
      await session.clearReworkStaging();
      _reworkEdited.clear();

      showAppSnackBar(
        closed == 0 ? 'Metadata saved' : 'Rework submitted',
        closed == 0
            ? 'The corrections were saved. The images QC flagged are still open '
                  '— recapture them, or mark them fixed by metadata, to send the '
                  'folder back for review.'
            : '$wrote image(s) replaced, $closed request(s) closed. '
                  '${wrote > 0 ? 'The folder returns to QC once image processing finishes.' : 'The folder is back in the QC queue.'}',
      );
      // Back to the box list, which reloads the worklist and drops the badge —
      // same exit as a confirmed transfer.
      if (closed > 0) {
        Get.back();
      } else {
        setState(() {
          _reworkSubmitting = false;
          statusMsg = 'Metadata saved.';
        });
      }
    } catch (e) {
      print('⚠️ Rework submit failed: $e');
      if (!mounted) return;
      setState(() {
        _reworkSubmitting = false;
        statusMsg = 'Rework submit failed.';
      });
      showAppSnackBar('Submit failed', '$e');
    }
  }

  /// Writes [source] over [target] via a temp file + rename, so LWIP can never
  /// observe a half-written image (it polls the folder continuously).
  ///
  /// The rename is RETRIED, because on Windows replacing a file fails with
  /// "Access is denied" (errno 5) while anything else holds either path open —
  /// and this writes into a directory that LWIP watches, Defender scans (a
  /// freshly written ~16MB JPEG is exactly its trigger) and the shell may be
  /// indexing. Observed 2026-07-30: three submits in a row failed on
  /// PathAccessException with no LWIP activity in its log, so the holder was
  /// transient and external. Holders like that clear in well under a second;
  /// retrying is the difference between a failed submit and an invisible hiccup.
  ///
  /// Deliberately does NOT fall back to a plain overwrite when the retries run
  /// out: that would trade a clear error for LWIP publishing a half-written
  /// image.
  Future<void> _overwriteReworkFileAtomically({
    required File source,
    required File target,
  }) async {
    final temp = File(
      p.join(target.parent.path, '.${p.basename(target.path)}.rework_tmp'),
    );
    try {
      // A crash mid-submit can leave one behind; copy() would fail on it.
      if (await temp.exists()) await temp.delete();
      // Drop any decoded copy of the image we are about to replace. Flutter
      // holds bytes rather than a handle, so this is defensive rather than
      // known-necessary — but it is free, and it guarantees the tile re-reads
      // the new pixels instead of showing the rejected frame from cache.
      try {
        await FileImage(target).evict();
      } catch (_) {}
      await source.copy(temp.path);
      if (await temp.length() <= 0) {
        throw StateError('the replacement image copied as an empty file');
      }
      Object? lastError;
      for (var attempt = 0; attempt < kReworkRenameAttempts; attempt++) {
        try {
          await temp.rename(target.path);
          return;
        } catch (e) {
          lastError = e;
          await Future<void>.delayed(kReworkRenameRetryDelay);
        }
      }
      throw StateError(
        'could not replace ${p.basename(target.path)} after '
        '$kReworkRenameAttempts attempts. ${_describeWriteBlock(temp, target)} '
        'If the destination is BLOCKED while the temp file is writable, this is '
        "almost certainly antivirus folder protection (Avast's Ransomware "
        'Shield, Defender\'s Controlled Folder Access): those allow NEW files '
        'but refuse to let an untrusted program modify EXISTING ones, and the '
        'capture roots sit under Desktop, which they protect by default. Allow '
        'LWCAM in the shield, or move the processing roots out of Desktop / '
        'Documents (LWCam Admin -> Station Setup). '
        'Last error: $lastError',
      );
    } catch (e) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {}
      rethrow;
    }
  }

  /// Says WHICH of the two paths is unwritable when a replace fails, so the
  /// next occurrence identifies the blocker instead of guessing at it.
  ///
  /// A rename-replace needs delete access on [temp] AND on [target]; "Access is
  /// denied" alone does not say which side is held. Probing both narrows it in
  /// one line: the destination points at whatever is reading the image (an
  /// external viewer, a scanner); the temp points at whatever just touched the
  /// file we wrote (antivirus on close is the classic); neither points at
  /// directory permissions or a delete-pending state.
  ///
  /// Ruled out by measurement on 2026-07-30, so do not re-chase them: the
  /// directory itself (probe rename of a 16MB file succeeded), Dart's rename
  /// API (same probe through dart:io succeeded), the read-only attribute (all
  /// Archive), and LWIP (journal untouched since 16:38, nothing logged, and it
  /// only opens inputs for a folder it is actively reprocessing).
  /// Opens [f] for WRITE without truncating a byte, purely to see whether that
  /// is currently allowed. Append mode takes a write handle and writes nothing.
  String _probeWritable(File f) {
    try {
      if (!f.existsSync()) return 'missing';
      f.openSync(mode: FileMode.append).closeSync();
      return 'writable';
    } catch (e) {
      return 'BLOCKED ($e)';
    }
  }

  String _describeWriteBlock(File temp, File target) =>
      'Blocker probe — destination: ${_probeWritable(target)}, '
      'temp: ${_probeWritable(temp)}.';

  /// Re-renders the box's saved thumbnail for a replaced image, so the
  /// read-only box view stops showing the frame QC rejected. Best-effort: a
  /// stale thumbnail is cosmetic, not a reason to fail a submit that already
  /// wrote the file.
  Future<void> _refreshSavedBoxThumbnail(
    int boxId,
    String imageName,
    File written,
  ) async {
    try {
      final assignments = await UploadStatsDB().getAssignmentsForBox(
        deviceId: _boxSession!.deviceId,
        boxId: boxId,
      );
      final localName = localImageNameForCloudImage(
        _boxSession!.deviceId,
        imageName,
        assignments.keys,
      );
      final dir = await ThumbnailService.boxThumbsDir(
        _boxSession!.deviceId,
        boxId,
      );
      final png = await ThumbnailService.buildPngThumbnail(written);
      if (png == null) return;
      final thumbnail = File(p.join(dir.path, '$localName.png'));
      await thumbnail.writeAsBytes(png, flush: true);
      await FileImage(thumbnail).evict();
    } catch (e) {
      print('ℹ️ Could not refresh the saved thumbnail for $imageName: $e');
    }
  }

  /// QC view: run the shared box transfer flow for the active box; on full
  /// success return to the box list, else stay in QC to retry.
  Future<void> _onConfirmTransferPressed() async {
    final session = _boxSession;
    if (session == null || session.activeBox.value == null) return;
    final queued = await runBoxTransferFlow(
      context: context,
      session: session,
      box: session.activeBox.value!,
      folderCount: session.foldersOfActiveBox.length,
    );
    if (queued && mounted) {
      Get.back(); // queued for background transfer → back to the box list
    }
  }
}

/// Icon painted with the Lifewood accent gradient (e.g. the select-all button).
class _GradientIcon extends StatelessWidget {
  final IconData icon;
  final double size;

  const _GradientIcon(this.icon, {this.size = 24});

  @override
  Widget build(BuildContext context) {
    final lw = LifewoodColors.of(context);
    return ShaderMask(
      shaderCallback: (Rect bounds) {
        return LinearGradient(
          colors: [lw.accentGradientStart, lw.accentGradientEnd],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(bounds);
      },
      child: Icon(icon, size: size, color: Colors.white),
    );
  }
}
