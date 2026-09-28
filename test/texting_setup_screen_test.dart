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
  List<String>? submittedSamples;
  List<String>? submittedConsentMethods;
  int provisionCount = 0;

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
    provisionCount++;
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
    List<String> consentMethods = const [],
    String? areaCode,
  }) async {
    submittedSamples = sampleMessages;
    submittedConsentMethods = consentMethods;
    return snapshots[facilityId]!;
  }
}

const _business = TextingBusinessDetails(
  legalBusinessName: 'Example Storage LLC',
  businessType: 'LLC',
  einLast4: '6789',
  addressLine1: '100 Main Street',
  city: 'Austin',
  state: 'TX',
  postalCode: '78701',
  website: 'https://storage.example',
  supportEmail: 'help@storage.example',
  supportPhone: '5125550100',
  // Carrier vetting requires a named authorized representative, so business
  // details are not complete without one.
  representativeFirstName: 'Dana',
  representativeLastName: 'Reyes',
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

/// A facility whose trust profile exists but whose saved details predate the
/// authorized-representative fields, so they are incomplete.
const _businessMissingRep = TextingBusinessDetails(
  legalBusinessName: 'Example Storage',
  businessType: 'LLC',
  einLast4: '6789',
  addressLine1: '100 Main Street',
  city: 'Austin',
  state: 'TX',
  postalCode: '78701',
  website: 'https://storage.example',
  supportEmail: 'help@storage.example',
  supportPhone: '5125550100',
);

const _profileWithIncompleteDetails = TextingOnboardingSnapshot(
  status: TextingRegistrationStatus.draft,
  platformApproved: false,
  businessDetails: _businessMissingRep,
  hasTrustProfile: true,
);

/// Bundle handed to Twilio: editing now would restart the review.
const _lockedSnapshot = TextingOnboardingSnapshot(
  status: TextingRegistrationStatus.draft,
  platformApproved: false,
  businessDetails: _businessMissingRep,
  hasTrustProfile: true,
  businessDetailsLocked: true,
);

/// Profile passed and is in review; the A2P trust product failed evaluation.
/// The product can be rebuilt, the profile's own fields cannot change.
const _profileInReviewSnapshot = TextingOnboardingSnapshot(
  status: TextingRegistrationStatus.draft,
  platformApproved: false,
  businessDetails: _business,
  hasTrustProfile: true,
  profileDetailsLocked: true,
  lockReason: 'Your business profile is with Twilio for review.',
  bundleProfileStatus: 'in-review',
  bundleProductStatus: 'draft',
  bundleIssues: 'A2P Messaging Profile Information - Company Type: invalid',
);

/// Saved details and a single message type chosen, bundles approved by
/// Twilio: resumes at review with the submit button enabled.
const _oneUseCaseSnapshot = TextingOnboardingSnapshot(
  status: TextingRegistrationStatus.draft,
  platformApproved: false,
  businessDetails: _business,
  useCases: ['Payment reminders'],
  consentMethods: ['online_form'],
  senderName: 'Example Self Storage',
  hasTrustProfile: true,
  bundleReady: true,
  bundleApproved: true,
  bundleProfileStatus: 'twilio-approved',
  bundleProductStatus: 'twilio-approved',
);

/// Same, but Twilio is still reviewing the A2P messaging registration.
const _awaitingApprovalSnapshot = TextingOnboardingSnapshot(
  status: TextingRegistrationStatus.draft,
  platformApproved: false,
  businessDetails: _business,
  useCases: ['Payment reminders'],
  consentMethods: ['online_form'],
  hasTrustProfile: true,
  bundleReady: true,
  bundleProfileStatus: 'twilio-approved',
  bundleProductStatus: 'in-review',
);

/// At "Review and submit" (details and plan saved), by what Twilio's
/// pre-check said about the business details.
/// `bundleApproved` defaults to true so these cases isolate the pre-check;
/// the approval lock has its own test.
TextingOnboardingSnapshot _atReview({
  required bool bundleReady,
  String? bundleIssues,
  bool bundleApproved = true,
}) =>
    TextingOnboardingSnapshot(
      status: TextingRegistrationStatus.draft,
      platformApproved: false,
      businessDetails: _business,
      useCases: const ['Payment reminders'],
      consentMethods: const ['online_form'],
      hasTrustProfile: true,
      bundleReady: bundleReady,
      bundleApproved: bundleApproved,
      bundleIssues: bundleIssues,
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

    testWidgets('business details stay editable while the bundle is a draft',
        (tester) async {
      // Regression: the form locked as soon as a trust profile SID existed.
      // Keepsake had a profile holding an empty shell and placeholder details,
      // so the owner was locked out of correcting the very data that was
      // blocking registration. A draft bundle can be rebuilt, so it must edit.
      await _pumpScreen(
          tester,
          _FakeRepository({
            'facility-1': _profileWithIncompleteDetails,
          }));

      expect(_profileWithIncompleteDetails.hasTrustProfile, isTrue);
      final ein = tester.widget<TextFormField>(find.byKey(const Key('ein')));
      expect(ein.enabled, isNot(false));
      expect(find.text('Business profile submitted'), findsNothing);
    });

    testWidgets('business details lock once the carrier is reviewing them',
        (tester) async {
      await _pumpScreen(
          tester,
          _FakeRepository({
            'facility-1': _lockedSnapshot,
          }));
      await tester.pumpAndSettle();

      expect(find.text('Business profile submitted'), findsOneWidget);
    });

    testWidgets(
        'profile in review: profile fields locked, product can be resubmitted',
        (tester) async {
      await _pumpScreen(
          tester,
          _FakeRepository({
            'facility-1': _profileInReviewSnapshot,
          }));
      // Resume step is 1 for complete details; go back to business details.
      await tester.tap(find.text('Business details').first);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('profile-locked-callout')), findsOneWidget);
      expect(find.text('Your business profile is with Twilio for review.'),
          findsOneWidget);
      expect(
        tester
            .widget<TextFormField>(find.byKey(const Key('legal-business-name')))
            .enabled,
        isFalse,
      );
      expect(
        tester.widget<TextFormField>(find.byKey(const Key('ein'))).enabled,
        isFalse,
      );
      expect(
        tester.widget<TextFormField>(find.byKey(const Key('dba'))).enabled,
        isNot(false),
      );
      expect(find.text('Resubmit A2P registration'), findsOneWidget);
      expect(
        tester
            .widget<Text>(find.byKey(const Key('bundle-profile-status')))
            .data,
        'In review at Twilio',
      );
      expect(
        tester
            .widget<Text>(find.byKey(const Key('bundle-product-status')))
            .data,
        'Not submitted',
      );
      expect(find.text('Carrier profile needs corrections'), findsOneWidget);
    });

    testWidgets('always submits at least two sample messages', (tester) async {
      final repository = _FakeRepository({'facility-1': _oneUseCaseSnapshot});
      await _pumpScreen(tester, repository);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('review-stage')), findsOneWidget);
      await tester.tap(find.byKey(const Key('consent-confirmation')));
      await tester.pump();
      tester
          .widget<FilledButton>(find.byKey(const Key('primary-stage-action')))
          .onPressed!();
      await tester.pumpAndSettle();

      final samples = repository.submittedSamples!;
      expect(samples.length, greaterThanOrEqualTo(2));
      expect(samples.toSet().length, samples.length);
      for (final sample in samples) {
        // The server's sender name, which live texts also open with.
        expect(sample, startsWith('Example Self Storage:'));
        expect(sample.length, greaterThanOrEqualTo(20));
      }
      expect(repository.submittedConsentMethods, ['online_form']);
      // The number is reserved inside the one submit call, after the server's
      // checks, never by a separate provisionPhoneNumber call first.
      expect(repository.provisionCount, 0);
    });

    testWidgets('submit stays disabled until Twilio approves both bundles',
        (tester) async {
      final repository =
          _FakeRepository({'facility-1': _awaitingApprovalSnapshot});
      await _pumpScreen(tester, repository);
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('review-stage')), findsOneWidget);
      expect(find.byKey(const Key('awaiting-bundle-approval')), findsOneWidget);
      expect(find.textContaining('A2P messaging registration: In review at Twilio'),
          findsOneWidget);
      final button = tester
          .widget<FilledButton>(find.byKey(const Key('primary-stage-action')));
      expect(button.onPressed, isNull);
      expect(repository.submittedSamples, isNull);
      expect(repository.provisionCount, 0);
    });

    testWidgets('messaging plan requires a consent method', (tester) async {
      await _pumpScreen(
          tester,
          _FakeRepository({
            'facility-1': _savedDraftSnapshot,
          }));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('messaging-plan-stage')), findsOneWidget);
      expect(find.byKey(const Key('consent-method-error')), findsOneWidget);
      // START only restores a tenant's own STOP, so it is not offered as a
      // way to opt in (and therefore never filed with the carriers).
      expect(find.byKey(const Key('consent-method-text_start')), findsNothing);
      expect(find.textContaining('START'), findsNothing);
      tester
          .widget<FilledButton>(find.byKey(const Key('primary-stage-action')))
          .onPressed!();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('messaging-plan-stage')), findsOneWidget,
          reason: 'cannot continue without a consent method');

      tester
          .widget<CheckboxListTile>(
              find.byKey(const Key('consent-method-signed_form')))
          .onChanged!(true);
      await tester.pump();
      expect(find.byKey(const Key('consent-method-error')), findsNothing);
      tester
          .widget<FilledButton>(find.byKey(const Key('primary-stage-action')))
          .onPressed!();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('review-stage')), findsOneWidget);
    });

    testWidgets('requires a named authorized representative', (tester) async {
      // The carrier customer-profile policy will not approve a bundle without
      // authorized_representative_1, so the form has to collect it.
      await _pumpScreen(
          tester,
          _FakeRepository({
            'facility-1': _draftSnapshot,
          }));

      expect(find.byKey(const Key('rep-first-name')), findsOneWidget);
      expect(find.byKey(const Key('rep-last-name')), findsOneWidget);

      final action = find.byKey(const Key('primary-stage-action'));
      tester.widget<FilledButton>(action).onPressed!();
      await tester.pump();

      expect(find.text("Enter the representative's first name."), findsOneWidget);
      expect(find.text("Enter the representative's last name."), findsOneWidget);
    });

    group('Reserve number & submit', () {
      // It buys a phone number before the brand step, and the brand step
      // refuses a bundle Twilio's pre-check flagged: pressing it then paid
      // for a number the facility could not use.
      Future<_FakeRepository> openReview(
          WidgetTester tester, TextingOnboardingSnapshot snapshot) async {
        final repository = _FakeRepository({'facility-1': snapshot});
        await _pumpScreen(tester, repository);
        expect(find.byKey(const Key('review-stage')), findsOneWidget);
        return repository;
      }

      FilledButton reserve(WidgetTester tester) =>
          tester.widget<FilledButton>(find.byKey(const Key('primary-stage-action')));

      testWidgets('is locked, with the reason, when the pre-check flagged the details',
          (tester) async {
        final repository = await openReview(
            tester, _atReview(bundleReady: false, bundleIssues: 'Address could not be verified'));
        expect(find.text('Reserve number & submit'), findsOneWidget);
        expect(reserve(tester).onPressed, isNull);
        expect(find.byKey(const Key('reserve-blocked')), findsOneWidget);
        expect(find.textContaining(reserveNumberBlockedMessage), findsOneWidget);
        expect(find.textContaining('Flagged: Address could not be verified'), findsOneWidget);
        expect(repository.provisionCount, 0);
      });

      testWidgets('is locked while the bundle has not passed the pre-check, and says why',
          (tester) async {
        // Also what a Twilio dry-run setup shows: it never sets bundleReady.
        await openReview(tester, _atReview(bundleReady: false));
        expect(reserve(tester).onPressed, isNull);
        expect(find.text(reserveNumberNotCheckedMessage), findsOneWidget);
        expect(find.textContaining('dry-run'), findsOneWidget);
      });

      testWidgets('is locked when ready but issues are still listed', (tester) async {
        await openReview(tester, _atReview(bundleReady: true, bundleIssues: 'EIN mismatch'));
        expect(reserve(tester).onPressed, isNull);
      });

      testWidgets('is open once the pre-check passed', (tester) async {
        await openReview(tester, _atReview(bundleReady: true));
        expect(reserve(tester).onPressed, isNotNull);
        expect(find.byKey(const Key('reserve-blocked')), findsNothing);
      });

      testWidgets('stays locked after the pre-check until Twilio approves both bundles',
          (tester) async {
        await openReview(
            tester, _atReview(bundleReady: true, bundleApproved: false));
        expect(reserve(tester).onPressed, isNull);
        expect(find.byKey(const Key('awaiting-bundle-approval')), findsOneWidget);
        expect(find.byKey(const Key('reserve-blocked')), findsNothing);
      });

      test('readyToReserveNumber', () {
        expect(_atReview(bundleReady: true).readyToReserveNumber, isTrue);
        expect(_atReview(bundleReady: true, bundleIssues: '  ').readyToReserveNumber, isTrue);
        expect(_atReview(bundleReady: false).readyToReserveNumber, isFalse);
        expect(_atReview(bundleReady: true, bundleIssues: 'x').readyToReserveNumber, isFalse);
      });
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
    name: 'Example Self Storage',
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
