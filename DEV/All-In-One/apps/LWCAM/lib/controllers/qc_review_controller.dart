import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:get/get.dart';

import '../models/qc_task.dart';
import '../services/pg_statements.dart' show textOrNull;
import '../services/qc_api_client.dart';

/// Drives one task's review: its pages, and which one is on screen.
///
/// Holds no editing state yet — crop, rotate, metadata and the draft stacks are
/// still the web console. This is the viewer half, which is what proves the
/// image path works end to end from Flutter: the engine resolves a Windows path
/// LWCAM wrote, renders a preview, and serves it over loopback.
class QcReviewController extends GetxController {
  QcReviewController(this.folderId);

  final int folderId;

  final loading = false.obs;
  final saving = false.obs;

  /// An image operation is in flight. Separate from [saving] so the metadata
  /// panel does not grey out while a page is being rotated.
  final working = false.obs;

  /// Pages ticked in the rail, by image id.
  ///
  /// Empty means "no selection", which is not the same as "no pages": an
  /// operation with an empty selection acts on the page on screen, so the
  /// common single-page case needs no ticking at all.
  final selected = <int>{}.obs;

  /// The viewer is in crop mode: the next drag draws a selection instead of
  /// panning the image.
  final cropping = false.obs;
  final error = ''.obs;
  final task = Rxn<QcTask>();
  final index = 0.obs;

  /// The fields the engine accepts on a metadata save. Anything outside this set
  /// is either derived (recordType), pinned by the project (the fixed fields) or
  /// not the reviewer's to change.
  static const editableKeys = <String>[
    'folderName',
    'coverTag',
    'imageTags',
    'title',
    'volume',
    'startDate',
    'endDate',
    'archivalRefNo',
    'recordType',
    'place',
    'language',
    'recordCustodian',
    'captureOperatorId',
    'captureOperatorName',
    'digitizingEntity',
  ];

  /// Working copy of the metadata, edited in the form.
  final form = <String, String?>{}.obs;

  /// Bumped every time the engine's values are adopted into [form].
  ///
  /// A TextFormField reads `initialValue` once, when its State is created, and
  /// keys that never change mean the State is reused forever - so an AI
  /// suggestion applied into the draft repainted the label and left the OLD text
  /// in the box. Keying the field on this makes an ADOPT rebuild it while typing
  /// does not, which is the distinction that matters: rebuilding per keystroke
  /// would drop focus and the cursor.
  final formRevision = 0.obs;

  /// True once the form differs from what the engine last reported.
  final dirty = false.obs;
  Map<String, String?> _saved = const {};

  /// Decoded previews, keyed by the image's own `previewUrl`.
  ///
  /// The URL carries the engine's `v=` stamp, which changes whenever the image
  /// or the reviewer's draft of it does — so keying on it means an edited page
  /// can never serve its stale bytes, and no manual invalidation is needed.
  final _previews = <String, Uint8List>{};

  /// Each preview's own pixel dimensions.
  ///
  /// Crop coordinates are expressed in these, and sent alongside them, because
  /// the engine scales the rectangle by `source.width / previewWidth` to reach
  /// the full-resolution draft. Guessing the size would crop the wrong area.
  final _previewSizes = <String, ui.Size>{};

  QcApiClient get _api => QcApiClient.instance;

  QcTaskImage? get current {
    final images = task.value?.images ?? const <QcTaskImage>[];
    if (images.isEmpty) return null;
    return images[index.value.clamp(0, images.length - 1)];
  }

  Uint8List? previewFor(QcTaskImage image) => _previews[image.previewUrl];

  /// Intrinsic size of the decoded preview, once it has loaded.
  ui.Size? previewSizeFor(QcTaskImage image) => _previewSizes[image.previewUrl];

  @override
  void onInit() {
    super.onInit();
    load();
  }

  Future<void> load() async {
    loading.value = true;
    try {
      final detail = await _api.task(folderId);
      // Before _adopt, which prunes rather than clears: a reload is a fresh
      // start on this folder, so nothing carries over from the last one.
      selected.clear();
      _adopt(QcTask.fromJson(detail));
      index.value = 0;
      await _loadCurrentPreview();
    } on QcApiException catch (e) {
      error.value = e.message;
      task.value = null;
    } finally {
      loading.value = false;
    }
  }

