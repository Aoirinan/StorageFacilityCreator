/// Reading SMS consent out of an operator's own spreadsheet.
///
/// Carriers require a per-tenant opt-in before we may text anyone, and consent
/// is recorded on the tenant. Until now the importer had no column for it, so
/// every operator who moved a rent roll across arrived with a full tenant list
/// and nobody who could legally be texted — the reminders they had just turned
/// on then sent to no one, with nothing on screen explaining why.
///
/// Operators who already collect consent keep it as a column of yes/no, a
/// signature date, or a checkbox export. All three shapes are read here.
library;

/// The consent taken from one imported row.
class ImportedSmsConsent {
  /// Whether the row says this tenant agreed to be texted.
  final bool optedIn;

  /// When they agreed, if the sheet says. Falls back to the import date, since
  /// a consent record with no date is weaker evidence than one with.
  final DateTime? consentedAt;

  const ImportedSmsConsent({required this.optedIn, this.consentedAt});

  static const ImportedSmsConsent none =
      ImportedSmsConsent(optedIn: false, consentedAt: null);
}

const _affirmative = <String>{
  'yes', 'y', 'true', '1', 'x', 'opted in', 'opted-in', 'optin', 'opt in',
  'consent', 'consented', 'agreed', 'signed', 'checked', 'ok', 'okay', 'accept',
  'accepted', 'allow', 'allowed', 'subscribed',
};

const _negative = <String>{
  'no', 'n', 'false', '0', 'opted out', 'opted-out', 'optout', 'opt out',
  'declined', 'refused', 'unsubscribed', 'stop', 'none', 'na', 'n/a', '-',
};

/// Reads a consent cell and an optional date cell.
///
/// A date on its own counts as consent: a sheet with a "SMS consent date"
/// column filled in is recording that it happened. A value that means neither
/// yes nor no is treated as no, because guessing wrong here means texting
/// someone who never agreed.
ImportedSmsConsent parseSmsConsent({
  String? consentValue,
  String? consentDateValue,
  DateTime? importedAt,
}) {
  final raw = (consentValue ?? '').trim().toLowerCase();
  final date = _parseDate(consentDateValue);

  if (raw.isEmpty) {
    if (date != null) {
      return ImportedSmsConsent(optedIn: true, consentedAt: date);
    }
    return ImportedSmsConsent.none;
  }

  if (_negative.contains(raw)) return ImportedSmsConsent.none;

  if (_affirmative.contains(raw)) {
    return ImportedSmsConsent(optedIn: true, consentedAt: date ?? importedAt);
  }

  // A date typed into the consent column itself.
  final inlineDate = _parseDate(consentValue);
  if (inlineDate != null) {
    return ImportedSmsConsent(optedIn: true, consentedAt: inlineDate);
  }

  return ImportedSmsConsent.none;
}

/// Accepts the date shapes a spreadsheet exports: ISO, and US M/D/Y.
DateTime? _parseDate(String? value) {
  final text = (value ?? '').trim();
  if (text.isEmpty) return null;

  final iso = DateTime.tryParse(text);
  if (iso != null) return iso;

  final slash = RegExp(r'^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})$').firstMatch(text);
  if (slash != null) {
    final month = int.parse(slash.group(1)!);
    final day = int.parse(slash.group(2)!);
    var year = int.parse(slash.group(3)!);
    if (year < 100) year += 2000;
    if (month >= 1 && month <= 12 && day >= 1 && day <= 31) {
      return DateTime(year, month, day);
    }
  }
  return null;
}

/// Whether a consented row can actually be texted.
///
/// Consent without a mobile number is not a send, and telling the operator up
/// front beats a reminder that silently goes nowhere.
bool consentIsUsable({required bool optedIn, required String? phone}) {
  if (!optedIn) return false;
  final digits = (phone ?? '').replaceAll(RegExp(r'[^\d]'), '');
  return digits.length >= 10;
}
