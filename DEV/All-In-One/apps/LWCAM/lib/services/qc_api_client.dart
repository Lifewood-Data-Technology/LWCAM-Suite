// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'qc_engine_service.dart';

/// A failure the QC engine reported deliberately, with a message written for
/// the operator.
///
/// Every engine response is `{code, message, data}`, and `message` is prose the
/// backend intends a human to read — its own error handler says so, and there is
/// a test forbidding non-English text in it. So it is shown as-is rather than
/// replaced with something vaguer.
class QcApiException implements Exception {
  final int code;
  final String message;
  final int? statusCode;

  QcApiException(this.code, this.message, {this.statusCode});

  /// True when the token is missing, expired or rejected — the caller should
  /// sign in again rather than show this to the operator.
  bool get isUnauthorized => statusCode == 401;

  @override
  String toString() => message;
}

/// Talks to the QC engine sidecar on loopback.
///
/// Deliberately built on `dart:io`'s HttpClient rather than adding an HTTP
/// package: this app has no HTTP dependency today, the API is a handful of JSON
/// endpoints, and the envelope unwrapping below is the only shared logic a
/// package would have saved.
///
/// Holds the JWT in memory only. It is never written to disk: the engine is
/// local, the token is short-lived, and a token on disk outlives the session it
/// belongs to.
class QcApiClient {
  QcApiClient._();
  static final QcApiClient instance = QcApiClient._();

  String? _token;
  int? _userId;

  /// The credentials the operator signed in with, kept in memory for the life
  /// of the LWCAM session so a sign-in that failed at login - the engine was
  /// still booting, the usual case after a Station Setup save restarts it -
  /// is retried the first time a QC screen actually needs a session, and a
  /// token the engine later rejects is replaced without a logout.
  ///
  /// Memory only, same as the token, and dropped by [signOut]. A second copy
  /// of a password is a real cost; a QC screen that stays broken until the
  /// operator logs out and back in was the larger one.
  ({String username, String password})? _credentials;

  bool get hasSession => _token != null;
  int? get userId => _userId;

  /// Whether a call can obtain a session on its own: credentials are held.
  bool get canRetrySignIn => _credentials != null;

  /// Why the last sign-in attempt failed, or null if it succeeded or none has
  /// been made.
  ///
  /// Sign-in happens once at login, unawaited, so its failure surfaced only as
  /// a `print` nobody sees in an installed build. The operator then met a bare
  /// "Not signed in to the QC engine" on a screen three clicks away, with the
  /// actual reason - wrong password, engine still booting, engine not running -
  /// thrown away. Keeping it here lets [notSignedInMessage] say WHICH, at the
  /// point the caller is actually blocked.
  String? _signInError;
  String? get signInError => _signInError;

  /// The message a caller gets when there is no session.
  ///
  /// Pure and static so the composition is testable without a server - that is
  /// the part that was missing: the reason existed and never reached the
  /// message.
  static String notSignedInMessage(String? reason) => reason == null
      ? 'Not signed in to the QC engine.'
      : 'Not signed in to the QC engine: $reason';

  /// Drops the token. Called whenever the engine rejects it so a stale one is
  /// never retried forever; the credentials stay so the next call signs in
  /// again. Logout uses [signOut].
  void clearSession() {
    _token = null;
    _userId = null;
  }

  /// Logout: drops the token AND the credentials, so the next operator at this
  /// PC can neither inherit the last one's session nor have it re-created.
  void signOut() {
    clearSession();
    _credentials = null;
    _signInError = null;
  }

  /// Makes sure there is a token before an authenticated call, signing in
  /// with the held credentials when there is none. Throws the same
  /// not-signed-in error as before when nothing can be done.
  Future<void> _ensureSession() async {
    if (_token != null) return;
    final credentials = _credentials;
    if (credentials == null) {
      throw QcApiException(
        401,
        notSignedInMessage(_signInError),
        statusCode: 401,
      );
    }
    try {
      await _signIn(credentials.username, credentials.password);
      _signInError = null;
    } catch (e) {
      _signInError = e is QcApiException ? e.message : e.toString();
      throw QcApiException(
        401,
        notSignedInMessage(_signInError),
        statusCode: 401,
      );
    }
  }