  Future<void> show(int newIndex) async {
    final images = task.value?.images ?? const <QcTaskImage>[];
    if (images.isEmpty) return;
    // A rectangle drawn on one page means nothing on the next, and the overlay
    // would happily send it - crop what you can see, or nothing.
    cropping.value = false;
    index.value = newIndex.clamp(0, images.length - 1);
    await _loadCurrentPreview();
  }

  Future<void> next() => show(index.value + 1);
  Future<void> previous() => show(index.value - 1);

  /// Moves the viewer to a page by its image id.
  ///
  /// AI review evidence names the page by id; the rail is indexed. Does nothing
  /// for an id that is no longer in the folder - a finding can outlive the page
  /// it cites if the reviewer deleted it since.
  Future<void> showImageById(int imageId) async {
    final images = task.value?.images ?? const <QcTaskImage>[];
    final at = images.indexWhere((image) => image.id == imageId);
    if (at >= 0) await show(at);
  }

  /// Takes a task from the engine as the new truth, resetting the form to it.
  void _adopt(QcTask value) {
    // Every edit restamps the page's `v=`, so its old preview can never be
    // served again. Draft previews come back at full working size - measured at
    // 463 KB against 91 KB for the captured original - so keeping the
    // superseded ones would grow the cache by megabytes over a long review.
    final live = value.images.map((image) => image.previewUrl).toSet();
    _previews.removeWhere((url, _) => !live.contains(url));
    _previewSizes.removeWhere((url, _) => !live.contains(url));

    task.value = value;
    // Delete shortens the list under the cursor, so the raw index can outrun it
    // - `current` clamps on read, but the page strip and the nav buttons read
    // `index.value` directly and would point past the end.
    final count = value.images.length;
    if (count > 0 && index.value > count - 1) index.value = count - 1;

    // Same reason, for the ticks: a deleted page must not stay selected and
    // silently join the next batch. Undo brings the page back but not its tick,
    // which is the safer of the two directions to be wrong in.
    final liveIds = value.images.map((image) => image.id).toSet();
    if (selected.any((id) => !liveIds.contains(id))) {
      selected.removeWhere((id) => !liveIds.contains(id));
    }

    final values = <String, String?>{
      for (final key in editableKeys) key: textOrNull(value.metadata[key]),
    };
    // Derive on load, not only on edit. The stored value was written under
    // whatever template was current then; if the project's mapping has changed
    // since, the folder's own row is stale and showing it would present a value
    // the next save overwrites. The template is the authority.
    value.template.applyMappings(values);
    form.value = values;
    formRevision.value++;
    _saved = Map<String, String?>.from(values);
    dirty.value = false;
    error.value = '';
  }

  void setField(String key, String? value) {
    final normalized = (value?.trim().isEmpty ?? true) ? null : value!.trim();
    form[key] = normalized;
    _deriveMapped(key);
    dirty.value = !_matchesSaved();
  }

  /// Recomputes the fields the project maps FROM [changedKey].
  ///
  /// The engine rewrites every mapped field on save, so mirroring it here is
  /// what stops the form showing a value the engine is about to replace. Which
  /// fields those are is the project's decision, not this app's: a template can
  /// map Record Type from Title, Start Date from Title, or nothing at all.
  void _deriveMapped(String changedKey) {
    final template = task.value?.template;
    if (template == null) return;
    final mapped = template.mappedFieldsFrom(changedKey);
    if (mapped.isNotEmpty) {
      final next = Map<String, String?>.from(form);
      template.applyMappings(next);
      for (final field in mapped) {
        form[field.key] = next[field.key];
      }
    }
    // The legacy top-level titleRecordTypeMap, for templates written before
    // per-field mapping existed. Skipped once recordType is mapped properly, so
    // a project that has moved on is not overruled by the older shape.
    if (changedKey == 'title' && template.fieldFor('recordType')?.isMapped != true) {
      form['recordType'] = template.recordTypeFor(form['title']);
    }
  }

  bool _matchesSaved() {
    for (final key in editableKeys) {
      if ((form[key] ?? '') != (_saved[key] ?? '')) return false;
    }
    return true;
  }

  /// Fields the operator must fill before this task can be approved. Draft saves
  /// are allowed without them - half-keyed work still deserves to survive a
  /// crash - so this only drives the warning.
  List<QcMetadataField> get missingMandatory {
    final fields = task.value?.template.fields ?? const <QcMetadataField>[];
    return fields
        .where((field) =>
            field.mandatory &&
            !field.isFixed &&
            (form[field.key] ?? '').isEmpty)
        .toList();
  }

