import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/audit_service.dart';

// The keys firestore-rules-src/facilities/28-auditLogs-2.rules requires on
// every auditLogs create.
const _ruleKeys = [
  'facilityId',
  'action',
  'entityType',
  'entityId',
  'userId',
  'userEmail',
  'timestamp',
  'changes',
  'metadata',
];

void main() {
  late List<AuditLogEntry> logged;
  setUp(() {
    logged = [];
    AuditService.recordForTesting = logged.add;
  });
  tearDown(() => AuditService.recordForTesting = null);

  // Each of these used to add an action/actorUid/targetId/details/at row of
  // its own, which the rule refuses, and hid the error.
  group('the old action/at writers now log through logEvent', () {
    test('DNR actions keep their action as the event name', () async {
      await AuditService.logDNRAction(
        facilityId: 'fac1',
        action: 'dnr.create',
        targetId: 'dnr1',
        details: {'name': 'Pat', 'reason': 'Unpaid', 'active': true},
      );
      await AuditService.logDNRAction(
        facilityId: 'fac1',
        action: 'dnr.override',
        targetId: 't1',
        targetType: 'tenant',
        tenantId: 't1',
        details: {'matchedDnrIds': ['dnr1']},
      );
      await AuditService.logDNRAction(
        facilityId: 'fac1',
        action: 'dnr.global.delete',
        targetId: 'g1',
        targetType: 'globalDnr',
      );

      expect(logged.map((e) => e.eventType),
          ['dnr.create', 'dnr.override', 'dnr.global.delete']);
      expect(logged[0].targetType, 'dnr');
      expect(logged[0].targetId, 'dnr1');
      expect(logged[0].tenantId, isNull);
      expect(logged[0].metadata, {'name': 'Pat', 'reason': 'Unpaid', 'active': true});
      expect(logged[1].targetType, 'tenant');
      expect(logged[1].targetId, 't1');
      expect(logged[1].tenantId, 't1');
      expect(logged[1].metadata, {'matchedDnrIds': ['dnr1']});
      expect(logged[2].targetType, 'globalDnr');
      expect(logged[2].metadata, isNull);
    });

    test('ledger entries created and voided, and payments allocated', () async {
      await AuditService.logLedgerEntryCreated(
        facilityId: 'fac1',
        tenantId: 't1',
        entryId: 'e1',
        type: 'charge',
        amount: 40,
        details: {'description': 'Rent'},
      );
      await AuditService.logLedgerEntryVoided(
        facilityId: 'fac1',
        tenantId: 't1',
        entryId: 'e1',
        reason: 'Duplicate',
      );
      await AuditService.logPaymentAllocated(
        facilityId: 'fac1',
        tenantId: 't1',
        paymentId: 'p1',
        allocations: [
          {'chargeId': 'e1', 'amount': 40.0},
        ],
      );

      expect(logged.map((e) => e.eventType),
          ['ledger.entry.created', 'ledger.entry.voided', 'ledger.payment.allocated']);
      expect(logged[0].targetType, 'ledgerEntry');
      expect(logged[0].targetId, 'e1');
      expect(logged[0].tenantId, 't1');
      expect(logged[0].after, {'type': 'charge', 'amount': 40.0});
      expect(logged[0].metadata, {'description': 'Rent'});
      expect(logged[1].targetId, 'e1');
      expect(logged[1].after, isNull);
      expect(logged[1].metadata, {'reason': 'Duplicate'});
      expect(logged[2].targetType, 'payment');
      expect(logged[2].targetId, 'p1');
      expect(logged[2].after, {
        'allocations': [
          {'chargeId': 'e1', 'amount': 40.0},
        ],
        'allocationCount': 1,
      });
    });

    test('move-in and move-out are logged against the contract, for the tenant', () async {
      await AuditService.logMoveInCompleted(
        facilityId: 'fac1',
        tenantId: 't1',
        unitId: 'u1',
        contractId: 'c1',
        totalAmount: 64.52,
      );
      await AuditService.logMoveOutCompleted(
        facilityId: 'fac1',
        tenantId: 't1',
        unitId: 'u1',
        contractId: 'c1',
        charges: 10,
        refund: 5,
        details: {'note': 'Keys returned'},
      );

      expect(logged.map((e) => e.eventType), ['movein.completed', 'moveout.completed']);
      expect(logged[0].targetType, 'moveIn');
      expect(logged[0].targetId, 'c1');
      expect(logged[0].tenantId, 't1');
      expect(logged[0].after, {'unitId': 'u1', 'contractId': 'c1', 'totalAmount': 64.52});
      expect(logged[1].targetType, 'moveOut');
      expect(logged[1].targetId, 'c1');
      expect(logged[1].tenantId, 't1');
      expect(logged[1].after,
          {'unitId': 'u1', 'contractId': 'c1', 'charges': 10.0, 'refund': 5.0});
      expect(logged[1].metadata, {'note': 'Keys returned'});
    });

    test('contact logs, payment methods and autopay', () async {
      await AuditService.logContactLogCreated(
          facilityId: 'fac1', tenantId: 't1', logId: 'l1', type: 'call');
      await AuditService.logPaymentMethodCreated(
          facilityId: 'fac1', tenantId: 't1', methodId: 'm1', type: 'card');
      await AuditService.logPaymentMethodDeleted(
          facilityId: 'fac1', tenantId: 't1', methodId: 'm1');
      await AuditService.logAutopayToggled(
          facilityId: 'fac1', tenantId: 't1', methodId: 'm1', enabled: true);
      await AuditService.logAutopayToggled(
          facilityId: 'fac1', tenantId: 't1', methodId: 'm1', enabled: false);
      await AuditService.logAutopayProcessed(
        facilityId: 'fac1',
        tenantId: 't1',
        methodId: 'm1',
        amount: 40,
        transactionId: 'pi_1',
      );

      expect(logged.map((e) => e.eventType), [
        'contactlog.created',
        'paymentmethod.created',
        'paymentmethod.deleted',
        'autopay.enabled',
        'autopay.disabled',
        'autopay.processed',
      ]);
      expect(logged.map((e) => e.tenantId), everyElement('t1'));
      expect(logged[0].targetType, 'contactLog');
      expect(logged[0].targetId, 'l1');
      expect(logged[0].after, {'type': 'call'});
      for (final e in logged.skip(1)) {
        expect(e.targetType, 'paymentMethod', reason: e.eventType);
        expect(e.targetId, 'm1', reason: e.eventType);
      }
      expect(logged[1].after, {'type': 'card'});
      expect(logged[2].after, isNull);
      expect(logged[3].after, {'enabled': true});
      expect(logged[4].after, {'enabled': false});
      expect(logged[5].after, {'amount': 40.0, 'transactionId': 'pi_1'});
    });

    test('invoices created, paid and voided', () async {
      await AuditService.logInvoiceCreated(
        facilityId: 'fac1',
        tenantId: 't1',
        invoiceId: 'i1',
        invoiceNumber: 'INV-1',
        total: 40,
      );
      await AuditService.logInvoiceAction(
        facilityId: 'fac1',
        tenantId: 't1',
        invoiceId: 'i1',
        invoiceNumber: 'INV-1',
        action: 'paid',
        details: {'amount': 40.0},
      );
      await AuditService.logInvoiceAction(
        facilityId: 'fac1',
        tenantId: 't1',
        invoiceId: 'i1',
        invoiceNumber: 'INV-1',
        action: 'voided',
        details: {'reason': 'Wrong month'},
      );

      expect(logged.map((e) => e.eventType),
          ['invoice.created', 'invoice.paid', 'invoice.voided']);
      for (final e in logged) {
        expect(e.targetType, 'invoice', reason: e.eventType);
        expect(e.targetId, 'i1', reason: e.eventType);
        expect(e.tenantId, 't1', reason: e.eventType);
      }
      expect(logged[0].after, {'invoiceNumber': 'INV-1', 'total': 40.0});
      expect(logged[1].metadata, {'invoiceNumber': 'INV-1', 'amount': 40.0});
      expect(logged[2].metadata, {'invoiceNumber': 'INV-1', 'reason': 'Wrong month'});
    });

    test('transfers, documents and liens', () async {
      await AuditService.logTransferCompleted(
        facilityId: 'fac1',
        tenantId: 't1',
        transferId: 'x1',
        fromUnitNumber: 'A1',
        toUnitNumber: 'B2',
        netAmount: 15,
      );
      await AuditService.logDocumentUploaded(
        facilityId: 'fac1',
        documentId: 'd1',
        fileName: 'lease.pdf',
        documentType: 'lease',
        tenantId: 't1',
      );
      await AuditService.logDocumentDeleted(
          facilityId: 'fac1', documentId: 'd1', fileName: 'lease.pdf');
      await AuditService.logLienCreated(
          facilityId: 'fac1', lienId: 'n1', tenantId: 't1', unitId: 'u1');

      expect(logged.map((e) => e.eventType),
          ['transfer.completed', 'document.uploaded', 'document.deleted', 'lien.created']);
      expect(logged[0].targetType, 'transfer');
      expect(logged[0].targetId, 'x1');
      expect(logged[0].tenantId, 't1');
      expect(logged[0].after,
          {'fromUnitNumber': 'A1', 'toUnitNumber': 'B2', 'netAmount': 15.0});
      expect(logged[1].targetType, 'document');
      expect(logged[1].tenantId, 't1');
      expect(logged[1].after, {'fileName': 'lease.pdf', 'documentType': 'lease'});
      expect(logged[2].targetType, 'document');
      expect(logged[2].tenantId, isNull);
      expect(logged[2].after, isNull);
      expect(logged[2].metadata, {'fileName': 'lease.pdf'});
      expect(logged[3].targetType, 'lien');
      expect(logged[3].targetId, 'n1');
      expect(logged[3].tenantId, 't1');
      expect(logged[3].after, {'unitId': 'u1'});
    });
  });

  test('every one of those rows has what the auditLogs rule requires', () async {
    await AuditService.logDNRAction(
        facilityId: 'fac1', action: 'dnr.toggle', targetId: 'dnr1');
    await AuditService.logLedgerEntryCreated(
        facilityId: 'fac1', tenantId: 't1', entryId: 'e1', type: 'charge', amount: 40);
    await AuditService.logMoveInCompleted(
        facilityId: 'fac1', tenantId: 't1', unitId: 'u1', contractId: 'c1', totalAmount: 40);
    await AuditService.logPaymentMethodDeleted(
        facilityId: 'fac1', tenantId: 't1', methodId: 'm1');
    await AuditService.logInvoiceAction(
        facilityId: 'fac1',
        tenantId: 't1',
        invoiceId: 'i1',
        invoiceNumber: 'INV-1',
        action: 'voided');
    await AuditService.logDocumentDeleted(
        facilityId: 'fac1', documentId: 'd1', fileName: 'lease.pdf');

    expect(logged, hasLength(6));
    for (final e in logged) {
      final row = e.toFirestore();
      for (final key in _ruleKeys) {
        expect(row.containsKey(key), isTrue, reason: '${e.eventType} lacks $key');
      }
      expect(row['facilityId'], 'fac1', reason: e.eventType);
      expect(row['action'], e.eventType);
      expect(row['entityType'], isA<String>(), reason: e.eventType);
      expect(row['timestamp'], isA<Timestamp>(), reason: e.eventType);
      // The Audit Log screen orders by timestamp and titles by eventType.
      expect(row['eventType'], e.eventType);
      expect(row.containsKey('at'), isFalse, reason: e.eventType);
    }
  });

  test('nothing in lib/ writes its own auditLogs map any more', () {
    // Every client write should go through AuditLogEntry.toFirestore, the one
    // shape the rule lets in. The recurring-charges writer is left for PR #33,
    // which retires its callers.
    const allowed = {'lib/services/audit_service.dart#logRecurringChargeGenerated'};
    final hand = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final file in files) {
      final path = file.path.replaceAll('\\', '/');
      final source = file.readAsStringSync();
      var at = source.indexOf("collection('auditLogs')");
      while (at != -1) {
        final end = source.indexOf(';', at);
        final statement = source.substring(at, end == -1 ? source.length : end);
        if (RegExp(r'\.(add|set)\(\s*\{').hasMatch(statement)) {
          final method = RegExp(r'Future<void>\s+(\w+)\(')
              .allMatches(source.substring(0, at))
              .lastOrNull
              ?.group(1);
          hand.add('$path#$method');
        }
        at = source.indexOf("collection('auditLogs')", at + 1);
      }
    }
    // The scan can see a hand-written row: drop this with the allowance once
    // logRecurringChargeGenerated is deleted.
    expect(hand, containsAll(allowed));
    expect(hand.where((w) => !allowed.contains(w)), isEmpty);
  });
}
