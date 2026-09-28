import 'package:cloud_functions/cloud_functions.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';
import 'package:sfcapp/models/stays/stays_callable_models.dart';

/// One typed method per Stays callable (spec §6.5). Screens reach it through
/// staysCallablesProvider; tests use test/support/fake_stays_callables.dart.
/// Every failure is a [StaysCallableException] carrying the server's reason.
abstract class StaysCallables {
  Future<StaysAvailability> getAvailability(String facilityId);
  Future<StaysSetControlsResult> setControls(StaysSetControlsRequest request);
  Future<StaysSaveListingResult> saveListing(StaysSaveListingRequest request);
  Future<List<String>> bulkCreateRvSites(StaysBulkCreateRvSitesRequest request);
  Future<StaysQuoteResult> quote(StaysQuoteRequest request);
  Future<StaysCreateStayResult> createStay(StaysCreateStayRequest request);
  Future<StaysStayResult> modifyStay(StaysModifyStayRequest request);
  Future<StaysStayResult> cancelStay(StaysCancelStayRequest request);
  Future<StaysStayResult> reviewStay(StaysReviewStayRequest request);
  Future<StaysRecordPaymentResult> recordPayment(StaysRecordPaymentRequest request);
  Future<StaysVoidIncomeResult> voidIncome({required String facilityId, required String entryId, required String reason});
  Future<List<StayGuestSearchResult>> searchGuests({required String facilityId, required String query});
  Future<StaysUpsertChannelResult> upsertChannel(StaysUpsertChannelRequest request);
  Future<int> removeChannel({required String facilityId, required String channelId});
  Future<List<StaysChannelSyncResult>> syncNow({required String facilityId, String? channelId});
  Future<StaysExportLinkUrl> createExportLink({
    required String facilityId,
    required String listingId,
    required ExportTargetProvider targetProvider,
    required String label,
    ExportScope scope = ExportScope.blocksOnly,
  });
  Future<StaysExportLinkUrl> getExportUrl({required String facilityId, required String linkId});
  Future<void> updateExportLink({required String facilityId, required String linkId, ExportScope? scope, String? label});
  Future<StaysRevokeExportLinkResult> revokeExportLink({required String facilityId, required String linkId, bool rotate = false});
  Future<StaysImportAirbnbCsvResult> importAirbnbCsv(StaysImportAirbnbCsvRequest request);
  Future<StaysRecordExpenseResult> recordExpense(StaysRecordExpenseRequest request);
  Future<void> voidExpense({required String facilityId, required String expenseId, required String reason});
}

/// Maps a callable failure to [StaysCallableException]. Any error without a
/// Stays reason (offline, an old deploy) becomes reason `unknown`.
StaysCallableException staysExceptionFrom(Object error) {
  if (error is StaysCallableException) return error;
  if (error is FirebaseFunctionsException) {
    final details = stayMap(error.details);
    return StaysCallableException(
      StaysErrorReason.fromWire(details['reason']),
      details: details,
      message: error.message,
      code: error.code,
    );
  }
  return StaysCallableException(StaysErrorReason.unknown, message: error.toString());
}

class FirebaseStaysCallables implements StaysCallables {
  FirebaseStaysCallables({FirebaseFunctions? functions}) : _functions = functions;

  final FirebaseFunctions? _functions;

  FirebaseFunctions get _fns => _functions ?? FirebaseFunctions.instance;

  Future<Object?> _call(String name, Map<String, dynamic> data, {Duration timeout = const Duration(seconds: 70)}) async {
    try {
      final result = await _fns.httpsCallable(name, options: HttpsCallableOptions(timeout: timeout)).call<Object?>(data);
      return result.data;
    } catch (error) {
      throw staysExceptionFrom(error);
    }
  }

  Future<Map<String, dynamic>> _callMap(String name, Map<String, dynamic> data, {Duration? timeout}) async =>
      stayMap(timeout == null ? await _call(name, data) : await _call(name, data, timeout: timeout));

  @override
  Future<StaysAvailability> getAvailability(String facilityId) async =>
      StaysAvailability.fromJson(await _callMap(StaysCallableNames.getAvailability, {'facilityId': facilityId}));

  @override
  Future<StaysSetControlsResult> setControls(StaysSetControlsRequest request) async =>
      StaysSetControlsResult.fromJson(
        await _callMap(StaysCallableNames.setControls, request.toJson()),
        facilityId: request.facilityId,
      );

  @override
  Future<StaysSaveListingResult> saveListing(StaysSaveListingRequest request) async =>
      StaysSaveListingResult.fromJson(await _callMap(StaysCallableNames.saveListing, request.toJson()));

  @override
  Future<List<String>> bulkCreateRvSites(StaysBulkCreateRvSitesRequest request) async =>
      stayStrList((await _callMap(StaysCallableNames.bulkCreateRvSites, request.toJson()))['listingIds']);

  @override
  Future<StaysQuoteResult> quote(StaysQuoteRequest request) async =>
      StaysQuoteResult.fromJson(await _callMap(StaysCallableNames.quote, request.toJson()));