  Future<bool> save() async {
    final current = task.value;
    if (current == null) return false;
    saving.value = true;
    try {
      final payload = <String, Object?>{
        for (final key in editableKeys)
          if (form[key] != null) key: form[key],
      };
      final updated = await _api.saveMetadata(
        current.folderId,
        current.sourceHash,
        payload,
      );
      _adopt(QcTask.fromJson(updated));
      return true;
    } on QcApiException catch (e) {
      error.value = e.message;
      return false;
    } finally {
      saving.value = false;
    }
  }

  bool get canEdit => task.value?.assignedTo != null;

  /// True once QC has finished with this folder.
  ///
  /// A settled folder is not merely unclaimed - it can never be claimed again
  /// (the engine's claim query matches `qc_status = 'pending'` only), so
  /// telling the operator to claim it is advice they cannot act on.
  bool get isSettled {
    final status = task.value?.status.toUpperCase();
    return status == 'PASS' || status == 'REWORK';
  }

  /// The pages the next operation acts on.
  ///
  /// Returned in page order rather than set order, so a batch call and its audit
  /// entry read the way the rail looks. With nothing ticked this is the page on
  /// screen, which keeps every single-page gesture working untouched.
  List<int> get targetIds {
    final images = task.value?.images ?? const <QcTaskImage>[];
    if (selected.isNotEmpty) {
      return [
        for (final image in images)
          if (selected.contains(image.id)) image.id,
      ];
    }
    final image = current;
    return image == null ? const [] : [image.id];
  }

  /// Ticks or unticks one page. The page on screen does not move.
  void toggleSelect(int imageId) {
    if (!selected.remove(imageId)) selected.add(imageId);
  }

  /// Ticks every page between two positions, inclusive, keeping what was already
  /// ticked.
  ///
  /// Unions rather than replaces, and leaves the page on screen where it is -
  /// the same shape as the web console, so shift-clicking means one thing across
  /// both clients. Broken pages are skipped: no operation can act on them, so
  /// ticking one would only misreport what a batch is about to do.
  void selectRange(int fromIndex, int toIndex) {
    final images = task.value?.images ?? const <QcTaskImage>[];
    if (images.isEmpty) return;
    final last = images.length - 1;
    final start = fromIndex.clamp(0, last);
    final end = toIndex.clamp(0, last);
    for (var i = start <= end ? start : end; i <= (start <= end ? end : start); i++) {
      if (images[i].available) selected.add(images[i].id);
    }
  }

  /// Ticks every usable page, or clears the selection entirely.
  void setSelectAll(bool value) {
    if (!value) {
      selected.clear();
      return;
    }
    final images = task.value?.images ?? const <QcTaskImage>[];
    selected.addAll([
      for (final image in images)
        if (image.available) image.id,
    ]);
  }

  /// True when every usable page is ticked. Drives the rail's tristate checkbox.
  bool get allSelected {
    final usable = (task.value?.images ?? const <QcTaskImage>[])
        .where((image) => image.available);
    return usable.isNotEmpty && usable.every((image) => selected.contains(image.id));
  }

  /// Runs one operation and adopts whatever the engine reports back.
  ///
  /// Every image endpoint returns the whole task, so there is nothing to merge:
  /// the new preview URLs carry fresh `v=` stamps, which is what makes the
  /// edited page reload instead of showing its old bytes.
  Future<bool> _run(Future<Map<String, Object?>> Function() action) async {
    if (!canEdit) return false;
    working.value = true;
    try {
      _adopt(QcTask.fromJson(await action()));
      await _loadCurrentPreview();
      return true;
    } on QcApiException catch (e) {
      error.value = e.message;
      return false;
    } finally {
      working.value = false;
    }
  }

  Future<bool> rotate(int degrees) {
    final task = this.task.value;
    if (task == null) return Future.value(false);
    final ids = targetIds;
    if (ids.isEmpty) return Future.value(false);
    return _run(() => ids.length == 1
        ? _api.rotate(task.folderId, ids.first, task.sourceHash, degrees)
        : _api.rotateBatch(task.folderId, task.sourceHash, ids, degrees));
  }

  /// Degrees the straighten buttons apply per click.
  ///
  /// The reviewer sets this: 1 is the common nudge, but a page that came off the
  /// glass slightly askew often needs half a degree, and the old fixed 1 could
  /// only overshoot it. Session-only on purpose - it is a property of the batch
  /// being worked through, not of the operator, and carrying it across folders
  /// would silently apply the last folder's step to the next one.
  final deskewStep = 1.0.obs;

