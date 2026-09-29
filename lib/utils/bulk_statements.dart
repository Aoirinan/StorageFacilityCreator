import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/utils/mailing_address_edit.dart'
    show currentMailingAddress, mailingAddressGap;
import 'package:sfcapp/utils/print_documents.dart' show tenantPrintAddress;
import 'package:sfcapp/utils/statement_lines.dart';

/// Planning a bulk print of account statements (Tenants > Select Multiple >
/// Print statements): which of the selected tenants get a statement, which
/// two-unit customers share one, and who is left out. Pure, so the dialog
/// can recount as the owner ticks options and tests can check the rules
/// without Firestore.
///
/// For the owner whose tenants mostly have no email: monthly statements are
/// printed and mailed, and before this each one meant opening the tenant's
/// ledger and printing from there.

/// The span a statement covers. [StatementPeriod.month] is the calendar
/// month in local time: rent (12:00 UTC on the 1st) and past-history
/// payments (12:00 UTC on the day received) land in the right US-local
/// month. [StatementPeriod.allHistory] has no bounds, so the statement's
/// figure is the ledger balance.
class StatementPeriod {
  final DateTime? startDate;

  /// The last day of the period; [inStatementPeriod] counts the whole day.
  final DateTime? endDate;

  const StatementPeriod.allHistory()
      : startDate = null,
        endDate = null;

  StatementPeriod.month(int year, int month)
      : startDate = DateTime(year, month, 1),
        // Day 0 of the next month is the last day of this one.
        endDate = DateTime(year, month + 1, 0);

  bool get isAllHistory => startDate == null && endDate == null;
}

/// The key two tenant records share when they are the same customer: the
/// name, trimmed, lowercased, with each run of whitespace made one space.
/// A person renting two units has two tenant records and two ledgers; the
/// owner types the name twice and does not always type it the same way.
String sameCustomerKey(TenantModel tenant) =>
    tenant.name.toLowerCase().replaceAll(RegExp(r'\s+'), ' ').trim();

/// The printable mailing address, normalised the same way, for deciding
/// whether two records agree on where the person lives.
String? _addressKey(TenantModel tenant) => tenantPrintAddress(tenant.addresses)
    ?.toLowerCase()
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// A same-name group that prints as separate statements, and why.
class NotCombinedGroup {
  /// The records, in list order.
  final List<TenantModel> tenants;

  /// At least one record has no mailing address.
  final bool addressMissing;

  /// At least two records have mailing addresses that are not the same.
  final bool addressesDiffer;

  const NotCombinedGroup({
    required this.tenants,
    required this.addressMissing,
    required this.addressesDiffer,
  });

  /// The reason, as the dialog's "Printed separately" note gives it.
  String get reason => addressMissing && addressesDiffer
      ? 'different and missing addresses'
      : addressMissing
          ? 'missing address'
          : 'different addresses';
}

/// The same-name groups in [orderedTenants], each in list order.
///
/// A group is combinable only when every record in it has a mailing
/// address ([tenantPrintAddress]) and they are all the same address, spacing
/// and case aside: one statement to that address then reaches the person
/// who holds every unit on it. Two different people can share a name, and
/// a record with no address says nothing about who it belongs to, so a
/// group with a missing address prints apart just as one with two
/// different addresses does; both are in notCombined, with the reason.
/// Records with a name of their own are in neither.
({List<List<TenantModel>> combinable, List<NotCombinedGroup> notCombined})
    sameCustomerGroups(List<TenantModel> orderedTenants) {
  final byKey = <String, List<TenantModel>>{};
  for (final t in orderedTenants) {
    final key = sameCustomerKey(t);
    if (key.isEmpty) continue;
    (byKey[key] ??= []).add(t);
  }
  final combinable = <List<TenantModel>>[];
  final notCombined = <NotCombinedGroup>[];
  for (final group in byKey.values) {
    if (group.length < 2) continue;
    final addresses = [for (final t in group) _addressKey(t)];
    final missing = addresses.contains(null);
    final differ = addresses.nonNulls.toSet().length > 1;
    if (!missing && !differ) {
      combinable.add(group);
    } else {
      notCombined.add(NotCombinedGroup(
        tenants: group,
        addressMissing: missing,
        addressesDiffer: differ,
      ));
    }
  }
  return (combinable: combinable, notCombined: notCombined);
}

