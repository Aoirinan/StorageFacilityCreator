import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/security_deposit_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/services/statement_service.dart';

// The held security deposit as a note on account statements, printed and
// emailed. All names, units and amounts are made up.
void main() {
  SecurityDeposit held(double amount, {DateTime? received}) => SecurityDeposit(
        amount: amount,
        receivedDate: received,
        method: PaymentMethod.check,
        reference: '1001',
      );

  final sep1 = SecurityDeposit.noonUtc(DateTime(2026, 9, 1));
  final sep15 = SecurityDeposit.noonUtc(DateTime(2026, 9, 15));

  SecurityDeposit settled(double amount) => held(amount, received: sep1).copyWith(
        status: SecurityDepositStatus.settled,
        settledAt: DateTime.utc(2026, 10, 3, 12),
        appliedAmount: 10,
        refundedAmount: amount - 10,
      );

  group('statementDepositNote', () {
    test('a held deposit: the amount, the day received, and that it is not '
        'in the balance', () {
      expect(
        statementDepositNote([held(25, received: sep1)]),
        r'Security deposit on file: $25.00 (held since 9/1/2026). '
        'Not part of the balance above.',
      );
    });

    test('no date on file: the amount alone', () {
      expect(
        statementDepositNote([held(25)]),
        r'Security deposit on file: $25.00. Not part of the balance above.',
      );
    });

    test('nothing when there is no deposit, or it is settled', () {
      expect(statementDepositNote(const []), isNull);
      expect(statementDepositNote([null]), isNull);
      expect(statementDepositNote([settled(25)]), isNull);
      expect(statementDepositNote([held(0, received: sep1)]), isNull);
    });

    test('several records: held deposits summed, settled ones left out', () {
      expect(
        statementDepositNote([
          held(25, received: sep1),
          null,
          settled(40),
          held(50.5, received: sep1),
        ]),
        r'Security deposits on file: $75.50 (held since 9/1/2026). '
        'Not part of the balance above.',
      );
      // One held among them reads as one deposit.
      expect(
        statementDepositNote([held(25, received: sep1), settled(40), null]),
        startsWith(r'Security deposit on file: $25.00 (held since 9/1/2026)'),
      );
    });

    test('several records received on different days, or one with no date: '
        'the sum without a date', () {
      const bare = r'Security deposits on file: $75.00. '
          'Not part of the balance above.';
      expect(
        statementDepositNote(
            [held(25, received: sep1), held(50, received: sep15)]),
        bare,
      );
      expect(statementDepositNote([held(25, received: sep1), held(50)]), bare);
    });

    test('the same day at another hour is the same day', () {
      expect(
        statementDepositNote([
          held(25, received: DateTime(2026, 9, 1, 8)),
          held(25, received: DateTime(2026, 9, 1, 17)),
        ]),
        contains('(held since 9/1/2026)'),
      );
    });

    test('thousands print with a separator, cents rounded', () {
      expect(
        statementDepositNote([held(1000, received: sep1), held(250.004)]),
        startsWith(r'Security deposits on file: $1,250.00.'),
      );
    });
  });

  group('statementEmailContent', () {
    final facility = FacilityModel(
      id: 'f1',
      name: 'Oak Storage',
      ownerUid: 'owner',
      createdAt: DateTime(2026, 1, 1),
      address: '1 Example Rd\nAnytown, ND 58999',
      phone: '(555) 123-4567',
      email: 'office@oak.example',
    );
    final tenant = TenantModel(
      id: 't1',
      facilityId: 'f1',
      name: 'Pat Example',
      email: 'pat@example.com',
      phone: '(555) 010-0199',
      unitNumber: 'B-14',
      monthlyRate: 144,
      createdAt: DateTime(2026, 1, 1),
    );
    const note = r'Security deposit on file: $25.00 (held since 9/1/2026). '
        'Not part of the balance above.';

    ({String subject, String html, String text}) email(String? depositNote) =>
        statementEmailContent(
          tenant: tenant,
          facility: facility,
          periodText: 'your account',
          pdfUrl: 'https://files.example/statement.pdf',
          currentBalance: r'$144.00',
          depositNote: depositNote,
        );

    test('a held deposit: the line straight after the current balance, in '
        'the HTML and the plain text', () {
      final withNote = email(note);
      expect(withNote.subject, 'Account Statement from Oak Storage');
      expect(withNote.html,
          contains('<p><strong>Current Balance:</strong> \$144.00</p>\n'
              '  <p>$note</p>\n'
              '  <p>Please review the statement'));
      expect(withNote.text,
          contains('Current Balance: \$144.00\n$note\n\nPlease review'));
      // The balance is the one passed in; the deposit is not added to it.
      expect(withNote.text, isNot(contains(r'$169.00')));
      expect(withNote.html, isNot(contains(r'$169.00')));
    });

    test('the tenant\'s deposit, as sendStatement reads it', () {
      final text = email(statementDepositNote([
        tenant
            .copyWith(
                securityDeposit: held(25,
                    received: SecurityDeposit.noonUtc(DateTime(2026, 9, 1))))
            .securityDeposit,
      ])).text;
      expect(text, contains(note));
    });

    test('no deposit or a settled one: the email is as it was, no line', () {
      for (final deposit in [null, settled(25)]) {
        final plain = email(statementDepositNote([deposit]));
        expect(plain.html, isNot(contains('Security deposit')));
        expect(plain.text, isNot(contains('Security deposit')));
        expect(plain.html,
            contains('<p><strong>Current Balance:</strong> \$144.00</p>\n'
                '  <p>Please review the statement'));
        expect(plain.text,
            contains('Current Balance: \$144.00\n\nPlease review'));
      }
    });
  });
}