  static const deskewStepMin = 0.1;
  static const deskewStepMax = 10.0;

  /// Clamps and stores the step, ignoring anything unparseable so a half-typed
  /// entry cannot leave the field holding a value the engine would reject.
  void setDeskewStep(double degrees) {
    if (degrees.isNaN) return;
    deskewStep.value =
        degrees.clamp(deskewStepMin, deskewStepMax).toDouble();
  }

  /// Straightens by [deskewStep] in [direction] (-1 left, 1 right).
  Future<bool> deskew(int direction) {
    final task = this.task.value;
    if (task == null) return Future.value(false);
    final ids = targetIds;
    if (ids.isEmpty) return Future.value(false);
    final degrees = deskewStep.value * direction.sign;
    return _run(() => ids.length == 1
        ? _api.deskew(task.folderId, ids.first, task.sourceHash, degrees)
        : _api.deskewBatch(task.folderId, task.sourceHash, ids, degrees));
  }

  Future<bool> luminance() {
    final task = this.task.value;
    if (task == null) return Future.value(false);
    final ids = targetIds;
    if (ids.isEmpty) return Future.value(false);
    return _run(() => ids.length == 1
        ? _api.luminance(task.folderId, ids.first, task.sourceHash)
        : _api.luminanceBatch(task.folderId, task.sourceHash, ids));
  }

  Future<bool> restoreOriginal() {
    final task = this.task.value;
    final image = current;
    if (task == null || image == null) return Future.value(false);
    return _run(() =>
        _api.restoreOriginal(task.folderId, image.id, task.sourceHash));
  }

  /// Crops the page on screen.
  ///
  /// [rect] is in the preview's own pixels — the overlay maps the operator's
  /// drag out of screen space before calling this, since the image is drawn
  /// scaled to fit.
  Future<bool> crop(ui.Rect rect) {
    final task = this.task.value;
    final image = current;
    if (task == null || image == null) return Future.value(false);
    final size = previewSizeFor(image);
    if (size == null) return Future.value(false);

    // A stray click is a zero-size rectangle; the engine would reject it, but
    // refusing here keeps a misclick from looking like a server error.
    final width = rect.width.round();
    final height = rect.height.round();
    if (width < 1 || height < 1) return Future.value(false);

    return _run(() => _api.crop(
          task.folderId,
          image.id,
          task.sourceHash,
          x: rect.left.round(),
          y: rect.top.round(),
          width: width,
          height: height,
          previewWidth: size.width.round(),
          previewHeight: size.height.round(),
        )).then((ok) {
      if (ok) cropping.value = false;
      return ok;
    });
  }

  /// The page order after moving the page at [from] to sit at [to].
  ///
  /// [to] is the index in the list once the page has been lifted out, which is
  /// what a drag actually means. Kept pure because the engine rejects any list
  /// that is not an exact permutation of the current one - an off-by-one here is
  /// a rejected request, or worse, a silently wrong page order in the export.
  static List<int> reorderedIds(List<int> ids, int from, int to) {
    if (from < 0 || from >= ids.length) return ids;
    final moved = List<int>.from(ids);
    final id = moved.removeAt(from);
    moved.insert(to.clamp(0, moved.length), id);
    return moved;
  }

  /// Moves the page at [from] to [to] and keeps it on screen.
  Future<bool> moveImage(int from, int to) async {
    final task = this.task.value;
    if (task == null) return false;
    final ids = task.images.map((image) => image.id).toList();
    final next = reorderedIds(ids, from, to);
    // Nothing actually moved: skip the round trip rather than ask the engine to
    // rewrite the order it already has.
    var same = next.length == ids.length;
    for (var i = 0; same && i < ids.length; i++) {
      if (ids[i] != next[i]) same = false;
    }
    if (same) return true;

    final moved = ids[from];
    final ok =
        await _run(() => _api.reorder(task.folderId, task.sourceHash, next));
    if (ok) {
      index.value = next.indexOf(moved).clamp(0, next.length - 1);
      await _loadCurrentPreview();
    }
    return ok;
  }

  /// Drops the ticked pages - or the page on screen - from the draft.
  ///
  /// The engine refuses to leave the folder empty, and undo brings the pages
  /// back - the captured files are untouched either way. A batch is validated
  /// whole before anything is removed, so a request that would empty the folder
  /// deletes nothing rather than stopping on the last page.
  Future<bool> deleteSelected() {
    final task = this.task.value;
    if (task == null) return Future.value(false);
    final ids = targetIds;
    if (ids.isEmpty) return Future.value(false);
    return _run(() => ids.length == 1
        ? _api.deleteImage(task.folderId, ids.first, task.sourceHash)
        : _api.deleteBatch(task.folderId, task.sourceHash, ids));
  }

