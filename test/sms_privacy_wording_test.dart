import 'package:flutter_test/flutter_test.dart';

import 'package:sfcapp/models/texting_onboarding_model.dart';
import 'package:sfcapp/utils/sms_privacy_wording.dart';

void main() {
  group('smsPrivacyConsentPhrase', () {
    test('maps each method to its phrase', () {
      expect(smsPrivacyConsentPhrase([TextingConsentMethod.onlineForm]),
          'on our online rental form');
      expect(smsPrivacyConsentPhrase([TextingConsentMethod.leaseClause]),
          'in your rental agreement');
      expect(smsPrivacyConsentPhrase([TextingConsentMethod.signedForm]),
          'on a signed form');
      expect(smsPrivacyConsentPhrase([TextingConsentMethod.verbalRecorded]),
          'in person');
    });

    test('joins two with "or"', () {
      expect(
        smsPrivacyConsentPhrase([
          TextingConsentMethod.verbalRecorded,
          TextingConsentMethod.onlineForm,
        ]),
        'on our online rental form or in person',
      );
    });

    test('joins three or more with commas, in the listed order', () {
      expect(
        smsPrivacyConsentPhrase([
          TextingConsentMethod.verbalRecorded,
          TextingConsentMethod.signedForm,
          TextingConsentMethod.leaseClause,
          TextingConsentMethod.onlineForm,
        ]),
        'on our online rental form, in your rental agreement, on a signed '
        'form, or in person',
      );
    });

    test('ignores duplicates and unknown keys', () {
      expect(
        smsPrivacyConsentPhrase([
          TextingConsentMethod.leaseClause,
          TextingConsentMethod.leaseClause,
          'text_start',
        ]),
        'in your rental agreement',
      );
    });

    test('falls back to the generic list when none are chosen', () {
      expect(smsPrivacyConsentPhrase(const []), smsPrivacyGenericConsent);
      expect(smsPrivacyConsentPhrase(['text_start']), smsPrivacyGenericConsent);
    });
  });

  group('buildSmsPrivacyWording', () {
    test('fills in the full wording with the generic consent list', () {
      final text = buildSmsPrivacyWording(
        facilityName: 'Example Self Storage',
        supportPhone: '5125550100',
        supportEmail: 'help@storage.example',
      );

      expect(
        text,
        'Text Messages (SMS)\n\n'
        'Example Self Storage sends text messages about your rental: payment '
        'reminders, account and billing notices, gate and access updates, and '
        'replies to your questions. We only text you after you have agreed to '
        'receive texts, for example in your rental agreement, on a signed '
        'form, or in person.\n\n'
        'Message frequency varies. Message and data rates may apply. Reply '
        'STOP to any message to stop receiving texts, or reply HELP for help. '
        'You can also reach us at (512) 555-0100 or help@storage.example.\n\n'
        'We do not sell, rent, or share your mobile phone number or your '
        'consent to receive texts with third parties or affiliates for '
        'marketing or promotional purposes. Text messaging opt-in data and '
        'consent will not be shared with any third parties. We share your '
        'number only with the service providers that deliver our messages '
        '(our property management software and its texting provider), and '
        'only to send the messages described above.',
      );
    });

    test('names only the chosen methods, without "for example"', () {
      final text = buildSmsPrivacyWording(
        facilityName: 'Example Self Storage',
        consentMethods: [
          TextingConsentMethod.onlineForm,
          TextingConsentMethod.leaseClause,
        ],
      );
      expect(
        text,
        contains('We only text you after you have agreed to receive texts on '
            'our online rental form or in your rental agreement.'),
      );
      expect(text, isNot(contains('for example')));
    });

    test('uses the DBA over the facility name', () {
      final text = buildSmsPrivacyWording(
        dba: '  Example Storage Co ',
        facilityName: 'Example Self Storage',
      );
      expect(text, contains('\n\nExample Storage Co sends text messages'));
      expect(text, isNot(contains('Example Self Storage')));
    });

    test('uses the facility name when the DBA is blank', () {
      final text =
          buildSmsPrivacyWording(dba: '  ', facilityName: 'Example Self Storage');
      expect(text, contains('\n\nExample Self Storage sends text messages'));
    });

    test('falls back to the facility email', () {
      final text = buildSmsPrivacyWording(
        facilityName: 'Example Self Storage',
        supportPhone: '+1 (512) 555-0100',
        supportEmail: '',
        facilityEmail: 'office@storage.example',
      );
      expect(
        text,
        contains('You can also reach us at (512) 555-0100 or '
            'office@storage.example.'),
      );
    });

    test('prefers the support email over the facility email', () {
      final text = buildSmsPrivacyWording(
        facilityName: 'Example Self Storage',
        supportEmail: 'help@storage.example',
        facilityEmail: 'office@storage.example',
      );
      expect(text, contains('reach us at help@storage.example.'));
      expect(text, isNot(contains('office@storage.example')));
    });

    test('keeps a phone it cannot format as typed', () {
      final text = buildSmsPrivacyWording(
        facilityName: 'Example Self Storage',
        supportPhone: '555-0100 ext 2',
      );
      expect(text, contains('reach us at 555-0100 ext 2.'));
    });

    test('leaves out the contact sentence when there is nothing to show', () {
      final text = buildSmsPrivacyWording(facilityName: 'Example Self Storage');
      expect(text, isNot(contains('reach us')));
      expect(text, contains('reply HELP for help.\n\n'));
    });

    test('never mentions texting START and keeps the carrier sentence', () {
      for (final methods in [
        const <String>[],
        TextingConsentMethod.labels.keys.toList(),
      ]) {
        final text = buildSmsPrivacyWording(
          facilityName: 'Example Self Storage',
          consentMethods: methods,
        );
        expect(text, isNot(contains('START')));
        expect(
          text,
          contains('Text messaging opt-in data and consent will not be shared '
              'with any third parties.'),
        );
      }
    });
  });
}
