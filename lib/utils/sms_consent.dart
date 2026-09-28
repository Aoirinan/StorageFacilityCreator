import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:sfcapp/models/tenant_model.dart';

/// The shared SFC toll-free number tenants text START to, as shown to owners.
const sfcTextingNumberDisplay = '(855) 526-4544';

/// The one wording of the consent box, on every screen that records it. The
/// owner is attesting that the tenant agreed; the tenant is not the one
/// ticking it, so it does not say "I agree".
String smsConsentCheckboxLabel(String facilityName) =>
    '$facilityName may text this tenant rent reminders and account notices '
    '(tenant agreed)';

const smsConsentHelperText =
    'Only tick this if the tenant agreed — in writing, on their lease, or by '
    'texting START to $sfcTextingNumberDisplay.';

/// Shown in place of the box when the tenant opted out themselves.
const smsOptedOutText =
    'This tenant opted out of texts, so the box is locked. Only the tenant can '
    'opt back in, by texting START to $sfcTextingNumberDisplay.';

/// smsConsentSource values written by the app. The server writes
/// 'inbound_stop', 'inbound_start', 'staff_restored' and 'publicRentalForm'.
class SmsConsentSources {
  SmsConsentSources._();

  /// Staff ticked the box, or recorded consent in bulk.
  static const staffRecorded = 'staff_recorded';

  /// Staff unticked the box, or removed consent in bulk. Stored as an opt-out
  /// so the server never texts them, but it is the facility's record, not the
  /// tenant's STOP: staff may record consent again.
  static const staffRemoved = 'staff_removed';

  /// The CSV import's "SMS Consent" column.
  static const csvImport = 'csv_import';
}

/// How the tenant agreed, as staff recorded it (smsConsentMethod).
enum SmsConsentMethod {
  writtenLease('written_lease', 'Written lease'),
  signedForm('signed_form', 'Signed form'),
  verbalInPerson('verbal_in_person', 'Verbally in person'),
  other('other', 'Other');

  const SmsConsentMethod(this.value, this.label);
  final String value;
  final String label;

  static SmsConsentMethod? fromValue(String? value) {
    for (final m in values) {
      if (m.value == value) return m;
    }
    return null;
  }
}

enum SmsConsentState {
  /// Consent is on record: the server will text them.
  consented,

  /// Nothing recorded either way.
  none,

  /// The tenant opted out (texted STOP, or an opt-out from elsewhere). Never
  /// overridden by staff.
  optedOut,

  /// Staff removed the consent they had recorded.
  removedByStaff,
}

/// The tenant's consent as the server reads it: an opt-out (either field)
/// beats everything; then `smsConsentStatus: opted_in` or an `smsOptInDate`
/// is consent (functions-messaging-twilio sendSMS and hasSmsConsent).
SmsConsentState smsConsentState(TenantModel tenant) {
  final status = tenant.smsConsentStatus.toLowerCase();
  if (tenant.smsOptOut || status == 'opted_out') {
    return tenant.smsConsentSource == SmsConsentSources.staffRemoved
        ? SmsConsentState.removedByStaff
        : SmsConsentState.optedOut;
  }
  if (status == 'opted_in' || tenant.smsOptInDate != null) {
    return SmsConsentState.consented;
  }
  return SmsConsentState.none;
}

/// A number a text can go to: ten digits or more.
bool hasTextablePhone(String? phone) =>
    (phone ?? '').replaceAll(RegExp(r'[^\d]'), '').length >= 10;

/// Consent on record and a number to send to.
bool canReceiveTexts(TenantModel tenant) =>
    smsConsentState(tenant) == SmsConsentState.consented &&
    hasTextablePhone(tenant.phone);

/// A short chip label for the tenant list.
String smsConsentChipLabel(TenantModel tenant) {
  switch (smsConsentState(tenant)) {
    case SmsConsentState.consented:
      return hasTextablePhone(tenant.phone) ? 'SMS ✓' : 'SMS: no number';
    case SmsConsentState.optedOut:
      return 'SMS opted out';
    case SmsConsentState.none:
    case SmsConsentState.removedByStaff:
      return 'SMS off';
  }
}

/// One line for the tenant's page, e.g. "Can text · agreed 12 Sep 2026
/// (Written lease)".
String smsConsentSummary(TenantModel tenant) {
  final state = smsConsentState(tenant);
  switch (state) {
    case SmsConsentState.consented:
      final parts = <String>[];
      final date = tenant.smsOptInDate ?? tenant.smsConsentTimestamp;
      if (date != null) parts.add('agreed ${_formatDate(date)}');
      final method = SmsConsentMethod.fromValue(tenant.smsConsentMethod);
      final note = (tenant.smsConsentNote ?? '').trim();
      if (method != null) {
        parts.add(note.isEmpty ? method.label : '${method.label}: $note');
      } else if (note.isNotEmpty) {
        parts.add(note);
      }
      final head =
          hasTextablePhone(tenant.phone) ? 'Can text' : 'Consent on file, but no mobile number';
      return parts.isEmpty ? head : '$head · ${parts.join(' · ')}';
    case SmsConsentState.optedOut:
      return 'Opted out (tenant texted STOP)';
    case SmsConsentState.removedByStaff:
      return 'No consent (removed by staff)';
    case SmsConsentState.none:
      return 'No consent recorded';
  }
}

