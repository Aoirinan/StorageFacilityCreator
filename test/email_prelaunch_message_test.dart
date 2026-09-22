import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/email_service.dart';

/// The pre-launch refusal is thrown by the server with a marker in the message
/// so that any client version can recognise it. The marker is for code; what
/// reaches the operator has to read like a sentence.
void main() {
  test('the marker never reaches the operator', () {
    final shown = EmailService.stripErrorMarker(
      'prelaunch_gate: customer email is switched off before launch. Ask a '
      'super admin to enable customerEmailsEnabled on appConfig/outbound, or '
      'add this address to the allowlist.',
    );
    expect(shown, isNot(contains('prelaunch_gate')));
    expect(shown, startsWith('Customer email is switched off'));
  });

  test('the message says what to do about it', () {
    final shown = EmailService.stripErrorMarker(
      'prelaunch_gate: customer email is switched off before launch. Ask a '
      'super admin to enable customerEmailsEnabled on appConfig/outbound.',
    );
    expect(shown, contains('customerEmailsEnabled'));
  });

  test('a missing or empty message still explains itself', () {
    // A callable failure can arrive with no message at all, and "null" is not
    // something to show someone who just tried to send a statement.
    for (final empty in <String?>[null, '', '   ', 'prelaunch_gate: ']) {
      final shown = EmailService.stripErrorMarker(empty);
      expect(shown, isNotEmpty, reason: 'for ${empty == null ? 'null' : '"$empty"'}');
      expect(shown, isNot(contains('prelaunch_gate')));
      expect(shown.toLowerCase(), contains('not sent'));
    }
  });

  test('a message without the marker is passed through, not swallowed', () {
    expect(
      EmailService.stripErrorMarker('SendGrid rejected the recipient address.'),
      'SendGrid rejected the recipient address.',
    );
  });

  test('the marker is only stripped from the front', () {
    // Stripping it anywhere would mangle a message that happens to quote it,
    // such as one describing the block rather than being the block.
    final shown = EmailService.stripErrorMarker(
      'Delivery failed after the prelaunch_gate check passed.',
    );
    expect(shown, contains('prelaunch_gate'));
  });
}