  Uri _uri(String path, [Map<String, String>? query]) =>
      QcEngineService.baseUri.replace(
        path: '/api$path',
        queryParameters: query == null || query.isEmpty ? null : query,
      );

  /// Signs in against the engine and keeps the token.
  ///
  /// Same credentials the operator already typed into LWCAM: both sides verify
  /// the SAME bcrypt hash in `users.password`, deliberately interoperable (the
  /// engine pins prefix `2a`, cost 10, 72-byte truncation to match Dart's
  /// bcrypt). So this is not a second account, just a second door to one.
  Future<void> signIn(String username, String password) async {
    _credentials = (username: username, password: password);
    try {
      await _signIn(username, password);
      _signInError = null;
    } catch (e) {
      // Recorded, then rethrown: the caller at login still decides whether to
      // wait or complain, but the reason is no longer lost when it does.
      _signInError = e is QcApiException ? e.message : e.toString();
      rethrow;
    }
  }

  Future<void> _signIn(String username, String password) async {
    final data = await _send(
      'POST',
      _uri('/auth/login'),
      body: {'username': username, 'password': password},
      authenticated: false,
    );
    final map = data as Map<String, Object?>;
    _token = map['token'] as String?;
    final user = map['user'];
    _userId = user is Map<String, Object?> ? user['id'] as int? : null;
    if (_token == null) {
      throw QcApiException(-1, 'The QC engine did not return a session token.');
    }
  }

  /// One page of QC tasks. `scope` is pending, mine or completed.
  ///
  /// [query] filters the COMPLETED scope by Group ID, group name or folder
  /// name. Sent to the engine rather than filtered here: the list is paged, so
  /// filtering a page locally would show short pages and a total counting rows
  /// the operator cannot see.
  Future<Map<String, Object?>> tasks({
    String scope = 'pending',
    String? query,
    int page = 1,
    int size = 20,
  }) async {
    final trimmed = query?.trim() ?? '';
    final data = await _send(
      'GET',
      _uri('/qc/metadata-tasks', {
        'scope': scope,
        if (trimmed.isNotEmpty) 'q': trimmed,
        'page': '$page',
        'size': '$size',
      }),
    );
    return (data as Map<String, Object?>?) ?? const {};
  }

  /// Claims a specific folder. One task per person: the engine enforces this
  /// with a row lock, so a second claimer gets a plain refusal, not a race.
  Future<Map<String, Object?>> claim(int folderId) async {
    final data = await _send(
      'POST',
      _uri('/qc/metadata-tasks/$folderId/claim'),
    );
    return (data as Map<String, Object?>?) ?? const {};
  }

  /// Claims the oldest available folder in the caller's projects.
  Future<Map<String, Object?>> claimNext() async {
    final data = await _send('POST', _uri('/qc/metadata-tasks/claim-next'));
    return (data as Map<String, Object?>?) ?? const {};
  }

  /// Sends a finished folder back to QC as a CLIENT rework, and claims it.
  ///
  /// The client has asked for changes to work already delivered. The folder
  /// returns to pending carrying the rework flag, keeps its Group ID so the
  /// corrected package replaces the original rather than arriving beside it,
  /// and is claimed by the caller so they land straight in the review screen.
  ///
  /// [sourceHash] guards against reverting from a stale list. The engine
  /// refuses with 409 if the caller already holds another task.
  Future<Map<String, Object?>> revert(int folderId, String sourceHash) async {
    final data = await _send(
      'POST',
      _uri('/qc/metadata-tasks/$folderId/revert'),
      body: {'sourceHash': sourceHash},
    );
    return (data as Map<String, Object?>?) ?? const {};
  }

  /// Releases a claim so somebody else can pick the folder up.
  Future<void> release(int folderId) =>
      _send('POST', _uri('/qc/metadata-tasks/$folderId/release'));

  /// One task in full, including its image list.
  Future<Map<String, Object?>> task(int folderId) async {
    final data = await _send('GET', _uri('/qc/metadata-tasks/$folderId'));
    return (data as Map<String, Object?>?) ?? const {};
  }