  /// Extensions the engine accepts on an insert. Checking here turns a rejected
  /// upload into an immediate message instead of a round trip carrying a file.
  static const uploadExtensions = <String>['jpg', 'jpeg', 'png', 'tif', 'tiff'];

  /// Adds a page in front of the one on screen.
  ///
  /// The caller supplies the bytes: picking a file is the view's job, which
  /// keeps this testable and stops the controller depending on a plugin.
  Future<bool> insertBefore(String filename, List<int> bytes) async {
    final task = this.task.value;
    final image = current;
    if (task == null || image == null) return false;

    final dot = filename.lastIndexOf('.');
    final extension = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
    if (!uploadExtensions.contains(extension)) {
      error.value = 'Only ${uploadExtensions.join(', ')} files can be inserted.';
      return false;
    }
    if (bytes.isEmpty) {
      error.value = 'That file is empty.';
      return false;
    }

    // The new page takes this slot and pushes the current one along, so holding
    // the index shows the operator what they just added.
    return _run(() => _api.insertBefore(
          task.folderId,
          image.id,
          task.sourceHash,
          filename: filename,
          bytes: bytes,
        ));
  }

  /// Replaces the current page's bytes, keeping its name.
  ///
  /// Same validation as [insertBefore] - the difference is only what the engine
  /// does with the file, and that the page keeps its own name rather than
  /// taking the uploaded one.
  Future<bool> replaceImage(String filename, List<int> bytes) async {
    final task = this.task.value;
    final image = current;
    if (task == null || image == null) return false;

    final dot = filename.lastIndexOf('.');
    final extension = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
    if (!uploadExtensions.contains(extension)) {
      error.value = 'Only ${uploadExtensions.join(', ')} files can replace a page.';
      return false;
    }
    if (bytes.isEmpty) {
      error.value = 'That file is empty.';
      return false;
    }

    return _run(() => _api.replaceImage(
          task.folderId,
          image.id,
          task.sourceHash,
          filename: filename,
          bytes: bytes,
        ));
  }

  /// True once the task has been approved or rejected and is no longer ours.
  final finished = false.obs;

  /// A terminal action is in flight.
  final finalizing = false.obs;

  /// Pages the engine will accept for rework.
  ///
  /// A page added during review has no row in the database yet - the draft
  /// numbers its own additions negatively - so there is nothing to attach a
  /// rework log to and the engine refuses the whole request if one is named.
  List<QcTaskImage> get officialImages =>
      task.value?.images.where((image) => image.id > 0).toList() ??
      const <QcTaskImage>[];

  /// Why the folder cannot be approved yet, or null when it can be.
  ///
  /// Mirrors the engine's own approval checks so the reviewer is told before
  /// committing rather than after being refused.
  String? get blocksApproval {
    final task = this.task.value;
    if (task == null) return 'This task is not loaded.';
    if (!canEdit) return 'Claim this task before approving it.';
    if (task.images.isEmpty) return 'A folder with no pages cannot be approved.';

    final missing = missingMandatory;
    if (missing.isNotEmpty) {
      return 'Fill in ${missing.map((f) => f.label).join(', ')} first.';
    }
    return null;
  }

  /// Approves the folder, committing the draft.
  ///
  /// Saves any unsaved metadata first: the operator pressing Approve means the
  /// values on screen, and approving the previously-saved draft instead would
  /// discard their typing without saying so.
  Future<bool> approve({String? comment}) async {
    final task = this.task.value;
    if (task == null || finalizing.value) return false;
    if (blocksApproval != null) {
      error.value = blocksApproval!;
      return false;
    }

    finalizing.value = true;
    try {
      if (dirty.value && !await save()) return false;
      // save() adopts a new task; take the hash from whatever is current now.
      final current = this.task.value;
      if (current == null) return false;
      await _api.approve(current.folderId, current.sourceHash, comment: comment);
      finished.value = true;
      return true;
    } on QcApiException catch (e) {
      error.value = e.message;
      return false;
    } finally {
      finalizing.value = false;
    }
  }

