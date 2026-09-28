import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:sfcapp/screens/tenant_edit_screen.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/utils/sms_consent.dart';
import 'package:sfcapp/widgets/tenant_contact_edit_dialog.dart';

/// Records what the save was asked to write about SMS consent.
class _FakeOperations extends TenantOperationsNotifier {
  bool saved = false;
  SmsConsentUpdate? consent;

  @override
  Future<String?> updateTenant({
    required String facilityId,
    required String tenantId,
    String? name,
    String? email,
    String? phone,
    String? unitNumber,
    String? unitId,
    double? monthlyRate,
    String? notes,
    bool? isActive,
    String? governmentIdType,
    String? governmentIdNumber,
    String? governmentIdState,
    String? governmentIdCountry,
    DateTime? governmentIdIssuedAt,
    DateTime? governmentIdExpiresAt,
    bool clearGovernmentIdIssuedAt = false,
    bool clearGovernmentIdExpiresAt = false,
    List<TenantContact>? emergencyContacts,
    List<TenantVehicle>? vehicles,
    bool? portalEnabled,
    String? portalAccessCode,
    bool clearPortalAccessCode = false,
    String? portalWelcomeMessage,
    DateTime? portalLastAccessAt,
    bool resetPortalStats = false,
    SmsConsentUpdate? smsConsent,
    ConfirmFreeUnit? confirmFreeOldUnit,
  }) async {
    saved = true;
    consent = smsConsent;
    // A save takes a round trip; the dialog finishes closing meanwhile.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    return null;
  }
}

/// Saving a tenant used to write smsOptInDate = now every time, so the date
/// the tenant actually agreed was lost on any edit, and unticking the box
/// wrote nothing at all.
void main() {
  final agreed = DateTime(2025, 3, 14);
  TenantModel tenant({DateTime? optIn, bool optOut = false, String? source}) => TenantModel(
        id: 't1',
        facilityId: 'f1',
        name: 'Ada Park',
        email: 'ada@example.com',
        phone: '9035550100',
        unitNumber: '101',
        monthlyRate: 100,
        isActive: true,
        createdAt: DateTime(2026, 1, 1),
        smsOptInDate: optIn,
        smsOptOut: optOut,
        smsConsentSource: source,
      );

  final facility = FacilityModel(
    id: 'f1',
    name: 'Keepsake Storage',
    ownerUid: 'owner-1',
    createdAt: DateTime(2025),
  );

  Future<_FakeOperations> pump(WidgetTester tester, Widget Function(WidgetRef ref) home) async {
    tester.view.physicalSize = const Size(1200, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final ops = _FakeOperations();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        tenantOperationsProvider.overrideWith((ref) => ops),
        facilityProvider('f1').overrideWith((ref) async => facility),
        facilityUnitsProvider('f1').overrideWith((ref) => Stream.value(const <UnitModel>[])),
      ],
      child: MaterialApp(
        home: Scaffold(body: Consumer(builder: (context, ref, _) => home(ref))),
      ),
    ));
    await tester.pumpAndSettle();
    return ops;
  }

  Future<void> saveEdit(WidgetTester tester) async {
    final save = find.widgetWithText(ElevatedButton, 'Save Changes');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pump(const Duration(seconds: 1));
    await tester.pumpAndSettle();
  }

  group('Edit Tenant', () {
    testWidgets('shows the one consent label', (tester) async {
      await pump(tester, (_) => TenantEditScreen(tenant: tenant()));
      expect(find.text(smsConsentCheckboxLabel('Keepsake Storage')), findsOneWidget);
      expect(find.text(smsConsentHelperText), findsOneWidget);
    });

    testWidgets('re-saving a consented tenant keeps the date they agreed', (tester) async {
      final ops = await pump(tester, (_) => TenantEditScreen(tenant: tenant(optIn: agreed)));
      await saveEdit(tester);
      expect(ops.saved, isTrue);
      expect(ops.consent, isNull);
    });

    testWidgets('unticking removes consent', (tester) async {
      final ops = await pump(tester, (_) => TenantEditScreen(tenant: tenant(optIn: agreed)));
      final box = find.byKey(const Key('sms-consent-checkbox'));
      await tester.ensureVisible(box);
      await tester.tap(box);
      await saveEdit(tester);
      expect(ops.consent!.grant, isFalse);
      expect(ops.consent!.fields()['smsOptOut'], isTrue);
    });

    testWidgets('ticking records consent', (tester) async {
      final ops = await pump(tester, (_) => TenantEditScreen(tenant: tenant()));
      final box = find.byKey(const Key('sms-consent-checkbox'));
      await tester.ensureVisible(box);
      await tester.tap(box);
      await tester.pump();
      expect(find.byKey(const Key('sms-consent-method')), findsOneWidget);
      await saveEdit(tester);
      expect(ops.consent!.grant, isTrue);
      expect(ops.consent!.fields()['smsConsentStatus'], 'opted_in');
    });

    testWidgets("a tenant's own opt-out is locked and untouched", (tester) async {
      final ops = await pump(
          tester, (_) => TenantEditScreen(tenant: tenant(optOut: true, source: 'inbound_stop')));
      expect(find.textContaining('This tenant texted STOP, so the box is locked'), findsOneWidget);
      await saveEdit(tester);
      expect(ops.saved, isTrue);
      expect(ops.consent, isNull);
    });
  });

  group('Edit Contact Information', () {
    Future<_FakeOperations> open(WidgetTester tester, TenantModel t) async {
      final ops = await pump(
        tester,
        (ref) => Builder(
          builder: (context) => TextButton(
            onPressed: () => editTenantContactInfo(context, ref, t),
            child: const Text('edit'),
          ),
        ),
      );
      await tester.tap(find.text('edit'));
      await tester.pumpAndSettle();
      return ops;
    }

    Future<void> save(WidgetTester tester) async {
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the same label, and a re-save keeps the date', (tester) async {
      final ops = await open(tester, tenant(optIn: agreed));
      expect(find.text(smsConsentCheckboxLabel('Keepsake Storage')), findsOneWidget);
      await save(tester);
      expect(ops.saved, isTrue);
      expect(ops.consent, isNull);
    });

    testWidgets('ticking records consent', (tester) async {
      final ops = await open(tester, tenant());
      await tester.tap(find.byKey(const Key('sms-consent-checkbox')));
      await tester.pump();
      await save(tester);
      expect(ops.consent!.grant, isTrue);
    });
  });
}
