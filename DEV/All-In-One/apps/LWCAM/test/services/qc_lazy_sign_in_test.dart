import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/qc_api_client.dart';
import 'package:lwcam/services/qc_engine_service.dart';

/// Sign-in at login is a single unawaited attempt. When the engine is still
/// booting - the normal case right after a Station Setup save restarts it -
/// that attempt fails and, before this, every QC screen stayed broken until the
/// operator logged out and back in. The client now keeps the credentials and
/// signs in again the first time a call needs a session, and once more when
/// the engine rejects a token.
///
/// Driven against a real local HttpServer standing in for the engine, so the
/// retry is proven on the actual request path, not a mock of it.
void main() {
  late HttpServer server;
  late List<String> hits;
  int loginFailuresLeft = 0;
  var rejectNextBearer = false;

  setUp(() async {
    hits = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    QcEngineService.debugBaseUriOverride = Uri.parse(
      'http://127.0.0.1:${server.port}',
    );
    server.listen((request) async {
      hits.add('${request.method} ${request.uri.path}');
      final response = request.response..headers.contentType = ContentType.json;
      if (request.uri.path == '/api/auth/login') {
        if (loginFailuresLeft > 0) {
          loginFailuresLeft--;
          response.statusCode = 503;
          response.write(
            jsonEncode({'code': 503, 'message': 'engine booting'}),
          );
        } else {
          response.write(
            jsonEncode({
              'code': 0,
              'message': 'ok',
              'data': {
                'token': 'tok-${hits.length}',
                'user': {'id': 7},
              },
            }),
          );
        }
      } else if (request.uri.path == '/api/admin/exports/current') {
        final auth = request.headers.value(HttpHeaders.authorizationHeader);
        if (rejectNextBearer || auth == null) {
          rejectNextBearer = false;
          response.statusCode = 401;
          response.write(jsonEncode({'code': 401, 'message': 'expired'}));
        } else {
          response.write(
            jsonEncode({
              'code': 0,
              'message': 'ok',
              'data': {'status': 'IDLE', 'auth': auth},
            }),
          );
        }
      } else {
        response.statusCode = 404;
        response.write(jsonEncode({'code': 404, 'message': 'no route'}));
      }
      await response.close();
    });
  });

  tearDown(() async {
    QcApiClient.instance.signOut();
    QcEngineService.debugBaseUriOverride = null;
    await server.close(force: true);
  });

  test(
    'a failed sign-in at login is retried by the first call that needs it',
    () async {
      loginFailuresLeft = 1;
      await expectLater(
        QcApiClient.instance.signIn('qc1', 'pw'),
        throwsA(isA<QcApiException>()),
      );
      expect(QcApiClient.instance.hasSession, isFalse);
      expect(QcApiClient.instance.canRetrySignIn, isTrue);
      expect(QcApiClient.instance.signInError, contains('engine booting'));

      // The engine is up now. The screen's call signs in on its own.
      final current = await QcApiClient.instance.exportCurrent();
      expect(current?['status'], 'IDLE');
      expect(QcApiClient.instance.hasSession, isTrue);
      expect(QcApiClient.instance.signInError, isNull);
      expect(hits, [
        'POST /api/auth/login',
        'POST /api/auth/login',
        'GET /api/admin/exports/current',
      ]);
    },
  );

  test('a rejected token is replaced once and the call repeated', () async {
    await QcApiClient.instance.signIn('qc1', 'pw');
    rejectNextBearer = true;
    final current = await QcApiClient.instance.exportCurrent();
    expect(current?['status'], 'IDLE');
    expect(hits, [
      'POST /api/auth/login',
      'GET /api/admin/exports/current', // 401
      'POST /api/auth/login',
      'GET /api/admin/exports/current',
    ]);
  });

  test('signOut drops the credentials, so nothing can sign back in', () async {
    await QcApiClient.instance.signIn('qc1', 'pw');
    QcApiClient.instance.signOut();
    expect(QcApiClient.instance.canRetrySignIn, isFalse);
    await expectLater(
      QcApiClient.instance.exportCurrent(),
      throwsA(isA<QcApiException>().having((e) => e.statusCode, 'status', 401)),
    );
    expect(hits, [
      'POST /api/auth/login',
    ], reason: 'no retry without credentials');
  });
}
