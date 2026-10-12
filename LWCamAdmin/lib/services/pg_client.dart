// PostgreSQL connection helper of LWCam Admin. Opens connections to the shared
// database and turns server errors into SyncConnectException with a PgFailure
// reason, so callers can show a specific message and treat the database as
// offline.
import 'dart:async';

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

/// The outcomes worth telling apart, because each has a different fix and
/// only some of them are network problems.
enum PgFailure {
  /// Nothing answered: wrong port, connection refused, server down, firewall.
  unreachable,

  /// The host did not answer in time (a dropped packet, a PC that is off, a
  /// Tailscale peer that is offline) - or its name did not resolve.
  timeout,

  /// The server answered and rejected the credentials.
  badPassword,

  /// The server answered, the credentials are good, and the database is simply
  /// not there yet. Recoverable without the operator doing anything - the app
  /// creates it.
  missingDatabase,

  /// The server's pg_hba.conf has no rule admitting this PC/user/database.
  noHbaEntry,

  /// TLS mismatch: the server has no TLS but this app requires it for every
  /// non-local host, or pg_hba only admits encrypted (hostssl) connections.
  encryptionRequired,
}

/// Classifies a driver error by what PostgreSQL actually said.
///
/// Matched on the server's own wording rather than SQLSTATE because the driver
/// surfaces these as plain exceptions here, and the phrases below are stable
/// parts of PostgreSQL's FATAL messages.
PgFailure classifyPgError(Object error) {
  final text = error.toString().toLowerCase();
  if (text.contains('no pg_hba.conf entry')) {
    // "... no encryption" = we connected plain and only hostssl rules exist.
    return text.contains('no encryption')
        ? PgFailure.encryptionRequired
        : PgFailure.noHbaEntry;
  }
  if (text.contains('does not support ssl') ||
      text.contains('server does not support tls') ||
      (text.contains('ssl') && text.contains('required'))) {
    return PgFailure.encryptionRequired;
  }
  if (text.contains('does not exist') && text.contains('database')) {
    return PgFailure.missingDatabase;
  }
  if (text.contains('password authentication failed') ||
      text.contains('no password supplied') ||
      text.contains('role') && text.contains('does not exist')) {
    return PgFailure.badPassword;
  }
  if (error is TimeoutException ||
      text.contains('timeoutexception') ||
      text.contains('timed out') ||
      text.contains('errno = 10060') ||
      text.contains('failed host lookup') ||
      text.contains('no such host')) {
    return PgFailure.timeout;
  }
  return PgFailure.unreachable;
}

/// Operator-facing sentence for [failure]. Says what to do, not what broke.
String describePgFailure(PgFailure failure) {
  switch (failure) {
    case PgFailure.unreachable:
      return 'could not reach the database server - check the host and port, '
          'and that PostgreSQL is running and its firewall allows this PC';
    case PgFailure.timeout:
      return 'host unreachable (no answer in time or the name did not resolve) '
          '- check the host name or IP, that the database PC is on, and that '
          'Tailscale/the network is up';
    case PgFailure.badPassword:
      return 'the database server rejected the user name or password';
    case PgFailure.missingDatabase:
      return 'the database does not exist yet';
    case PgFailure.noHbaEntry:
      return 'the server has no pg_hba.conf entry for this PC - the database '
          'administrator must allow the address of this PC (LWCamDatabaseSetup '
          '"allow other PCs")';
    case PgFailure.encryptionRequired:
      return 'encryption (TLS) mismatch - this app requires TLS for a remote '
          'database, so the server must have ssl = on (or pg_hba must allow '
          'the connection)';
  }
}

/// TLS is required for every non-local database host (encrypted; the server's
/// self-signed certificate is not verified - SslMode.require ignores
/// certificate issues in postgres 3.5.x). Loopback may stay plain unless
/// [useSsl] is set.
SslMode pgSslMode(String host, bool useSsl) {
  final h = host.trim().toLowerCase();
  final local = h == 'localhost' || h == '127.0.0.1' || h == '::1' || h == '[::1]';
  return (useSsl || !local) ? SslMode.require : SslMode.disable;
}

/// Shared PostgreSQL connection opener — the single place the connect
/// settings (SSL mode, 10 s connect / 20 s overall timeout) live. Used by AdminPgGateway (long-lived,
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
        sslMode: pgSslMode(host, useSsl),
        // Over a WAN/Tailscale link the first packet can take seconds.
        connectTimeout: const Duration(seconds: 10),
      ),
      // connectTimeout covers only the TCP connect; a stalled TLS/auth
      // exchange would otherwise wait forever on a half-dead remote host.
    ).timeout(const Duration(seconds: 20));
  } catch (e) {
    // Carry the classification, not just the driver's text: callers decide
    // between "tell the operator" and "create the database and retry".
    throw SyncConnectException(e.toString(), failure: classifyPgError(e));
  }
}
