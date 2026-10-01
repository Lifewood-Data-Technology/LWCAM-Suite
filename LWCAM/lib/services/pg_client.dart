import 'dart:async';
import 'dart:io' show SocketException;

import 'package:postgres/postgres.dart';

import 'sync_sink.dart';

/// TLS is required for every non-local database host (encrypted; the server's
/// self-signed certificate is not verified - SslMode.require ignores
/// certificate issues in postgres 3.5.x). Loopback may stay plain unless
/// [useSsl] is set.
SslMode pgSslMode(String host, bool useSsl) {
  final h = host.trim().toLowerCase();
  final local = h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]';
  return (useSsl || !local) ? SslMode.require : SslMode.disable;
}

/// Every statement gets this long before the driver gives up. Without it a
/// half-dead Tailscale/VPN link hangs a query for the OS TCP timeout.
const Duration kPgQueryTimeout = Duration(seconds: 20);

/// A link problem, not a statement problem: timeouts, socket errors, a closed
/// connection and a cancelled (timed-out) query. Only GENUINE statement errors
/// (constraint violations, bad data...) should count toward an outbox row's
/// attempts - a flapping link must never push rows toward HELD.
bool isPgConnectivityError(Object e) =>
    e is TimeoutException ||
    e is SocketException ||
    (e is ServerException && e.code == '57014') || // query_canceled (timeout)
    (e is PgException && e is! ServerException);

/// Runs [body]; a connectivity failure surfaces as [SyncConnectException].
Future<T> mapPgConnectivity<T>(Future<T> Function() body) async {
  try {
    return await body();
  } catch (e) {
    if (e is! SyncConnectException && isPgConnectivityError(e)) {
      throw SyncConnectException(e.toString());
    }
    rethrow;
  }
}

/// Shared PostgreSQL connection opener — the single place the connect
/// settings (SSL mode, 5s timeout) live. Used by [PgSyncSink] (long-lived,
/// lazily reconnecting) and DeviceRegistry (short-lived, per call). Throws
/// [SyncConnectException] on any failure so callers get one exception shape
/// for "PG unreachable".
Future<Connection> openPgConnection({
  required String host,
  required int port,
  required String database,
  required String user,
  required String password,
  required bool useSsl,
}) async {
  try {
    return await Connection.open(
      Endpoint(
        host: host,
        port: port,
        database: database,
        username: user,
        password: password,
      ),
      settings: ConnectionSettings(
        sslMode: pgSslMode(host, useSsl),
        connectTimeout: const Duration(seconds: 5),
        queryTimeout: kPgQueryTimeout,
        // Stated, not inherited. The package already defaults this to 'UTC'
        // (ConnectionSettings.timeZone -> resolved_settings.dart), which is NOT
        // the RDS server default (Asia/Singapore) — and CAST(@x AS timestamptz)
        // resolves an offset-less string using the session zone. That mismatch
        // put every LWCAM timestamp 8h in the future until 2026-07-30. The real
        // fix is that pg_statements only ever emits UTC now (tsOrNull);
        // pinning it here keeps a future change to the
        // package's default from silently reintroducing the bug.
        timeZone: 'UTC',
      ),
    );
  } catch (e) {
    throw SyncConnectException(e.toString());
  }
}