  /// Saves metadata edits into the reviewer's DRAFT.
  ///
  /// Nothing reaches `capture_folders` until the task is approved - the engine
  /// keeps every edit in a manifest on disk, so an abandoned review leaves the
  /// captured row untouched.
  ///
  /// [sourceHash] is echoed back so the engine can refuse an edit written
  /// against images that have changed since the task was opened, and the caller
  /// must hold the lock: reading a task is open to anyone who can see it,
  /// writing is not.
  Future<Map<String, Object?>> saveMetadata(
    int folderId,
    String sourceHash,
    Map<String, Object?> metadata,
  ) async {
    final data = await _send(
      'PUT',
      _uri('/qc/metadata-tasks/$folderId/metadata'),
      body: {'sourceHash': sourceHash, 'metadata': metadata},
    );
    return (data as Map<String, Object?>?) ?? const {};
  }

  /// Crops one page.
  ///
  /// The rectangle is in the PREVIEW's own pixels, and [previewWidth] /
  /// [previewHeight] tell the engine which preview it was drawn on: it scales by
  /// `source.width / previewWidth` to reach the full-resolution draft. Sending
  /// the rect without the dimensions would crop a fraction of the intended area,
  /// because the engine then assumes source coordinates.
  Future<Map<String, Object?>> crop(
    int folderId,
    int imageId,
    String sourceHash, {
    required int x,
    required int y,
    required int width,
    required int height,
    required int previewWidth,
    required int previewHeight,
  }) => _mutateTask('/qc/metadata-tasks/$folderId/images/$imageId/crop', {
    'sourceHash': sourceHash,
    'x': x,
    'y': y,
    'width': width,
    'height': height,
    'previewWidth': previewWidth,
    'previewHeight': previewHeight,
  });

  /// Approves the folder: the draft becomes the real thing.
  ///
  /// This is the one call in the review screen that writes to `capture_folders`.
  /// The engine commits the draft, moves any separated pages on disk, marks the
  /// folder PASS and releases the claim. There is no undo afterwards - the draft
  /// it was built from is discarded.
  ///
  /// Answers 400 when a mandatory field is empty or the dates are the wrong way
  /// round, so it is worth checking both before asking.
  Future<void> approve(int folderId, String sourceHash, {String? comment}) =>
      _send(
        'POST',
        _uri('/qc/metadata-tasks/$folderId/approve'),
        body: {
          'sourceHash': sourceHash,
          if (comment != null && comment.isNotEmpty) 'comment': comment,
        },
      );

  /// Sends the folder back for rework.
  ///
  /// [reasons] maps an image id to why that page needs redoing; the engine
  /// requires at least one and a non-empty reason for each, and every id must be
  /// an OFFICIAL page - a page added in the draft has no row to attach a rework
  /// log to and is refused.
  ///
  /// The folder goes to REWORK, its deskew/crop/thumbnail flags are cleared so
  /// the pipeline redoes them, and the reviewer's draft is DISCARDED.
  Future<void> reject(
    int folderId,
    String sourceHash,
    Map<int, String> reasons, {
    String? comment,
  }) => _send(
    'POST',
    _uri('/qc/metadata-tasks/$folderId/reject'),
    body: {
      'sourceHash': sourceHash,
      if (comment != null && comment.isNotEmpty) 'comment': comment,
      'rejectedImages': [
        for (final entry in reasons.entries)
          {'imageId': entry.key, 'rejectReason': entry.value},
      ],
    },
  );

  /// Starts an AI metadata review, or hands back the one already running.
  ///
  /// [force] asks for a fresh run rather than reusing a finished job. The engine
  /// answers 503 when AI review is switched off in LWCam Admin, which is a
  /// setting rather than a failure - the caller says so instead of retrying.
  Future<Map<String, Object?>> startAiReview(
    int folderId,
    String sourceHash, {
    bool force = false,
  }) async {
    final data = await _send(
      'POST',
      _uri('/qc/metadata-tasks/$folderId/ai-review/jobs'),
      body: {'sourceHash': sourceHash, 'force': force},
    );
    return (data as Map<String, Object?>?) ?? const {};
  }

