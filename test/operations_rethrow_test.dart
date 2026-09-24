import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/contract_model.dart';
import 'package:sfcapp/models/invoice_model.dart';
import 'package:sfcapp/models/reminder_model.dart';
import 'package:sfcapp/providers/contract_provider.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/gate_access_provider.dart';
import 'package:sfcapp/providers/invoice_provider.dart';
import 'package:sfcapp/providers/reminder_provider.dart';
import 'package:sfcapp/providers/reminder_schedule_provider.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:state_notifier/state_notifier.dart';

// There is no Firebase app in tests, so every write below fails inside the
// real service, as a dropped connection or a refused write does in the app.
// These notifiers used to record the failure and return normally, so the
// pages that awaited them said "sent", "archived", "deleted" or "restored".

/// Runs [call] on [notifier] and expects it to fail and to leave the
/// failure in its state.
Future<void> _expectFails<N extends StateNotifier<AsyncValue<void>>>(
  N notifier,
  Future<void> Function(N notifier) call, {
  Matcher error = anything,
}) async {
  addTearDown(notifier.dispose);
  AsyncValue<void>? last;
  notifier.addListener((state) => last = state, fireImmediately: false);
  await expectLater(call(notifier), throwsA(error));
  expect(last, isA<AsyncError<void>>());
}

final _invoice = InvoiceModel(
  id: 'i1',
  tenantId: 't1',
  facilityId: 'f1',
  invoiceNumber: 'INV-1',
  status: InvoiceStatus.draft,
  issueDate: DateTime(2026, 9, 1),
  dueDate: DateTime(2026, 9, 15),
  subtotal: 100,
  total: 100,
  balance: 100,
  lineItems: const [],
  ledgerEntryIds: const [],
  paymentIds: const [],
  createdAt: DateTime(2026, 9, 1),
  createdBy: 'owner',
);

