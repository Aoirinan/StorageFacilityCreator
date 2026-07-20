import 'package:firebase_auth_mocks/firebase_auth_mocks.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sfcapp/controllers/texting_onboarding_controller.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/models/texting_onboarding_model.dart';
import 'package:sfcapp/screens/texting_setup_screen.dart';
import 'package:sfcapp/services/texting_onboarding_service.dart';

class _FakeRepository implements TextingOnboardingRepository {
  final Map<String, TextingOnboardingSnapshot> snapshots;
  int refreshCount = 0;
  int resetCount = 0;

  _FakeRepository(this.snapshots);

  @override
  Future<TextingOnboardingSnapshot> getStatus(String facilityId) async {
    return snapshots[facilityId]!;
  }

  @override
  Future<TextingOnboardingSnapshot> provisionPhoneNumber({
    required String facilityId,
    String? areaCode,
  }) async {
    return snapshots[facilityId]!;
  }

  @override
  Future<void> resubmit(String facilityId) async {
    resetCount++;
    snapshots[facilityId] = _draftSnapshot;
  }

  @override
  Future<TextingOnboardingSnapshot> refreshStatus(String facilityId) async {
    refreshCount++;
    return snapshots[facilityId]!;
  }

  @override
  Future<void> saveBusinessInfo({
    required String facilityId,
    required Map<String, dynamic> businessData,
  }) async {}

  @override
  Future<void> setPlatformApproval({
    required String facilityId,
    required bool approved,
  }) async {
    final current = snapshots[facilityId]!;
    snapshots[facilityId] = TextingOnboardingSnapshot(
      status: current.status,
      platformApproved: approved,
      phoneNumber: current.phoneNumber,
      businessDetails: current.businessDetails,
      useCases: current.useCases,
      hasTrustProfile: current.hasTrustProfile,
    );
  }

  @override
  Future<TextingOnboardingSnapshot> submitOnboarding({
    required String facilityId,
    required List<String> useCases,
    required List<String> sampleMessages,
  }) async {
    return snapshots[facilityId]!;
  }
}

const _business = TextingBusinessDetails(
  legalBusinessName: 'Keepsake Storage LLC',
  businessType: 'LLC',
  einLast4: '6789',
  addressLine1: '100 Main Street',
  city: 'Austin',
  state: 'TX',
  postalCode: '78701',
  website: 'https://keepsake.example',
  supportEmail: 'help@keepsake.example',
  supportPhone: '5125550100',
);

const _draftSnapshot = TextingOnboardingSnapshot(
  status: TextingRegistrationStatus.draft,
  platformApproved: false,
  hasTrustProfile: false,
);

const _savedDraftSnapshot = TextingOnboardingSnapshot(
  status: TextingRegistrationStatus.draft,
  platformApproved: false,
  businessDetails: _business,
  hasTrustProfile: true,
);

const _pendingSnapshot = TextingOnboardingSnapshot(
  status: TextingRegistrationStatus.pending,
  platformApproved: false,
  phoneNumber: '+15125550100',
  businessDetails: _business,
  useCases: ['Payment reminders'],
  hasTrustProfile: true,
);

const _approvedSnapshot = TextingOnboardingSnapshot(
  status: TextingRegistrationStatus.approved,
  platformApproved: false,
  phoneNumber: '+15125550100',
  businessDetails: _business,
  useCases: ['Payment reminders'],
  hasTrustProfile: true,
);

const _rejectedSnapshot = TextingOnboardingSnapshot(
  status: TextingRegistrationStatus.rejected,
  platformApproved: false,
  rejectionReason: 'CTA could not be verified',
  phoneNumber: '+15125550100',
  businessDetails: _business,
  useCases: ['Payment reminders'],
  hasTrustProfile: true,
);

void main() {
  group('TextingOnboardingController', () {
    test('resumes saved draft at messaging plan', () async {
      final controller = TextingOnboardingController(
        repository: _FakeRepository({'facility-1': _savedDraftSnapshot}),
      );

      await controller.load('facility-1');

      expect(controller.step, 1);
      expect(controller.showDashboard, isFalse);
      controller.dispose();
    });

    test('switches facilities and derives dashboard state', () async {
      final controller = TextingOnboardingController(
        repository: _FakeRepository({
          'facility-1': _savedDraftSnapshot,
          'facility-2': _pendingSnapshot,
        }),
      );

      await controller.load('facility-1');
      await controller.load('facility-2');

      expect(controller.facilityId, 'facility-2');
      expect(controller.showDashboard, isTrue);
      expect(controller.shouldPoll, isTrue);
      controller.dispose();
    });

    test('resets rejected registration to saved draft', () async {
      final repository = _FakeRepository({'facility-1': _rejectedSnapshot});
      final controller = TextingOnboardingController(repository: repository);
      await controller.load('facility-1');

      final success = await controller.resetAfterRejection();

      expect(success, isTrue);
      expect(repository.resetCount, 1);
      expect(controller.showDashboard, isFalse);
      controller.dispose();
    });
  });

  group('TextingSetupScreen', () {
    testWidgets('shows required validation on an empty business form',
        (tester) async {
      await _pumpScreen(
          tester,
          _FakeRepository({
            'facility-1': _draftSnapshot,
          }));

      final action = find.byKey(const Key('primary-stage-action'));
      tester.widget<FilledButton>(action).onPressed!();
      await tester.pump();

      expect(find.text('Enter the legal business name.'), findsOneWidget);
      expect(find.text('Enter a valid 9-digit EIN.'), findsOneWidget);
      expect(
        find.text('Enter a full website URL, including https://.'),
        findsOneWidget,
      );
    });

    testWidgets('opens pending registration on status dashboard',
        (tester) async {
      await _pumpScreen(
          tester,
          _FakeRepository({
            'facility-1': _pendingSnapshot,
          }));

      expect(find.byKey(const Key('status-pending')), findsOneWidget);
      expect(find.text('Registration under review'), findsOneWidget);
      expect(find.text('+15125550100'), findsOneWidget);
      expect(find.text('Approve texting'), findsNothing);
    });

    testWidgets('shows platform controls only to superadmins', (tester) async {
      await _pumpScreen(
        tester,
        _FakeRepository({'facility-1': _approvedSnapshot}),
        isSuperAdmin: true,
      );

      expect(find.text('SFC platform review'), findsOneWidget);
      expect(find.text('Approve texting'), findsOneWidget);
    });

    testWidgets('shows rejection reason and recovery action', (tester) async {
      await _pumpScreen(
          tester,
          _FakeRepository({
            'facility-1': _rejectedSnapshot,
          }));

      expect(find.text('Registration needs attention'), findsOneWidget);
      expect(find.text('CTA could not be verified'), findsOneWidget);
      expect(find.text('Review and resubmit'), findsOneWidget);
    });
  });
}

Future<void> _pumpScreen(
  WidgetTester tester,
  TextingOnboardingRepository repository, {
  bool isSuperAdmin = false,
}) async {
  tester.view.physicalSize = const Size(1200, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
  final user = MockUser(uid: 'user-1', email: 'owner@example.com');
  final facility = FacilityModel(
    id: 'facility-1',
    name: 'Keepsake Self Storage',
    ownerUid: user.uid,
    createdAt: DateTime(2025),
  );

  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        home: TextingSetupScreen(
          facilityId: facility.id,
          repository: repository,
          isSuperAdminOverride: isSuperAdmin,
          facilitiesOverride: [facility],
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}