  /// Progress for one job. Only the reviewer holding the claim may read it.
  Future<Map<String, Object?>> aiReviewJob(int folderId, String jobId) async {
    final data = await _send(
      'GET',
      _uri('/qc/metadata-tasks/$folderId/ai-review/jobs/$jobId'),
    );
    return (data as Map<String, Object?>?) ?? const {};
  }

  /// The most recent review for this folder, or null when there has never been
  /// one. A null here is an answer, not a failure.
  Future<Map<String, Object?>?> latestAiReview(int folderId) async {
    final data = await _send(
      'GET',
      _uri('/qc/metadata-tasks/$folderId/ai-review/latest'),
    );
    return data as Map<String, Object?>?;
  }

  /// Writes the chosen suggestions into the metadata draft.
  ///
  /// [inputHash] pins the review to the folder state it examined; the engine
  /// answers 409 if either the folder or any of the named fields has moved since,
  /// rather than overwriting a newer value with an older opinion.
  Future<Map<String, Object?>> applyAiReview(
    int folderId,
    String sourceHash,
    String inputHash,
    List<String> fieldKeys,
  ) => _mutateTask('/qc/metadata-tasks/$folderId/ai-review/apply', {
    'sourceHash': sourceHash,
    'inputHash': inputHash,
    'fieldKeys': fieldKeys,
  });

  /// Removes one page from the draft.
  ///
  /// The engine refuses to delete the last remaining page, so a folder can
  /// never review down to nothing. Undo puts it back.
  Future<Map<String, Object?>> deleteImage(
    int folderId,
    int imageId,
    String sourceHash,
  ) => _mutateTask('/qc/metadata-tasks/$folderId/images/$imageId/delete', {
    'sourceHash': sourceHash,
  });

  /// Removes several pages from the draft in one call.
  ///
  /// The engine validates the whole list before deleting anything, so a batch
  /// that would empty the folder is refused outright rather than applied down
  /// to the last page.
  Future<Map<String, Object?>> deleteBatch(
    int folderId,
    String sourceHash,
    List<int> imageIds,
  ) => _mutateTask('/qc/metadata-tasks/$folderId/images/delete-batch', {
    'sourceHash': sourceHash,
    'imageIds': imageIds,
  });

  /// Sets the page order.
  ///
  /// [imageIds] must be every currently visible page exactly once - the engine
  /// compares the set and the length and rejects anything else, rather than
  /// guessing at a partial list.
  Future<Map<String, Object?>> reorder(
    int folderId,
    String sourceHash,
    List<int> imageIds,
  ) => _mutateTask('/qc/metadata-tasks/$folderId/images/reorder', {
    'sourceHash': sourceHash,
    'imageIds': imageIds,
  });

  /// Uploads a page and puts it in front of [imageId].
  ///
  /// The only multipart endpoint on the engine: `sourceHash` is a form field
  /// rather than JSON, and the file rides alongside it. The inserted page comes
  /// back with a NEGATIVE id - the draft numbers its own additions downward from
  /// -1, since they have no row in `capture_folders` until the task is approved.
  Future<Map<String, Object?>> insertBefore(
    int folderId,
    int imageId,
    String sourceHash, {
    required String filename,
    required List<int> bytes,
  }) async {
    final boundary = _boundary();
    final data = await _send(
      'POST',
      _uri('/qc/metadata-tasks/$folderId/images/$imageId/insert-before'),
      rawBody: _multipartBody(
        boundary: boundary,
        fields: {'sourceHash': sourceHash},
        fileField: 'file',
        filename: filename,
        bytes: bytes,
      ),
      rawContentType: 'multipart/form-data; boundary=$boundary',
      // A full-resolution page plus the engine's own decode of it takes longer
      // than a JSON round trip, and timing out here would strand a file the
      // engine has already written.
      timeout: const Duration(minutes: 2),
    );
    return (data as Map<String, Object?>?) ?? const {};
  }

