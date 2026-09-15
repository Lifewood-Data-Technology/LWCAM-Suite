import 'package:flutter_test/flutter_test.dart';
import 'package:lwcam/services/qc_api_client.dart';

/// A failed QC engine sign-in used to vanish into a `print`. The operator met a
/// bare "Not signed in to the QC engine" on a screen three clicks away, and the
/// reason - wrong password, engine still booting, engine not running - was
/// discarded at the point it was known.
///
/// Diagnosing one instance of that took ruling out the build, the deployed
/// backend, the account, the role gate and the route table, when the client had
/// been told the answer and thrown it away.
void main() {
  group('not-signed-in message', () {
    test('carries the reason when one is known', () {
      expect(
        QcApiClient.notSignedInMessage('Incorrect username or password.'),
        'Not signed in to the QC engine: Incorrect username or password.',
      );
    });

    test('stays plain when nothing was recorded', () {
      // No attempt yet, so inventing a cause would be worse than silence.
      expect(
        QcApiClient.notSignedInMessage(null),
        'Not signed in to the QC engine.',
      );
    });

    test('passes a connection failure through as written', () {
      // "engine not running" and "wrong password" must stay distinguishable -
      // they need completely different actions from the operator.
      const reason = 'Connection refused';
      expect(QcApiClient.notSignedInMessage(reason), contains(reason));
    });
  });

  test('a fresh client has recorded no failure', () {
    expect(QcApiClient.instance.signInError, isNull);
  });
}
