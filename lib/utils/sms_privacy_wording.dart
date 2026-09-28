import 'package:sfcapp/models/texting_onboarding_model.dart';

/// How each consent method reads in "We only text you after you have agreed
/// to receive texts ...". Keys are [TextingConsentMethod] values, in the
/// order they are listed. Texting START is deliberately absent: it only
/// restores a tenant's own earlier STOP, so it is not a way to sign up.
const smsPrivacyConsentPhrases = <String, String>{
  TextingConsentMethod.onlineForm: 'on our online rental form',
  TextingConsentMethod.leaseClause: 'in your rental agreement',
  TextingConsentMethod.signedForm: 'on a signed form',
  TextingConsentMethod.verbalRecorded: 'in person',
};

/// Used when the facility has not chosen any consent methods yet.
const smsPrivacyGenericConsent =
    'for example in your rental agreement, on a signed form, or in person';

/// Carriers look for this sentence word for word; do not reword it.
const smsPrivacyNoSharingSentence =
    'Text messaging opt-in data and consent will not be shared with any third '
    'parties.';

/// The "how they agreed" phrase for the chosen methods: known keys only, in
/// the listed order, joined "A", "A or B", "A, B, or C". Falls back to
/// [smsPrivacyGenericConsent] when none are chosen.
String smsPrivacyConsentPhrase(Iterable<String> consentMethods) {
  final chosen = consentMethods.toSet();
  final phrases = smsPrivacyConsentPhrases.entries
      .where((e) => chosen.contains(e.key))
      .map((e) => e.value)
      .toList();
  if (phrases.isEmpty) return smsPrivacyGenericConsent;
  if (phrases.length == 1) return phrases.single;
  if (phrases.length == 2) return '${phrases[0]} or ${phrases[1]}';
  return '${phrases.sublist(0, phrases.length - 1).join(', ')}, '
      'or ${phrases.last}';
}

/// A US number as (512) 555-0100; anything else is returned as typed.
String _displayPhone(String phone) {
  var digits = phone.replaceAll(RegExp(r'\D'), '');
  if (digits.length == 11 && digits.startsWith('1')) digits = digits.substring(1);
  if (digits.length != 10) return phone;
  return '(${digits.substring(0, 3)}) ${digits.substring(3, 6)}-'
      '${digits.substring(6)}';
}

String? _nonEmpty(String? value) {
  final trimmed = value?.trim() ?? '';
  return trimmed.isEmpty ? null : trimmed;
}

/// The SMS section an owner adds to their own website's privacy policy,
/// which carriers check when reviewing the facility's A2P registration.
///
/// Named by the DBA, else the facility name. Contact is the support phone and
/// the support email, else the facility email; a missing one is left out.
String buildSmsPrivacyWording({
  String? dba,
  required String facilityName,
  String? supportPhone,
  String? supportEmail,
  String? facilityEmail,
  Iterable<String> consentMethods = const [],
}) {
  final name = _nonEmpty(dba) ?? _nonEmpty(facilityName) ?? 'Our facility';
  final phone = _nonEmpty(supportPhone);
  final email = _nonEmpty(supportEmail) ?? _nonEmpty(facilityEmail);
  final contacts = [
    if (phone != null) _displayPhone(phone),
    if (email != null) email,
  ];

  final how = smsPrivacyConsentPhrase(consentMethods);
  final separator = how == smsPrivacyGenericConsent ? ', ' : ' ';

  return [
    'Text Messages (SMS)',
    '$name sends text messages about your rental: payment reminders, account '
        'and billing notices, gate and access updates, and replies to your '
        'questions. We only text you after you have agreed to receive '
        'texts$separator$how.',
    [
      'Message frequency varies. Message and data rates may apply. Reply STOP '
          'to any message to stop receiving texts, or reply HELP for help.',
      if (contacts.isNotEmpty)
        'You can also reach us at ${contacts.join(' or ')}.',
    ].join(' '),
    'We do not sell, rent, or share your mobile phone number or your consent '
        'to receive texts with third parties or affiliates for marketing or '
        'promotional purposes. $smsPrivacyNoSharingSentence We share your '
        'number only with the service providers that deliver our messages '
        '(our property management software and its texting provider), and '
        'only to send the messages described above.',
  ].join('\n\n');
}
