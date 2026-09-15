import 'package:postgres/postgres.dart';

import 'sync_sink.dart';

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
        sslMode: useSsl ? SslMode.require : SslMode.disable,
        connectTimeout: const Duration(seconds: 5),
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