  /// Swaps new bytes into an existing page, keeping the page's identity.
  ///
  /// The engine renames the upload to the page it replaces
  /// (`replacement_image_name`, qc.py:707) - the stem is the page's identity
  /// and its ordering, so a file called anything at all lands as
  /// `SAX01_IMG_...`. Only the extension follows the upload, and only when the
  /// format actually differs, because `.tif` on PNG bytes would be a lie.
  Future<Map<String, Object?>> replaceImage(
    int folderId,
    int imageId,
    String sourceHash, {
    required String filename,
    required List<int> bytes,
  }) async {
    final boundary = _boundary();
    final data = await _send(
      'POST',
      _uri('/qc/metadata-tasks/$folderId/images/$imageId/replace'),
      rawBody: _multipartBody(
        boundary: boundary,
        fields: {'sourceHash': sourceHash},
        fileField: 'file',
        filename: filename,
        bytes: bytes,
      ),
      rawContentType: 'multipart/form-data; boundary=$boundary',
      // Same reasoning as insertBefore: a full-resolution page plus the
      // engine's decode of it outlasts a JSON round trip.
      timeout: const Duration(minutes: 2),
    );
    return (data as Map<String, Object?>?) ?? const {};
  }

  // ── Exports (admin) ──────────────────────────────────────────────────────
  //
  // Approving a folder only marks it PASS; the export that turns it into a ZIP
  // for ingest is a separate, admin-gated step. The server now starts one on
  // its own, so these are for watching it and for retrying what failed.

  Future<Map<String, Object?>> exportPreflight() async =>
      (await _send('GET', _uri('/admin/exports/preflight'))
          as Map<String, Object?>?) ??
      const {};

  /// The active run, or the last one to finish. Null when none has ever run.
  Future<Map<String, Object?>?> exportCurrent() async =>
      await _send('GET', _uri('/admin/exports/current'))
          as Map<String, Object?>?;

  /// The S3 upload phase: enabled, problem, counts, current, failures, recent.
  Future<Map<String, Object?>> exportUploads() async =>
      (await _send('GET', _uri('/admin/exports/uploads'))
          as Map<String, Object?>?) ??
      const {};

  /// Lifts the back-off on every failed upload and wakes the sweep.
  Future<Map<String, Object?>> retryUploads() async =>
      (await _send('POST', _uri('/admin/exports/uploads/retry'))
          as Map<String, Object?>?) ??
      const {};

  /// Folders that failed and have not since exported. Outlives the run.
  Future<List<Map<String, Object?>>> exportFailures() async {
    final data = await _send('GET', _uri('/admin/exports/failures'));
    return (data as List?)?.cast<Map<String, Object?>>() ?? const [];
  }

  Future<Map<String, Object?>> runExport() async =>
      (await _send('POST', _uri('/admin/exports/run'))
          as Map<String, Object?>?) ??
      const {};

  /// Re-exports one folder.
  Future<Map<String, Object?>> retryExportFolder(int folderId) async =>
      (await _send('POST', _uri('/admin/exports/folders/$folderId'))
          as Map<String, Object?>?) ??
      const {};

  /// Re-exports several folders in ONE run - the engine refuses to start a
  /// second run while one is alive, so a caller looping per folder would fail
  /// on its second call. Empty list means every unresolved failure.
  Future<Map<String, Object?>> retryExports([
    List<int> folderIds = const [],
  ]) async =>
      (await _send(
            'POST',
            _uri('/admin/exports/retry'),
            body: {'folderIds': folderIds},
          )
          as Map<String, Object?>?) ??
      const {};

  /// Random enough that it cannot occur inside the image bytes it delimits.
  static String _boundary() {
    final random = Random.secure();
    final hex = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return '----LWCamQc$hex';
  }

  static List<int> _multipartBody({
    required String boundary,
    required Map<String, String> fields,
    required String fileField,
    required String filename,
    required List<int> bytes,
  }) {
    // A quote or line break in the name would break out of the header and
    // corrupt the request; the engine sanitises the name again on its side.
    final safe = filename.replaceAll(RegExp(r'["\r\n]'), '_');
    final out = <int>[];
    for (final entry in fields.entries) {
      out.addAll(
        utf8.encode(
          '--$boundary\r\n'
          'Content-Disposition: form-data; name="${entry.key}"\r\n\r\n'
          '${entry.value}\r\n',
        ),
      );
    }
    out.addAll(
      utf8.encode(
        '--$boundary\r\n'
        'Content-Disposition: form-data; name="$fileField"; '
        'filename="$safe"\r\n'
        'Content-Type: application/octet-stream\r\n\r\n',
      ),
    );
    out.addAll(bytes);
    out.addAll(utf8.encode('\r\n--$boundary--\r\n'));
    return out;
  }