void main() {
  group('reminders', () {
    ReminderOperationsNotifier make() => ReminderOperationsNotifier();

    // ReminderService.sendReminder catches its own failures and returns
    // false; that was ignored, and the reminder page said "Reminder sent
    // successfully" with nothing sent.
    test('Send fails when no channel went through', () async {
      await _expectFails(
        make(),
        (n) => n.sendReminder(
          facilityId: 'f1',
          reminderId: 'r1',
          tenantEmail: 'pat@example.com',
          tenantPhone: '',
          message: 'Rent is due',
          channels: const [ReminderChannel.email],
        ),
        error: isA<ReminderNotSentException>(),
      );
    });

    test('Mark as sent', () async {
      await _expectFails(make(), (n) => n.markAsSent('f1', 'r1'));
    });

    test('Mark as read', () async {
      await _expectFails(make(), (n) => n.markAsRead('f1', 'r1'));
    });

    test('Cancel', () async {
      await _expectFails(make(), (n) => n.cancelReminder('f1', 'r1'));
    });

    test('Delete', () async {
      await _expectFails(make(), (n) => n.deleteReminder('f1', 'r1'));
    });

    test('Create', () async {
      await _expectFails(
        make(),
        (n) => n.createReminder(
          facilityId: 'f1',
          tenantId: 't1',
          title: 'Rent due',
          message: 'Rent is due',
          scheduledFor: DateTime(2026, 10, 1),
          channels: const [ReminderChannel.email],
        ),
      );
    });

    test('Update, mark sent by id and archive', () async {
      await _expectFails(
        make(),
        (n) => n.updateReminder(facilityId: 'f1', reminderId: 'r1', title: 'x'),
      );
      await _expectFails(
        make(),
        (n) => n.markReminderAsSent(facilityId: 'f1', reminderId: 'r1'),
      );
      await _expectFails(make(), (n) => n.archiveReminder('f1', 'r1'));
    });
  });

  group('reminder schedules', () {
    ReminderScheduleOperationsNotifier make() =>
        ReminderScheduleOperationsNotifier();

    // Pausing said "paused" while the schedule went on sending.
    test('Pause and delete', () async {
      await _expectFails(
        make(),
        (n) => n.toggleSchedule(
          facilityId: 'f1',
          scheduleId: 's1',
          isActive: false,
        ),
      );
      await _expectFails(
        make(),
        (n) => n.deleteSchedule(facilityId: 'f1', scheduleId: 's1'),
      );
    });

    test('Create and update', () async {
      await _expectFails(
        make(),
        (n) => n.createSchedule(
          facilityId: 'f1',
          name: 'Rent due',
          type: ReminderType.rentDue,
          channels: const [ReminderChannel.email],
          sendMode: ReminderSendMode.immediate,
          offsetDays: 3,
          sendTime: '09:00',
          autoSend: false,
          isActive: true,
          titleTemplate: 'Rent due',
          messageTemplate: 'Rent is due',
        ),
      );
      await _expectFails(
        make(),
        (n) => n.updateSchedule(facilityId: 'f1', scheduleId: 's1', name: 'x'),
      );
    });
  });

  group('invoices', () {
    InvoiceOperationsNotifier make() => InvoiceOperationsNotifier();

    // "Send to tenant" said "Invoice sent successfully".
    test('Send to tenant', () async {
      await _expectFails(
        make(),
        (n) => n.sendInvoice(facilityId: 'f1', invoiceId: 'i1'),
      );
    });

    // The ledger's Generate Invoice said "Invoice generated successfully".
    test('Generate Invoice', () async {
      await _expectFails(
        make(),
        (n) => n.generateInvoice(
          tenantId: 't1',
          facilityId: 'f1',
          ledgerEntryIds: const ['e1'],
        ),
      );
    });

    test('Generate PDF', () async {
      await _expectFails(
        make(),
        (n) => n.generateAndUploadPDF(
          invoice: _invoice,
          facilityId: 'f1',
          invoiceId: 'i1',
        ),
      );
    });
  });

  group('contracts', () {
    ContractOperationsNotifier make() => ContractOperationsNotifier();

    // Delete on the Contracts list failed without a word.
    test('Delete', () async {
      await _expectFails(make(), (n) => n.deleteContract('f1', 'c1'));
    });

    test('Update, send and sign', () async {
      await _expectFails(
        make(),
        (n) => n.updateContract(facilityId: 'f1', contractId: 'c1', title: 'x'),
      );
      await _expectFails(
        make(),
        (n) => n.sendContract(facilityId: 'f1', contractId: 'c1', sentBy: 'u1'),
      );
      await _expectFails(
        make(),
        (n) => n.signContract(
          facilityId: 'f1',
          contractId: 'c1',
          signedBy: 'u1',
          signedFileUrl: 'https://example.com/c1.pdf',
        ),
      );
    });

    test('Create template', () async {
      await _expectFails(
        ContractTemplateOperationsNotifier(),
        (n) => n.createContractTemplate(
          facilityId: 'f1',
          name: 'Lease',
          description: '',
          content: 'Terms',
          type: ContractType.lease,
        ),
      );
    });
  });

  group('units', () {
    UnitOperationsNotifier make() => UnitOperationsNotifier();

    // The Units list said "archived" / "deleted" for units still there.
    test('Archive and delete', () async {
      await _expectFails(make(), (n) => n.archiveUnit('f1', 'u1'));
      await _expectFails(make(), (n) => n.deleteUnit('f1', 'u1'));
    });

    test('Create, update, assign and unassign', () async {
      await _expectFails(
        make(),
        (n) => n.createUnit(
          facilityId: 'f1',
          unitNumber: 'A1',
          unitType: 'standard',
          monthlyRate: 100,
        ),
      );
      await _expectFails(
        make(),
        (n) => n.updateUnit(facilityId: 'f1', unitId: 'u1', notes: 'x'),
      );
      await _expectFails(
        make(),
        (n) => n.assignTenantToUnit(
          facilityId: 'f1',
          unitId: 'u1',
          tenantId: 't1',
          tenantName: 'Pat Renter',
        ),
      );
      await _expectFails(
        make(),
        (n) => n.removeTenantFromUnit(facilityId: 'f1', unitId: 'u1'),
      );
    });
  });

  group('facilities', () {
    FacilityOperationsNotifier make() => FacilityOperationsNotifier();

    // Facilities said "restored successfully".
    test('Restore', () async {
      await _expectFails(make(), (n) => n.restoreFacility('f1'));
    });

    // Facilities said "archived successfully".
    test('Archive', () async {
      await _expectFails(make(), (n) => n.softDeleteFacility('f1'));
    });

    test('Create and update', () async {
      await _expectFails(make(), (n) => n.createFacility(name: 'Oak Storage'));
      await _expectFails(
        make(),
        (n) => n.updateFacility(facilityId: 'f1', name: 'Oak Storage'),
      );
    });
  });

  group('gate access', () {
    GateAccessOperationsNotifier make() => GateAccessOperationsNotifier();

    // Delete said "Access code ... deleted"; the editor closed on a failed
    // save.
    test('Create, update and delete', () async {
      await _expectFails(
        make(),
        (n) => n.createGateAccess(facilityId: 'f1', accessCode: '1234'),
      );
      await _expectFails(
        make(),
        (n) => n.updateGateAccess(
          facilityId: 'f1',
          accessId: 'g1',
          isActive: false,
        ),
      );
      await _expectFails(
        make(),
        (n) => n.deleteGateAccess(facilityId: 'f1', accessId: 'g1'),
      );
    });
  });
}
