import 'package:flutter_test/flutter_test.dart';
import 'package:postgres/postgres.dart';

import 'package:lwcam/services/pg_client.dart';

void main() {
  test('non-local hosts always require TLS', () {
    expect(pgSslMode('192.168.0.120', false), SslMode.require);
    expect(pgSslMode('db.example.com', false), SslMode.require);
    expect(pgSslMode('100.64.1.2', true), SslMode.require);
  });

  test('loopback is plain unless dbUseSsl is set', () {
    for (final h in ['localhost', 'LOCALHOST', '127.0.0.1', '::1']) {
      expect(pgSslMode(h, false), SslMode.disable);
      expect(pgSslMode(h, true), SslMode.require);
    }
  });
}
