import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/stays/stays_callable_models.dart';
import 'package:sfcapp/screens/stays/stays_setup_wizard_screen.dart';
import 'package:sfcapp/services/stays/stays_collections.dart';
import 'package:sfcapp/utils/request_id.dart';

import 'support/stays_widget_harness.dart';

// Made-up facility and listings only.

Finder _next() => find.byKey(const Key('stays-setup-next'));

bool _enabled(WidgetTester tester, Finder finder) => tester.widget<ButtonStyleButton>(finder).onPressed != null;

Future<void> _pickZone(WidgetTester tester, String zone) async {
  await tester.tap(find.byKey(const Key('stays-setup-zone')));
  await settle(tester);
  await tester.tap(find.textContaining('($zone)').last);
  await settle(tester);
}

void main() {
  testWidgets('time zone: nothing is picked for the owner, and Next waits for an explicit confirm', (tester) async {
    final h = StaysWidgetHarness(facilityTimeZone: 'America/Chicago');
    h.callables.onSetControls = (req) => StaysSetControlsResult.fromJson({
          'controls': req.changes.toJson(),
          'warnings': [
            {'code': 'facility_timezone_mismatch', 'message': 'Stays uses America/Denver, but the facility is set to America/Chicago.'},
          ],
        }, facilityId: req.facilityId);
    await h.pump(tester, StaysSetupWizardScreen(facilityId: h.facilityId));

    expect(find.text('Step 1 of 5 · Confirm your time zone'), findsOneWidget);
    expect(find.text('Choose a time zone'), findsOneWidget);
    expect(_enabled(tester, _next()), isFalse);
    expect(_enabled(tester, find.byKey(const Key('stays-setup-confirm-zone'))), isFalse);
    // The facility's zone is offered, not chosen.
    expect(find.textContaining('Your facility settings say Central (Chicago)'), findsOneWidget);
    expect(h.callables.calls, isEmpty);

    await _pickZone(tester, 'America/Denver');
    expect(find.byKey(const Key('stays-setup-zone-mismatch')), findsOneWidget);
    expect(_enabled(tester, _next()), isFalse, reason: 'picked is not confirmed');

    await tester.tap(find.byKey(const Key('stays-setup-confirm-zone')));
    await settle(tester);

    final requests = h.callables.requestsOf<StaysSetControlsRequest>(StaysCallableNames.setControls);
    expect(requests, hasLength(1));
    expect(requests.single.changes.toJson(), {'timeZone': 'America/Denver'});
    expect(requests.single.confirmTimeZone, isTrue);
    expect(find.byKey(const Key('stays-setup-zone-confirmed')), findsOneWidget);
    expect(find.textContaining('but the facility is set to America/Chicago'), findsOneWidget);
    expect(_enabled(tester, _next()), isTrue);
  });

  testWidgets('time zone: "Use it" fills in the facility zone but still needs Confirm', (tester) async {
    final h = StaysWidgetHarness(facilityTimeZone: 'America/Denver');
    await h.pump(tester, StaysSetupWizardScreen(facilityId: h.facilityId));
    await tester.tap(find.byKey(const Key('stays-setup-use-facility-zone')));
    await settle(tester);
    expect(find.text('Confirm Mountain (Denver)'), findsOneWidget);
    expect(find.byKey(const Key('stays-setup-zone-mismatch')), findsNothing);
    expect(h.callables.calls, isEmpty);
    expect(_enabled(tester, _next()), isFalse);
  });

  testWidgets('listings, then turning Stays on, then calendars', (tester) async {
    final h = StaysWidgetHarness();
    h.seedControls(moduleEnabled: false);
    h.callables.onSaveListing = (req) {
      final id = 'lst_${req.requestId}';
      h.repository.seed(h.facilityId, StaysCollections.listings, id, {...req.listing, 'facilityId': h.facilityId, 'version': 1});
      return StaysSaveListingResult(listingId: id, version: 1);
    };
    await h.pump(tester, StaysSetupWizardScreen(facilityId: h.facilityId));

    // Already confirmed: shown, and Next is open.
    expect(find.byKey(const Key('stays-setup-zone-confirmed')), findsOneWidget);
    await tester.tap(_next());
    await settle(tester);
    expect(find.text('Step 2 of 5 · Add your listings'), findsOneWidget);
    expect(_enabled(tester, _next()), isFalse, reason: 'no listings yet');

    await tester.tap(find.byKey(const Key('stays-setup-add-listing')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('stay-listing-name')), 'Blue House');
    await tester.tap(find.byKey(const Key('stay-listing-kind')));
    await settle(tester);
    await tester.tap(find.text('House').last);
    await settle(tester);
    await tester.enterText(find.byKey(const Key('stay-listing-rate')), '125');
    await tester.tap(find.byKey(const Key('stay-listing-save')));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 500)); // the dialog's exit animation

    final saves = h.callables.requestsOf<StaysSaveListingRequest>(StaysCallableNames.saveListing);
    expect(saves, hasLength(1));
    expect(isValidRequestId(saves.single.requestId), isTrue);
    expect(saves.single.listingId, isNull);
    expect(saves.single.listing['name'], 'Blue House');
    expect(saves.single.listing['kind'], 'house');
    expect(saves.single.listing['shortCode'], 'BH');
    expect(saves.single.listing['active'], isTrue);
    expect((saves.single.listing['ratesCents'] as Map)['nightly'], 12500);
    final listingId = 'lst_${saves.single.requestId}';
    expect(find.byKey(Key('stays-setup-listing-$listingId')), findsOneWidget);
    expect(find.byKey(const Key('stay-listing-save')), findsNothing, reason: 'the dialog closed');
    expect(_enabled(tester, _next()), isTrue);

    await tester.tap(_next());
    await settle(tester);
    expect(find.text('Step 3 of 5 · Turn on Stays'), findsOneWidget);
    expect(_enabled(tester, _next()), isFalse);
    await tester.tap(find.byKey(const Key('stays-setup-turn-on')));
    await settle(tester);
    final controls = h.callables.requestsOf<StaysSetControlsRequest>(StaysCallableNames.setControls);
    expect(controls.single.changes.toJson(), {'moduleEnabled': true});
    expect(find.byKey(const Key('stays-setup-on')), findsOneWidget);

    await tester.tap(_next());
    await settle(tester);
    expect(find.text('Step 4 of 5 · Connect calendars'), findsOneWidget);
    expect(find.byKey(Key('stays-add-channel-$listingId')), findsOneWidget);
    expect(find.byKey(const Key('stays-export-off-note')), findsOneWidget);

    await tester.tap(_next());
    await settle(tester);
    expect(find.byKey(const Key('stays-setup-open-calendar')), findsOneWidget);
  });

  testWidgets('a failed listing save shows the server message and keeps the dialog open', (tester) async {
    final h = StaysWidgetHarness();
    h.seedControls(moduleEnabled: false);
    h.callables.failures[StaysCallableNames.saveListing] = const StaysCallableException(
      StaysErrorReason.invalidArgument,
      message: 'There is already a listing called "Blue House".',
    );
    await h.pump(tester, StaysSetupWizardScreen(facilityId: h.facilityId));
    await tester.tap(_next());
    await settle(tester);
    await tester.tap(find.byKey(const Key('stays-setup-add-listing')));
    await settle(tester);
    await tester.enterText(find.byKey(const Key('stay-listing-name')), 'Blue House');
    await tester.tap(find.byKey(const Key('stay-listing-kind')));
    await settle(tester);
    await tester.tap(find.text('Cabin').last);
    await settle(tester);
    await tester.tap(find.byKey(const Key('stay-listing-save')));
    await settle(tester);
    expect(find.text('There is already a listing called "Blue House".'), findsOneWidget);
    expect(find.byKey(const Key('stay-listing-save')), findsOneWidget);
  });
}