  /// Rotates one page. The engine allows only 90, -90 and 180.
  Future<Map<String, Object?>> rotate(
    int folderId,
    int imageId,
    String sourceHash,
    int degrees,
  ) => _mutateTask('/qc/metadata-tasks/$folderId/images/$imageId/rotate', {
    'sourceHash': sourceHash,
    'degrees': degrees,
  });

  /// Rotates several pages in one call.
  Future<Map<String, Object?>> rotateBatch(
    int folderId,
    String sourceHash,
    List<int> imageIds,
    int degrees,
  ) => _mutateTask('/qc/metadata-tasks/$folderId/images/rotate-batch', {
    'sourceHash': sourceHash,
    'imageIds': imageIds,
    'degrees': degrees,
  });

  /// Nudges one page level.
  ///
  /// The engine bounds this to 0.1-10 degrees either way: it is the fine
  /// correction after LWIP's own deskew, not a second deskew pass, and every
  /// application re-encodes and re-expands the page. A real turn is [rotate].
  Future<Map<String, Object?>> deskew(
    int folderId,
    int imageId,
    String sourceHash,
    double degrees,
  ) => _mutateTask('/qc/metadata-tasks/$folderId/images/$imageId/deskew', {
    'sourceHash': sourceHash,
    'degrees': degrees,
  });

  /// Nudges several pages level in one call.
  Future<Map<String, Object?>> deskewBatch(
    int folderId,
    String sourceHash,
    List<int> imageIds,
    double degrees,
  ) => _mutateTask('/qc/metadata-tasks/$folderId/images/deskew-batch', {
    'sourceHash': sourceHash,
    'imageIds': imageIds,
    'degrees': degrees,
  });

  /// Runs the vendored luminance correction over one page.
  Future<Map<String, Object?>> luminance(
    int folderId,
    int imageId,
    String sourceHash,
  ) => _mutateTask('/qc/metadata-tasks/$folderId/images/$imageId/luminance', {
    'sourceHash': sourceHash,
  });

  Future<Map<String, Object?>> luminanceBatch(
    int folderId,
    String sourceHash,
    List<int> imageIds,
  ) => _mutateTask('/qc/metadata-tasks/$folderId/images/luminance-batch', {
    'sourceHash': sourceHash,
    'imageIds': imageIds,
  });

  /// Throws away every edit made to one page, back to what capture produced.
  Future<Map<String, Object?>> restoreOriginal(
    int folderId,
    int imageId,
    String sourceHash,
  ) => _mutateTask(
    '/qc/metadata-tasks/$folderId/images/$imageId/restore-original',
    {'sourceHash': sourceHash},
  );

  /// Steps the whole draft back or forward. No body and no source hash: these
  /// replay the manifest's own stack rather than editing an image.
  Future<Map<String, Object?>> undo(int folderId) =>
      _mutateTask('/qc/metadata-tasks/$folderId/draft/undo', null);

  Future<Map<String, Object?>> redo(int folderId) =>
      _mutateTask('/qc/metadata-tasks/$folderId/draft/redo', null);

  /// Every image operation answers with the whole task, so the caller can simply
  /// adopt the result instead of guessing what changed.
  Future<Map<String, Object?>> _mutateTask(
    String path,
    Map<String, Object?>? body,
  ) async {
    final data = await _send('POST', _uri(path), body: body);
    return (data as Map<String, Object?>?) ?? const {};
  }