/// The unit a ledger entry names for itself, `metadata.unitNumber`, or null
/// when it names none, as most entries do.
String? _entryUnit(LedgerEntry entry) {
  final unit = entry.metadata?['unitNumber'];
  if (unit is! String) return null;
  final trimmed = unit.trim();
  return trimmed.isEmpty ? null : trimmed;
}

final RegExp _areaSuffix = RegExp(r' \([^()]*\)$');

/// [labels] as one row prefix: "B-14", "B-14/B-15", or with an area every
/// label shares named once, "B-14/B-15 (Building B)".
String _joinUnitLabels(List<String> labels) {
  if (labels.length < 2) return labels.firstOrNull ?? '';
  final suffix = _areaSuffix.firstMatch(labels.first)?.group(0);
  if (suffix == null || !labels.every((l) => l.endsWith(suffix))) {
    return labels.join('/');
  }
  final numbers = [
    for (final l in labels) l.substring(0, l.length - suffix.length),
  ];
  return '${numbers.join('/')}$suffix';
}

/// One statement to print: one tenant record, or a same-person group.
class BulkStatementJob {
  /// The records on this statement, in list order.
  final List<TenantModel> tenants;

  /// The record whose name, address, phone and email head the statement:
  /// the first with a printable mailing address, else the first.
  final TenantModel holder;

  /// Every unit the records hold, in record order, without repeats.
  final List<String> unitLabels;

  /// The rows and balance over every record's ledger together.
  final StatementLines lines;

  const BulkStatementJob({
    required this.tenants,
    required this.holder,
    required this.unitLabels,
    required this.lines,
  });

  bool get isCombined => tenants.length > 1;
}

class BulkStatementPlan {
  /// In list order; a group sits where its first member was.
  final List<BulkStatementJob> jobs;

  /// Left out because the statement's balance is zero or a credit.
  final List<TenantModel> skippedNothingOwed;

  /// Left out because no posted ledger entry exists for them: the page
  /// would be empty at $0.00, as every tenant's is before the first rent
  /// job runs.
  final List<TenantModel> skippedNoActivity;

  /// One record per statement that has no mailing address to print, so the
  /// owner knows which envelopes she will have to address by hand.
  final List<TenantModel> noMailingAddress;

  /// One record per statement whose mailing address has a street but no
  /// city, state or ZIP ([mailingAddressGap]), as a workbook import often
  /// leaves it: the statement prints, but the envelope would not arrive.
  /// None of these is in [noMailingAddress].
  final List<TenantModel> incompleteMailingAddress;

  /// Same-name groups printed apart, with the reason: their addresses
  /// differ, or at least one has none ([sameCustomerGroups]).
  final List<NotCombinedGroup> notCombined;

  const BulkStatementPlan({
    required this.jobs,
    required this.skippedNothingOwed,
    required this.skippedNoActivity,
    required this.noMailingAddress,
    required this.incompleteMailingAddress,
    required this.notCombined,
  });

  int get statementCount => jobs.length;
}