String _formatDate(DateTime d) {
  const months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];
  return '${d.day} ${months[d.month - 1]} ${d.year}';
}

/// A change to a tenant's recorded consent, written by staff.
class SmsConsentUpdate {
  /// True records consent; false removes it.
  final bool grant;

  /// When the tenant agreed (grant) or when staff removed it (remove).
  final DateTime date;
  final SmsConsentMethod? method;
  final String? note;

  SmsConsentUpdate.grant({
    required DateTime consentDate,
    this.method,
    String? note,
  })  : grant = true,
        date = consentDate,
        note = (note ?? '').trim().isEmpty ? null : note!.trim();

  SmsConsentUpdate.remove({required DateTime at})
      : grant = false,
        date = at,
        method = null,
        note = null;

  /// The tenant fields to write. Both shapes the server reads are kept in
  /// step: `smsOptOut` / `smsOptInDate` and `smsConsentStatus`.
  Map<String, dynamic> fields({String? actingUid}) {
    final at = Timestamp.fromDate(date);
    final common = <String, dynamic>{
      'smsConsentTimestamp': at,
      'smsConsentRecordedAt': FieldValue.serverTimestamp(),
      if (actingUid != null && actingUid.isNotEmpty)
        'smsConsentRecordedBy': actingUid,
    };
    if (grant) {
      return {
        ...common,
        'smsOptOut': false,
        'smsOptOutDate': FieldValue.delete(),
        'smsOptInDate': at,
        'smsConsentStatus': 'opted_in',
        'smsConsentSource': SmsConsentSources.staffRecorded,
        'smsConsentMethod': method?.value ?? FieldValue.delete(),
        'smsConsentNote': note ?? FieldValue.delete(),
      };
    }
    return {
      ...common,
      'smsOptOut': true,
      'smsOptOutDate': at,
      'smsConsentStatus': 'opted_out',
      'smsConsentSource': SmsConsentSources.staffRemoved,
      'smsConsentMethod': FieldValue.delete(),
      'smsConsentNote': FieldValue.delete(),
    };
  }

  /// Plain values for the audit log (no Firestore sentinels).
  Map<String, dynamic> auditSummary() => {
        'smsConsent': grant ? 'recorded' : 'removed',
        'date': date.toIso8601String(),
        if (method != null) 'method': method!.value,
        if (note != null) 'note': note,
      };
}

/// What saving the consent box does, given the tenant as saved and whether
/// the box is ticked now. Null when nothing changes: re-saving a tenant
/// whose consent stays on keeps the date they agreed, and a tenant's own
/// opt-out is never touched from here.
SmsConsentUpdate? smsConsentChange({
  required TenantModel tenant,
  required bool ticked,
  SmsConsentMethod? method,
  String? note,
  DateTime? now,
}) {
  final state = smsConsentState(tenant);
  if (state == SmsConsentState.optedOut) return null;
  final wasOn = state == SmsConsentState.consented;
  if (wasOn == ticked) return null;
  final at = now ?? DateTime.now();
  return ticked
      ? SmsConsentUpdate.grant(consentDate: at, method: method, note: note)
      : SmsConsentUpdate.remove(at: at);
}

/// The selected tenants sorted for a bulk record or removal.
class SmsConsentBulkPlan {
  /// Written.
  final List<TenantModel> toUpdate;

  /// Grant only: no mobile number on file.
  final List<TenantModel> noPhone;

  /// Grant only: the tenant opted out themselves. Never overridden.
  final List<TenantModel> optedOut;

  /// Already as asked: consent already on record (grant; its date is kept),
  /// or no consent to remove (remove).
  final List<TenantModel> unchanged;

  const SmsConsentBulkPlan({
    required this.toUpdate,
    required this.noPhone,
    required this.optedOut,
    required this.unchanged,
  });

  int get skipped => noPhone.length + optedOut.length + unchanged.length;
}

SmsConsentBulkPlan planSmsConsentBulk(
  Iterable<TenantModel> tenants, {
  required bool grant,
}) {
  final toUpdate = <TenantModel>[];
  final noPhone = <TenantModel>[];
  final optedOut = <TenantModel>[];
  final unchanged = <TenantModel>[];
  for (final t in tenants) {
    final state = smsConsentState(t);
    if (grant) {
      if (state == SmsConsentState.optedOut) {
        optedOut.add(t);
      } else if (state == SmsConsentState.consented) {
        unchanged.add(t);
      } else if (!hasTextablePhone(t.phone)) {
        noPhone.add(t);
      } else {
        toUpdate.add(t);
      }
    } else {
      if (state == SmsConsentState.consented) {
        toUpdate.add(t);
      } else {
        unchanged.add(t);
      }
    }
  }
  return SmsConsentBulkPlan(
    toUpdate: toUpdate,
    noPhone: noPhone,
    optedOut: optedOut,
    unchanged: unchanged,
  );
}
