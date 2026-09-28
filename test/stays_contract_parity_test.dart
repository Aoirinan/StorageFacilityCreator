import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/facility_notification_model.dart';
import 'package:sfcapp/models/stays/stay_controls.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_listing.dart';
import 'package:sfcapp/models/stays/stays_callable_models.dart';
import 'package:sfcapp/services/stays/stays_collections.dart';
import 'package:sfcapp/services/stays/stays_repository.dart';

// The app and the Stays functions share one contract: callable names, error
// reasons, notification types, enum wire values and collection names. The
// TypeScript side (functions-shared/src/stays/contracts.ts) is the source;
// this test reads it and fails when the Dart mirror drifts from it.

final String _contracts = File('functions-shared/src/stays/contracts.ts').readAsStringSync();

/// The quoted strings of `export const NAME = [ ... ]` or `export const NAME: T = [ ... ]`.
List<String> _tsArray(String name) {
  final m = RegExp('export const $name(?::[^=]+)?\\s*=\\s*\\[([\\s\\S]*?)\\]', multiLine: true).firstMatch(_contracts);
  if (m == null) throw StateError('contracts.ts has no array $name');
  return RegExp(r"'([^']*)'").allMatches(m.group(1)!).map((x) => x.group(1)!).toList();
}

/// The string values of `export const NAME = { key: 'value', ... }`.
Map<String, String> _tsObject(String name) {
  final m = RegExp('export const $name\\s*=\\s*\\{([\\s\\S]*?)\\}', multiLine: true).firstMatch(_contracts);
  if (m == null) throw StateError('contracts.ts has no object $name');
  return {
    for (final x in RegExp(r"(\w+)\s*:\s*'([^']*)'").allMatches(m.group(1)!)) x.group(1)!: x.group(2)!,
  };
}

List<String> _wires(List<WireEnum> values) => [
      for (final v in values)
        if (v.wire != 'unknown') v.wire,
    ];

