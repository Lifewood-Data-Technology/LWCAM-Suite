import 'package:postgres/postgres.dart';

/// Thrown when PostgreSQL could not be reached at all — the one exception
/// shape every caller in this app checks for "treat as offline".
class SyncConnectException implements Exception {
  final String message;

  /// Why the connect failed, when the server said enough to tell.
  ///
  /// Every failure used to surface as "could not reach the host", which sent
  /// operators looking at networks and firewalls when the real answer was a
  /// database that had never been created. The server distinguishes these
  /// perfectly well; only this class was throwing that away.
  final PgFailure failure;

  const SyncConnectException(this.message, {this.failure = PgFailure.unreachable});

  @override
  String toString() => 'SyncConnectException: $message';
}

/// The three outcomes worth telling apart, because each has a different fix and
/// only one of them is a network problem.
enum PgFailure {
  /// Nothing answered: wrong host or port, server down, firewall.
  unreachable,

  /// The server answered and rejected the credentials.
  badPassword,

  /// The server answered, the credentials are good, and the database is simply
  /// not there yet. Recoverable without the operator doing anything - the app
  /// creates it.
  missingDatabase,
}

/// Classifies a driver error by what PostgreSQL actually said.
///
/// Matched on the server's own wording rather than SQLSTATE because the driver
/// surfaces these as plain exceptions here, and the two phrases below are
/// stable parts of PostgreSQL's FATAL messages.
PgFailure classifyPgError(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('does not exist') && text.contains('database')) {
    return PgFailure.missingDatabase;
  }
  if (text.contains('password authentication failed') ||
      text.contains('no password supplied') ||
      text.contains('role') && text.contains('does not exist')) {
    return PgFailure.badPassword;
  }
  return PgFailure.unreachable;
}

/// Operator-facing sentence for [failure]. Says what to do, not what broke.
String describePgFailure(PgFailure failure) {
  switch (failure) {
    case PgFailure.unreachable:
      return 'could not reach the database server - check the host and port, '
          'and that PostgreSQL is running';
    case PgFailure.badPassword:
      return 'the database server rejected the user name or password';
    case PgFailure.missingDatabase:
      return 'the database does not exist yet';
  }
}

/// Shared PostgreSQL connection opener — the single place the connect
/// settings (SSL mode, 5s timeout) live. Used by AdminPgGateway (long-lived,
/// lazily reconnecting) and DeviceRegistry (short-lived, per call). Mirrors
/// LWCAM's copy of this file exactly, except [SyncConnectException] is
/// defined here instead of in a sync_sink.dart this app doesn't have.
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
      ),
    );
  } catch (e) {
    // Carry the classification, not just the driver's text: callers decide
    // between "tell the operator" and "create the database and retry".
    throw SyncConnectException(e.toString(), failure: classifyPgError(e));
  }
}