  /// Sends the folder back for rework.
  ///
  /// [reasons] must name at least one official page and give each a reason. The
  /// reviewer's draft is discarded by the engine, so anything they edited is
  /// gone - the caller is expected to have said so.
  Future<bool> reject(Map<int, String> reasons, {String? comment}) async {
    final task = this.task.value;
    if (task == null || finalizing.value) return false;
    if (!canEdit) {
      error.value = 'Claim this task before sending it back.';
      return false;
    }
    final cleaned = <int, String>{
      for (final entry in reasons.entries)
        if (entry.value.trim().isNotEmpty) entry.key: entry.value.trim(),
    };
    if (cleaned.isEmpty) {
      error.value = 'Choose at least one page and say what is wrong with it.';
      return false;
    }

    finalizing.value = true;
    try {
      await _api.reject(task.folderId, task.sourceHash, cleaned,
          comment: comment);
      finished.value = true;
      return true;
    } on QcApiException catch (e) {
      error.value = e.message;
      return false;
    } finally {
      finalizing.value = false;
    }
  }

  /// Writes AI suggestions into the metadata draft.
  ///
  /// Goes through the same path as any other edit so the returned task is
  /// adopted and the form reloads from it - the reviewer sees the applied values
  /// in the fields, not a panel claiming they were written.
  ///
  /// [inputHash] is the engine's own staleness check: it refuses if the folder
  /// or any named field moved since the review looked at it.
  Future<bool> applyAiSuggestions(String inputHash, List<String> fieldKeys) {
    final task = this.task.value;
    if (task == null || fieldKeys.isEmpty) return Future.value(false);
    return _run(() => _api.applyAiReview(
          task.folderId,
          task.sourceHash,
          inputHash,
          fieldKeys,
        ));
  }

  Future<bool> undo() {
    final task = this.task.value;
    if (task == null) return Future.value(false);
    return _run(() => _api.undo(task.folderId));
  }

  Future<bool> redo() {
    final task = this.task.value;
    if (task == null) return Future.value(false);
    return _run(() => _api.redo(task.folderId));
  }

  /// Reads a preview's pixel dimensions.
  ///
  /// The decoded frame is disposed immediately: only the size is wanted, and
  /// holding every page's decoded image would pin GPU memory for a folder the
  /// reviewer may only be scrolling past.
  static Future<ui.Size> _measure(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    try {
      final frame = await codec.getNextFrame();
      final size = ui.Size(
        frame.image.width.toDouble(),
        frame.image.height.toDouble(),
      );
      frame.image.dispose();
      return size;
    } finally {
      codec.dispose();
    }
  }

  Future<void> _loadCurrentPreview() => ensurePreview(current);

  /// How many previews may be in flight at once.
  ///
  /// The rail asks for a preview per visible tile, and the engine renders them
  /// one at a time from full-resolution scans. Unbounded, a fast scroll through
  /// a forty-page folder queues forty ~200KB renders and the page an operator
  /// is actually looking at waits behind all of them.
  static const _maxConcurrentPreviews = 4;
  int _previewsInFlight = 0;
  final _previewQueue = <QcTaskImage>[];

  /// Downloads [image]'s preview unless it is already cached or in flight.
  ///
  /// Shared by the viewer and every rail tile, so both read the same cache and
  /// a page already fetched for the rail costs nothing to open.
  Future<void> ensurePreview(QcTaskImage? image) async {
    if (image == null || !image.available) return;
    if (_previews.containsKey(image.previewUrl)) return;
    if (_previewsInFlight >= _maxConcurrentPreviews) {
      if (!_previewQueue.any((q) => q.previewUrl == image.previewUrl)) {
        _previewQueue.add(image);
      }
      return;
    }

    _previewsInFlight++;
    try {
      final bytes = await _api.previewBytes(
        image.previewUrl,
        // 30s is not enough for a cold render of a large TIFF; the engine
        // caches to disk afterwards, so only the first view is slow.
        timeout: const Duration(seconds: 60),
      );
      _previews[image.previewUrl] = bytes;
      _previewSizes[image.previewUrl] = await _measure(bytes);
      // The map is not observable — bump an observable the view watches so a
      // finished download repaints without making every byte array reactive.
      index.refresh();
      error.value = '';
    } on QcApiException catch (e) {
      // A tile that cannot be fetched shows its placeholder; only the page
      // being READ is worth interrupting the operator over.
      if (identical(image, current)) error.value = e.message;
    } finally {
      _previewsInFlight--;
      if (_previewQueue.isNotEmpty) {
        unawaited(ensurePreview(_previewQueue.removeAt(0)));
      }
    }
  }
}