void main() {
  test('callable names match STAYS_CALLABLES, in order', () {
    expect(StaysCallableNames.all, _tsObject('STAYS_CALLABLES').values.toList());
    expect(StaysCallableNames.all.toSet().length, StaysCallableNames.all.length);
  });

  test('error reasons match STAYS_ERROR_REASONS', () {
    expect(_wires(StaysErrorReason.values), _tsArray('STAYS_ERROR_REASONS'));
  });

  test('notification types match STAY_NOTIFICATION_TYPES, and the notification model knows each', () {
    final ts = _tsArray('STAY_NOTIFICATION_TYPES');
    expect(StayNotificationTypes.all, ts);
    for (final type in ts) {
      final parsed = FacilityNotificationTypeX.fromString(type);
      expect(parsed, isNot(FacilityNotificationType.other), reason: type);
      expect(parsed.value, type);
      expect(parsed.isStay, isTrue);
    }
  });

  test('every enum has the same wire values on both sides', () {
    final pairs = <String, List<WireEnum>>{
      'STAY_LISTING_KINDS': StayListingKind.values,
      'RV_HOOKUPS': RvHookup.values,
      'STAY_KINDS': StayKind.values,
      'STAY_SOURCES': StaySource.values,
      'STAY_ORIGINS': StayOrigin.values,
      'STAY_STATUSES': StayStatus.values,
      'STAY_ARRIVAL_STATES': StayArrivalState.values,
      'STAY_PAYMENT_STATUSES': StayPaymentStatus.values,
      'CHANNEL_PROVIDERS': ChannelProvider.values,
      'CHANNEL_SYNC_STATUSES': ChannelSyncStatus.values,
      'EXPORT_TARGET_PROVIDERS': ExportTargetProvider.values,
      'EXPORT_SCOPES': ExportScope.values,
      'TASK_CATEGORIES': StayTaskCategory.values,
      'TASK_STATUSES': StayTaskStatus.values,
      'TASK_PRIORITIES': StayTaskPriority.values,
      'TURNOVER_MODES': TurnoverMode.values,
      'ACCESS_CODE_MODES': AccessCodeMode.values,
      'STAY_ACCESS_SOURCES': StayAccessSource.values,
      'INCOME_SOURCES': StayIncomeSource.values,
      'INCOME_METHODS': StayIncomeMethod.values,
      'INCOME_KINDS': StayIncomeKind.values,
      'EXPENSE_CATEGORIES': StayExpenseCategory.values,
      'MONEY_ENTRY_STATUSES': StayMoneyEntryStatus.values,
      'IMPORT_BATCH_KINDS': StayImportBatchKind.values,
      'IMPORT_BATCH_STATUSES': StayImportBatchStatus.values,
      'TEMPLATE_CHANNEL_HINTS': TemplateChannelHint.values,
      'FOLIO_LINE_CODES': FolioLineCode.values,
      'CONSENT_METHODS': ConsentMethod.values,
      'SYNC_TRIGGERS': SyncTrigger.values,
      'REVIEW_ACTIONS': StayReviewAction.values,
    };
    for (final entry in pairs.entries) {
      expect(_wires(entry.value), _tsArray(entry.key), reason: entry.key);
      // Unknown strings must have somewhere safe to land.
      expect(entry.value.any((v) => v.wire == 'unknown'), isTrue, reason: '${entry.key} has no unknown');
    }
  });

  test('the default payment methods match DEFAULT_PAYMENT_METHODS', () {
    expect(StayControls.defaultPaymentMethods.map((m) => m.wire).toList(), _tsArray('DEFAULT_PAYMENT_METHODS'));
  });

  test('the value sets beside the enums match too', () {
    expect(StayIncomeMethod.manual.map((m) => m.wire).toList(), _tsArray('MANUAL_PAYMENT_METHODS'));
    expect(StaySource.values.where((s) => s.isSfcBooking).map((s) => s.wire).toList(), _tsArray('SFC_BOOKING_SOURCES'));
    expect(StaySource.values.where((s) => s.isChannel).map((s) => s.wire).toList(), _tsArray('OTA_SOURCES'));
    expect(StayTaxLine.appliesToValues, _tsArray('TAX_APPLIES_TO'));
    expect(StayRoles.all, _tsArray('STAY_ROLES'));
    expect(StaysWarningCodes.all, _tsArray('STAYS_WARNING_CODES'));
    // Every key the app quick-edits is one the writer treats as staff-owned.
    expect(_tsArray('STAY_STAFF_FIELDS'), containsAll(stayQuickEditKeys));
  });

  test('collection names match STAY_COLLECTIONS', () {
    final ts = _tsObject('STAY_COLLECTIONS')..remove('notifications');
    expect(
      {
        'controls': StaysCollections.controls,
        'listings': StaysCollections.listings,
        'listingAccess': StaysCollections.listingAccess,
        'channels': StaysCollections.channels,
        'channelBlocks': StaysCollections.channelBlocks,
        'exportLinks': StaysCollections.exportLinks,
        'syncLog': StaysCollections.syncLog,
        'stays': StaysCollections.stays,
        'private': StaysCollections.private,
        'access': StaysCollections.access,
        'folios': StaysCollections.folios,
        'nightLocks': StaysCollections.nightLocks,
        'tasks': StaysCollections.tasks,
        'income': StaysCollections.income,
        'expenses': StaysCollections.expenses,
        'importBatches': StaysCollections.importBatches,
        'guestProfiles': StaysCollections.guestProfiles,
        'messageTemplates': StaysCollections.messageTemplates,
      },
      ts,
    );
    expect(StaysCollections.currentDocId, RegExp("STAYS_CURRENT_DOC_ID = '([^']+)'").firstMatch(_contracts)!.group(1));
  });

  test('the parser itself finds what it looks for', () {
    // Guards against a contracts.ts reformat silently emptying the lists above.
    expect(_tsArray('STAY_KINDS'), ['reservation', 'owner_block', 'maintenance_block']);
    expect(_tsObject('STAYS_CALLABLES')['createStay'], 'staysCreateStay');
    expect(_tsArray('STAYS_ERROR_REASONS'), contains('hard_conflict'));
  });
}