/// Lays out the statements for [orderedTenants] (the selected tenants as
/// the list shows them) from [entriesByTenant], each tenant's whole ledger
/// by tenant id.
///
/// With [combineSamePerson], records that share a name and all have the
/// same mailing address ([sameCustomerGroups]) print as one statement:
/// every unit on the unit line, the ledgers merged in date order with each
/// row's description prefixed by its unit, and the balances summed. With
/// [skipNoActivity], tenants with no posted ledger entry are left out; with
/// [skipNothingOwed], those whose balance for [period] is zero or a credit.
/// A group is skipped as a whole, by the same tests on its combined ledger.
///
/// [unitLabels] names a tenant's units, as StatementService's
/// statementUnitLabels does with the facility's units; without it the unit
/// line shows the record's own unit number.
BulkStatementPlan planBulkStatements(
  List<TenantModel> orderedTenants,
  Map<String, List<LedgerEntry>> entriesByTenant, {
  required StatementPeriod period,
  bool combineSamePerson = false,
  bool skipNothingOwed = false,
  bool skipNoActivity = true,
  List<String> Function(TenantModel tenant)? unitLabels,
}) {
  List<String> labelsOf(TenantModel t) => unitLabels?.call(t) ??
      [if (t.unitNumber.trim().isNotEmpty) t.unitNumber.trim()];

  final groups = sameCustomerGroups(orderedTenants);
  final groupOf = <String, List<TenantModel>>{
    if (combineSamePerson)
      for (final g in groups.combinable)
        for (final t in g) t.id: g,
  };

  final jobs = <BulkStatementJob>[];
  final skippedNothingOwed = <TenantModel>[];
  final skippedNoActivity = <TenantModel>[];
  final noMailingAddress = <TenantModel>[];
  final incompleteMailingAddress = <TenantModel>[];
  final placed = <String>{};

  for (final tenant in orderedTenants) {
    if (!placed.add(tenant.id)) continue;
    final members = groupOf[tenant.id] ?? [tenant];
    for (final m in members) {
      placed.add(m.id);
    }

    final entries = <LedgerEntry>[];
    for (final m in members) {
      final own = entriesByTenant[m.id] ?? const <LedgerEntry>[];
      if (members.length == 1) {
        entries.addAll(own);
        continue;
      }
      // On a combined statement each row says which unit it belongs to,
      // since the ledgers are read as one: the unit the entry names, else
      // every unit its record holds. A record holding two units keeps one
      // ledger for both, so naming only the first would pin the other
      // unit's rows on it.
      final recordUnits = _joinUnitLabels(labelsOf(m));
      for (final e in own) {
        final unit = _entryUnit(e) ?? recordUnits;
        entries.add(unit.isEmpty
            ? e
            : e.copyWith(
                description: '$unit: ${e.description ?? e.typeDisplayName}'));
      }
    }

    final hasActivity =
        entries.any((e) => e.status == LedgerEntryStatus.posted);
    if (skipNoActivity && !hasActivity) {
      skippedNoActivity.addAll(members);
      continue;
    }
    final lines = buildStatementLines(entries,
        startDate: period.startDate, endDate: period.endDate);
    if (skipNothingOwed && lines.closingBalance <= 0) {
      skippedNothingOwed.addAll(members);
      continue;
    }

    final holder = members.firstWhere(
        (m) => tenantPrintAddress(m.addresses) != null,
        orElse: () => members.first);
    final labels = <String>[];
    for (final m in members) {
      for (final l in labelsOf(m)) {
        if (!labels.contains(l)) labels.add(l);
      }
    }
    // The entry tenantPrintAddress prints.
    final printed = currentMailingAddress(holder.addresses);
    if (printed == null) {
      noMailingAddress.add(holder);
    } else if (mailingAddressGap(printed) != null) {
      incompleteMailingAddress.add(holder);
    }
    jobs.add(BulkStatementJob(
      tenants: members,
      holder: holder,
      unitLabels: labels,
      lines: lines,
    ));
  }

  return BulkStatementPlan(
    jobs: jobs,
    skippedNothingOwed: skippedNothingOwed,
    skippedNoActivity: skippedNoActivity,
    noMailingAddress: noMailingAddress,
    incompleteMailingAddress: incompleteMailingAddress,
    notCombined: groups.notCombined,
  );
}

/// [ids] in runs of at most [size], in order: Firestore's whereIn takes at
/// most 30 values, so 82 tenants' ledgers are three queries.
List<List<String>> chunkIds(List<String> ids, int size) => [
      for (var i = 0; i < ids.length; i += size)
        ids.sublist(i, (i + size).clamp(0, ids.length)),
    ];
