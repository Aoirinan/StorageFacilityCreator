import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/ledger_provider.dart';
import 'package:sfcapp/screens/ledger_screen.dart';

LedgerEntry _entry(
  String id,
  double amount, {
  String? storedType,
  Map<String, dynamic>? metadata,
  LedgerEntryStatus status = LedgerEntryStatus.posted,
}) =>
    LedgerEntry(
      id: id,
      tenantId: 't1',
      facilityId: 'f1',
      type: amount < 0 ? LedgerEntryType.payment : LedgerEntryType.otherCharge,
      amount: amount,
      entryDate: DateTime(2026, 9, 1),
      status: status,
      metadata: metadata,
      createdAt: DateTime(2026, 9, 1),
      createdBy: 'system@stripe-webhook',
      storedType: storedType,
    );

void main() {
  group('parity with functions-shared disputeEntries.ts', () {
    // The same table the server's autopay rule runs; a rule changed on one
    // side only fails that side's test.
    final parity = jsonDecode(File(
            'functions-shared/src/test/fixtures/disputeLedgerParity.json')
        .readAsStringSync()) as Map<String, dynamic>;

    List<Map<String, dynamic>> maps(Object? list) => [
          for (final m in list as List? ?? const []) Map<String, dynamic>.from(m as Map)
        ];

    test('which rows are card-dispute rows', () {
      for (final c in maps(parity['rows'])) {
        final row = Map<String, dynamic>.from(c['row'] as Map);
        expect(isDisputeLedgerRow(row), c['isDispute'], reason: '${c['name']}');
      }
    });

    test('how a posted balance splits', () {
      for (final c in maps(parity['balances'])) {
        final split = splitLedgerBalance(maps(c['rows']));
        expect(split.total, (c['total'] as num).toDouble(), reason: '${c['name']}');
        expect(split.disputed, (c['disputed'] as num).toDouble(), reason: '${c['name']}');
        expect(split.collectible, (c['collectible'] as num).toDouble(), reason: '${c['name']}');
      }
    });
  });

  test('entries read from Firestore split by their stored type, posted only', () {
    final split = splitPostedLedgerEntries([
      _entry('rent', 100, storedType: 'rentCharge'),
      _entry('dispute_du_1', 100, storedType: 'dispute', metadata: {'disputeId': 'du_1'}),
      _entry('dispute_du_2', 60, storedType: 'dispute', status: LedgerEntryStatus.voided),
    ]);

    expect(split.total, 200);
    expect(split.disputed, 100);
    expect(split.collectible, 100);
  });

  test('dispute rows are named as such, not "Other Charge"', () {
    expect(_entry('d', 42, storedType: 'dispute').typeDisplayName, 'Card dispute');
    expect(_entry('r', -42, storedType: 'dispute_reversal').typeDisplayName,
        'Card dispute reversed');
    expect(_entry('o', 5, storedType: 'otherCharge').typeDisplayName, 'Other Charge');
  });

  testWidgets('the ledger tells staff how much of the balance is a card dispute autopay will not charge',
      (tester) async {
    final tenant = TenantModel(
      id: 't1',
      facilityId: 'f1',
      name: 'Pat Tenant',
      email: '',
      phone: '',
      unitNumber: 'A1',
      monthlyRate: 100,
      createdAt: DateTime(2026, 1, 1),
    );
    const params = LedgerParams(tenantId: 't1', facilityId: 'f1');
    final source = StreamController<List<LedgerEntry>>.broadcast();
    addTearDown(source.close);

    await tester.pumpWidget(ProviderScope(
      overrides: [ledgerStreamProvider(params).overrideWith((ref) => source.stream)],
      child: MaterialApp(home: Scaffold(body: LedgerScreen(tenant: tenant))),
    ));
    source.add([
      _entry('march', 100, storedType: 'rentCharge'),
      _entry('payment_pi_march', -100, storedType: 'payment'),
      _entry('dispute_du_1', 100, storedType: 'dispute', metadata: {'disputeId': 'du_1'}),
      _entry('april', 100, storedType: 'rentCharge'),
    ]);
    await tester.pump();
    await tester.pump();

    expect(find.text(disputedBalanceNote(100)), findsOneWidget);
    expect(find.textContaining('Includes \$100.00 from card disputes'), findsOneWidget);

    // Won: the reversal nets it out and the note goes.
    source.add([
      _entry('march', 100, storedType: 'rentCharge'),
      _entry('payment_pi_march', -100, storedType: 'payment'),
      _entry('dispute_du_1', 100, storedType: 'dispute', metadata: {'disputeId': 'du_1'}),
      _entry('dispute_du_1_reinstated', -100,
          storedType: 'dispute_reversal', metadata: {'disputeId': 'du_1'}),
      _entry('april', 100, storedType: 'rentCharge'),
    ]);
    await tester.pump();
    await tester.pump();

    expect(find.textContaining('from card disputes'), findsNothing);
  });
}