  /// The JPEG preview of one page.
  ///
  /// Not an envelope call: the engine streams the file itself, so this bypasses
  /// [_send] entirely rather than trying to parse image bytes as JSON.
  ///
  /// [previewUrl] comes from the image record and already carries the `v=` stamp
  /// the engine derives from the image's own timestamp, or from the reviewer's
  /// draft version when they hold the lock. Passing it through unchanged is what
  /// makes an edited page stop serving its stale preview.
  Future<Uint8List> previewBytes(
    String previewUrl, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    await _ensureSession();
    final uri = QcEngineService.baseUri.resolve(previewUrl);
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.getUrl(uri).timeout(timeout);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      final response = await request.close().timeout(timeout);
      if (response.statusCode == 401) clearSession();
      if (response.statusCode != 200) {
        // A failure here IS an envelope - the engine's error handler wraps
        // everything - so the operator still gets its own words.
        final text = await response.transform(utf8.decoder).join();
        String message = 'The image preview could not be loaded.';
        try {
          final decoded = jsonDecode(text);
          if (decoded is Map && decoded['message'] is String) {
            message = decoded['message'] as String;
          }
        } catch (_) {}
        throw QcApiException(-1, message, statusCode: response.statusCode);
      }
      final chunks = await response.toList();
      return Uint8List.fromList(
        chunks.expand((chunk) => chunk).toList(growable: false),
      );
    } on QcApiException {
      rethrow;
    } on TimeoutException {
      throw QcApiException(-1, 'The image preview timed out.');
    } on SocketException {
      throw QcApiException(-1, 'The QC engine is not running on this PC.');
    } finally {
      client.close(force: true);
    }
  }

  Future<Object?> _send(
    String method,
    Uri uri, {
    Map<String, Object?>? body,
    List<int>? rawBody,
    String? rawContentType,
    bool authenticated = true,
    Duration timeout = const Duration(seconds: 30),
    bool retryOnUnauthorized = true,
  }) async {
    if (authenticated) await _ensureSession();
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
    try {
      final request = await client.openUrl(method, uri).timeout(timeout);
      request.headers.set(HttpHeaders.acceptHeader, 'application/json');
      if (authenticated) {
        request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $_token');
      }
      if (rawBody != null) {
        request.headers.set(HttpHeaders.contentTypeHeader, rawContentType!);
        request.headers.contentLength = rawBody.length;
        request.add(rawBody);
      } else if (body != null) {
        request.headers.contentType = ContentType.json;
        request.write(jsonEncode(body));
      }
      final response = await request.close().timeout(timeout);
      final text = await response.transform(utf8.decoder).join();

      if (response.statusCode == 401 && authenticated) {
        // A stale token would otherwise be retried on every call.
        clearSession();
        // Once: sign in again with the held credentials and repeat the call.
        // A second 401 is reported as it stands, so a revoked account does
        // not loop.
        if (retryOnUnauthorized && _credentials != null) {
          client.close(force: true);
          return await _send(
            method,
            uri,
            body: body,
            rawBody: rawBody,
            rawContentType: rawContentType,
            authenticated: true,
            timeout: timeout,
            retryOnUnauthorized: false,
          );
        }
      }

      Map<String, Object?>? envelope;
      if (text.isNotEmpty) {
        try {
          final decoded = jsonDecode(text);
          if (decoded is Map<String, Object?>) envelope = decoded;
        } catch (_) {
          // Not JSON: a proxy error page or a crash before the app handled it.
        }
      }
      if (envelope == null) {
        throw QcApiException(
          -1,
          'The QC engine returned an unexpected response '
          '(HTTP ${response.statusCode}).',
          statusCode: response.statusCode,
        );
      }
      final code = (envelope['code'] as num?)?.toInt() ?? -1;
      if (code != 0 || response.statusCode >= 400) {
        throw QcApiException(
          code,
          (envelope['message'] as String?)?.trim().isNotEmpty == true
              ? envelope['message'] as String
              : 'The QC engine rejected the request.',
          statusCode: response.statusCode,
        );
      }
      return envelope['data'];
    } on QcApiException {
      rethrow;
    } on TimeoutException {
      throw QcApiException(-1, 'The QC engine did not respond in time.');
    } on SocketException {
      throw QcApiException(
        -1,
        'The QC engine is not running on this PC. Open Quality Check to check '
        'its status.',
      );
    } finally {
      client.close(force: true);
    }
  }
}
