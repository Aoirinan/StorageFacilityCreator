import 'package:sfcapp/models/address_model.dart';
import 'package:sfcapp/utils/print_documents.dart' show tenantPrintAddressEntry;

/// The fields the Edit Mailing Address dialog collects, as typed. The
/// helpers below trim them; a blank [street2] is left off the saved entry.
class MailingAddressFields {
  final String street1;
  final String street2;
  final String city;
  final String state;
  final String zipCode;

  const MailingAddressFields({
    required this.street1,
    this.street2 = '',
    required this.city,
    required this.state,
    required this.zipCode,
  });

  /// No address: what the dialog's Remove returns.
  static const none =
      MailingAddressFields(street1: '', city: '', state: '', zipCode: '');

  /// Nothing to save. The street decides: TenantModel drops an entry whose
  /// street1 is empty when it reads the tenant, so an entry with a city and
  /// no street would vanish on the next load.
  bool get isBlank => street1.trim().isEmpty;
}

/// The entry the tenant page shows as the mailing address and the dialog
/// edits: the same one the invoice prints ([tenantPrintAddressEntry]), so
/// the pencil always edits what the owner is looking at. Null when the
/// tenant has none.
Address? currentMailingAddress(List<Address> addresses) =>
    tenantPrintAddressEntry(addresses);

/// What [address] still needs before a statement can be mailed to it, as
/// the tenant page says it under the street: "City, state and ZIP missing",
/// "ZIP missing", and so on. Null when city, state and ZIP are all there:
/// the same three the dialog's Save requires. A workbook import usually
/// leaves only the street, and the owner has to be able to see which
/// tenants are still like that without opening every pencil to find out.
String? mailingAddressGap(Address address) {
  final missing = [
    if (address.city.trim().isEmpty) 'city',
    if (address.state.trim().isEmpty) 'state',
    if (address.zipCode.trim().isEmpty) 'ZIP',
  ];
  if (missing.isEmpty) return null;
  final listed = missing.length == 1
      ? missing.single
      : '${missing.take(missing.length - 1).join(', ')} and ${missing.last}';
  final gap = '$listed missing';
  return gap[0].toUpperCase() + gap.substring(1);
}

/// [existing] with the mailing address set to [fields]: the entry
/// [currentMailingAddress] picks is replaced in place, keeping its id, type,
/// createdAt, country and notes and marking it updated at [now]; the other
/// entries are kept as they are. With no such entry, a new primary mailing
/// entry is appended. Blank [fields] mean no address, as
/// [removeMailingAddress].
///
/// Entries are matched by identity, not id: online move-in stores its entry
/// with an empty id.
List<Address> replaceMailingAddress(
  List<Address> existing,
  MailingAddressFields fields,
  DateTime now,
) {
  if (fields.isBlank) return removeMailingAddress(existing);
  final street2 = fields.street2.trim();
  final current = currentMailingAddress(existing);
  if (current == null) {
    return [
      ...existing,
      Address(
        id: 'mailing-${now.millisecondsSinceEpoch}',
        type: AddressType.mailing,
        street1: fields.street1.trim(),
        street2: street2.isEmpty ? null : street2,
        city: fields.city.trim(),
        state: fields.state.trim(),
        zipCode: fields.zipCode.trim(),
        isPrimary: true,
        createdAt: now,
      ),
    ];
  }
  // Not copyWith: its `street2 ?? this.street2` cannot clear an Apt that
  // was removed.
  final replaced = Address(
    id: current.id,
    type: current.type,
    street1: fields.street1.trim(),
    street2: street2.isEmpty ? null : street2,
    city: fields.city.trim(),
    state: fields.state.trim(),
    zipCode: fields.zipCode.trim(),
    country: current.country,
    isPrimary: true,
    notes: current.notes,
    createdAt: current.createdAt,
    updatedAt: now,
  );
  return [for (final a in existing) identical(a, current) ? replaced : a];
}

/// [existing] without the entry [currentMailingAddress] picks; the other
/// entries are kept. Unchanged when there is none.
List<Address> removeMailingAddress(List<Address> existing) {
  final current = currentMailingAddress(existing);
  if (current == null) return List.of(existing);
  return [for (final a in existing) if (!identical(a, current)) a];
}