  @override
  Future<StaysCreateStayResult> createStay(StaysCreateStayRequest request) async =>
      StaysCreateStayResult.fromJson(await _callMap(StaysCallableNames.createStay, request.toJson()));

  @override
  Future<StaysStayResult> modifyStay(StaysModifyStayRequest request) async => StaysStayResult.fromJson(
        await _callMap(StaysCallableNames.modifyStay, request.toJson()),
        stayId: request.stayId,
      );

  @override
  Future<StaysStayResult> cancelStay(StaysCancelStayRequest request) async => StaysStayResult.fromJson(
        await _callMap(StaysCallableNames.cancelStay, request.toJson()),
        stayId: request.stayId,
      );

  @override
  Future<StaysStayResult> reviewStay(StaysReviewStayRequest request) async => StaysStayResult.fromJson(
        await _callMap(StaysCallableNames.reviewStay, request.toJson()),
        stayId: request.stayId,
      );

  @override
  Future<StaysRecordPaymentResult> recordPayment(StaysRecordPaymentRequest request) async =>
      StaysRecordPaymentResult.fromJson(
        await _callMap(StaysCallableNames.recordPayment, request.toJson()),
        stayId: request.stayId,
      );

  @override
  Future<StaysVoidIncomeResult> voidIncome({required String facilityId, required String entryId, required String reason}) async =>
      StaysVoidIncomeResult.fromJson(await _callMap(StaysCallableNames.voidIncome, {
        'facilityId': facilityId,
        'entryId': entryId,
        'reason': reason,
      }));

  @override
  Future<List<StayGuestSearchResult>> searchGuests({required String facilityId, required String query}) async {
    final data = await _call(StaysCallableNames.searchGuests, {'facilityId': facilityId, 'query': query});
    return stayMapList(data).map(StayGuestSearchResult.fromJson).toList();
  }

  @override
  Future<StaysUpsertChannelResult> upsertChannel(StaysUpsertChannelRequest request) async =>
      StaysUpsertChannelResult.fromJson(await _callMap(StaysCallableNames.upsertChannel, request.toJson()));

  @override
  Future<int> removeChannel({required String facilityId, required String channelId}) async => stayInt(
        (await _callMap(StaysCallableNames.removeChannel, {'facilityId': facilityId, 'channelId': channelId}))['detachedStays'],
      );

  @override
  Future<List<StaysChannelSyncResult>> syncNow({required String facilityId, String? channelId}) async {
    final data = await _callMap(StaysCallableNames.syncNow, {
      'facilityId': facilityId,
      if (channelId != null) 'channelId': channelId,
    });
    return stayMapList(data['results']).map(StaysChannelSyncResult.fromJson).toList();
  }

  @override
  Future<StaysExportLinkUrl> createExportLink({
    required String facilityId,
    required String listingId,
    required ExportTargetProvider targetProvider,
    required String label,
    ExportScope scope = ExportScope.blocksOnly,
  }) async =>
      StaysExportLinkUrl.fromJson(await _callMap(StaysCallableNames.createExportLink, {
        'facilityId': facilityId,
        'listingId': listingId,
        'targetProvider': targetProvider.wire,
        'label': label,
        'scope': scope.wire,
      }));

  @override
  Future<StaysExportLinkUrl> getExportUrl({required String facilityId, required String linkId}) async =>
      StaysExportLinkUrl.fromJson(
        await _callMap(StaysCallableNames.getExportUrl, {'facilityId': facilityId, 'linkId': linkId}),
        linkId: linkId,
      );

  @override
  Future<void> updateExportLink({required String facilityId, required String linkId, ExportScope? scope, String? label}) async {
    await _call(StaysCallableNames.updateExportLink, {
      'facilityId': facilityId,
      'linkId': linkId,
      if (scope != null) 'scope': scope.wire,
      if (label != null) 'label': label,
    });
  }

  @override
  Future<StaysRevokeExportLinkResult> revokeExportLink({required String facilityId, required String linkId, bool rotate = false}) async =>
      StaysRevokeExportLinkResult.fromJson(await _callMap(StaysCallableNames.revokeExportLink, {
        'facilityId': facilityId,
        'linkId': linkId,
        'rotate': rotate,
      }));

  @override
  Future<StaysImportAirbnbCsvResult> importAirbnbCsv(StaysImportAirbnbCsvRequest request) async =>
      StaysImportAirbnbCsvResult.fromJson(await _callMap(
        StaysCallableNames.importAirbnbCsv,
        request.toJson(),
        timeout: const Duration(seconds: 310),
      ));

  @override
  Future<StaysRecordExpenseResult> recordExpense(StaysRecordExpenseRequest request) async =>
      StaysRecordExpenseResult.fromJson(await _callMap(StaysCallableNames.recordExpense, request.toJson()));

  @override
  Future<void> voidExpense({required String facilityId, required String expenseId, required String reason}) async {
    await _call(StaysCallableNames.voidExpense, {'facilityId': facilityId, 'expenseId': expenseId, 'reason': reason});
  }
}
