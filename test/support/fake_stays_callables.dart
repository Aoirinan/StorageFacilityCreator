import 'dart:async';

import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stays_callable_models.dart';
import 'package:sfcapp/services/stays/stays_callables.dart';

/// One call a test made through [FakeStaysCallables].
class FakeStaysCall {
  const FakeStaysCall(this.name, this.request);

  /// The callable's name, e.g. StaysCallableNames.createStay.
  final String name;

  /// The request object, or a map for the callables that take named arguments.
  final Object? request;
}

/// StaysCallables for widget tests: records every call, answers with
/// configurable results, and can fail ([failures]) or hold ([gates]) a
/// callable so a test can tap twice while the first call is in flight.
class FakeStaysCallables implements StaysCallables {
  final List<FakeStaysCall> calls = [];

  /// Callable name → error to throw (usually a StaysCallableException).
  final Map<String, Object> failures = {};

  /// Callable name → completer the call waits on before answering.
  final Map<String, Completer<void>> gates = {};

  StaysAvailability availability = const StaysAvailability(allowed: true, paused: false);
  StaysQuoteResult Function(StaysQuoteRequest request)? onQuote;
  StaysCreateStayResult Function(StaysCreateStayRequest request)? onCreateStay;
  StaysStayResult Function(StaysModifyStayRequest request)? onModifyStay;
  StaysRecordPaymentResult Function(StaysRecordPaymentRequest request)? onRecordPayment;
  StaysSetControlsResult Function(StaysSetControlsRequest request)? onSetControls;
  StaysSaveListingResult Function(StaysSaveListingRequest request)? onSaveListing;
  StaysUpsertChannelResult Function(StaysUpsertChannelRequest request)? onUpsertChannel;
  StaysImportAirbnbCsvResult Function(StaysImportAirbnbCsvRequest request)? onImportAirbnbCsv;
  List<StayGuestSearchResult> guestResults = const [];

  int countOf(String name) => calls.where((c) => c.name == name).length;

  List<T> requestsOf<T>(String name) => calls.where((c) => c.name == name).map((c) => c.request).whereType<T>().toList();

  Future<T> _answer<T>(String name, Object? request, T Function() result) async {
    calls.add(FakeStaysCall(name, request));
    final gate = gates[name];
    if (gate != null) await gate.future;
    final failure = failures[name];
    if (failure != null) throw failure;
    return result();
  }

  static Stay _stayFor(String stayId, {int version = 1}) =>
      Stay(id: stayId, facilityId: '', listingId: '', checkIn: '', checkOut: '', version: version);

  @override
  Future<StaysAvailability> getAvailability(String facilityId) =>
      _answer(StaysCallableNames.getAvailability, {'facilityId': facilityId}, () => availability);

  @override
  Future<StaysSetControlsResult> setControls(StaysSetControlsRequest request) => _answer(
        StaysCallableNames.setControls,
        request,
        () => onSetControls?.call(request) ??
            StaysSetControlsResult.fromJson({'controls': request.changes.toJson()}, facilityId: request.facilityId),
      );

  @override
  Future<StaysSaveListingResult> saveListing(StaysSaveListingRequest request) => _answer(
        StaysCallableNames.saveListing,
        request,
        () =>
            onSaveListing?.call(request) ??
            StaysSaveListingResult(listingId: request.listingId ?? 'lst_${request.requestId}', version: 1),
      );

  @override
  Future<List<String>> bulkCreateRvSites(StaysBulkCreateRvSitesRequest request) => _answer(
        StaysCallableNames.bulkCreateRvSites,
        request,
        () => [for (var n = request.from; n <= request.to; n++) 'lst_${request.requestId}_$n'],
      );

  @override
  Future<StaysQuoteResult> quote(StaysQuoteRequest request) => _answer(
        StaysCallableNames.quote,
        request,
        () => onQuote?.call(request) ?? const StaysQuoteResult(available: true),
      );

  @override
  Future<StaysCreateStayResult> createStay(StaysCreateStayRequest request) => _answer(
        StaysCallableNames.createStay,
        request,
        () =>
            onCreateStay?.call(request) ??
            StaysCreateStayResult(stayId: 'man_${request.requestId}', created: true, status: StayStatus.confirmed),
      );

  @override
  Future<StaysStayResult> modifyStay(StaysModifyStayRequest request) => _answer(
        StaysCallableNames.modifyStay,
        request,
        () => onModifyStay?.call(request) ?? StaysStayResult(stay: _stayFor(request.stayId, version: request.expectedVersion + 1)),
      );

  @override
  Future<StaysStayResult> cancelStay(StaysCancelStayRequest request) => _answer(
        StaysCallableNames.cancelStay,
        request,
        () => StaysStayResult(stay: _stayFor(request.stayId, version: request.expectedVersion + 1)),
      );

  @override
  Future<StaysStayResult> reviewStay(StaysReviewStayRequest request) =>
      _answer(StaysCallableNames.reviewStay, request, () => StaysStayResult(stay: _stayFor(request.stayId)));

  @override
  Future<StaysRecordPaymentResult> recordPayment(StaysRecordPaymentRequest request) => _answer(
        StaysCallableNames.recordPayment,
        request,
        () =>
            onRecordPayment?.call(request) ??
            StaysRecordPaymentResult(entryId: 'man_${request.requestId}', created: true, paymentStatus: StayPaymentStatus.paid),
      );

  @override
  Future<StaysVoidIncomeResult> voidIncome({required String facilityId, required String entryId, required String reason}) =>
      _answer(
        StaysCallableNames.voidIncome,
        {'facilityId': facilityId, 'entryId': entryId, 'reason': reason},
        () => StaysVoidIncomeResult(entryId: entryId),
      );

  @override
  Future<List<StayGuestSearchResult>> searchGuests({required String facilityId, required String query}) =>
      _answer(StaysCallableNames.searchGuests, {'facilityId': facilityId, 'query': query}, () => guestResults);

  @override
  Future<StaysUpsertChannelResult> upsertChannel(StaysUpsertChannelRequest request) => _answer(
        StaysCallableNames.upsertChannel,
        request,
        () =>
            onUpsertChannel?.call(request) ??
            (request.dryRun
                ? const StaysChannelPreview(status: ChannelSyncStatus.ok)
                : const StaysChannelSaved(
                    channelId: 'ch_test',
                    urlHost: 'www.airbnb.com',
                    urlFingerprint: 'abcdef123456',
                    firstSync: StaysChannelSyncResult(channelId: 'ch_test', status: ChannelSyncStatus.ok),
                  )),
      );

  @override
  Future<int> removeChannel({required String facilityId, required String channelId}) =>
      _answer(StaysCallableNames.removeChannel, {'facilityId': facilityId, 'channelId': channelId}, () => 0);

  @override
  Future<List<StaysChannelSyncResult>> syncNow({required String facilityId, String? channelId}) => _answer(
        StaysCallableNames.syncNow,
        {'facilityId': facilityId, 'channelId': channelId},
        () => [StaysChannelSyncResult(channelId: channelId ?? 'ch_test', status: ChannelSyncStatus.ok)],
      );

  @override
  Future<StaysExportLinkUrl> createExportLink({
    required String facilityId,
    required String listingId,
    required ExportTargetProvider targetProvider,
    required String label,
    ExportScope scope = ExportScope.blocksOnly,
    String? requestId,
  }) =>
      _answer(
        StaysCallableNames.createExportLink,
        {
          'facilityId': facilityId,
          'listingId': listingId,
          'targetProvider': targetProvider.wire,
          'label': label,
          'scope': scope.wire,
          'requestId': requestId,
        },
        () => StaysExportLinkUrl(
          linkId: requestId == null ? 'xl_test' : 'xl_$requestId',
          url: 'https://app.example/api/ical/${'0' * 48}.ics',
        ),
      );

  @override
  Future<StaysExportLinkUrl> getExportUrl({required String facilityId, required String linkId}) => _answer(
        StaysCallableNames.getExportUrl,
        {'facilityId': facilityId, 'linkId': linkId},
        () => StaysExportLinkUrl(linkId: linkId, url: 'https://app.example/api/ical/${'0' * 48}.ics'),
      );

  @override
  Future<void> updateExportLink({required String facilityId, required String linkId, ExportScope? scope, String? label}) =>
      _answer(
        StaysCallableNames.updateExportLink,
        {'facilityId': facilityId, 'linkId': linkId, 'scope': scope?.wire, 'label': label},
        () {},
      );

  @override
  Future<StaysRevokeExportLinkResult> revokeExportLink({required String facilityId, required String linkId, bool rotate = false}) =>
      _answer(
        StaysCallableNames.revokeExportLink,
        {'facilityId': facilityId, 'linkId': linkId, 'rotate': rotate},
        () => StaysRevokeExportLinkResult(
          linkId: linkId,
          rotated: rotate ? StaysExportLinkUrl(linkId: 'xl_rotated', url: 'https://app.example/api/ical/${'1' * 48}.ics') : null,
        ),
      );

  @override
  Future<StaysImportAirbnbCsvResult> importAirbnbCsv(StaysImportAirbnbCsvRequest request) => _answer(
        StaysCallableNames.importAirbnbCsv,
        request,
        () => onImportAirbnbCsv?.call(request) ?? StaysImportAirbnbCsvResult(batchId: 'batch_test', dryRun: request.dryRun),
      );

  @override
  Future<StaysRecordExpenseResult> recordExpense(StaysRecordExpenseRequest request) => _answer(
        StaysCallableNames.recordExpense,
        request,
        () => StaysRecordExpenseResult(expenseId: 'exp_${request.requestId}', created: true),
      );

  @override
  Future<void> voidExpense({required String facilityId, required String expenseId, required String reason}) => _answer(
        StaysCallableNames.voidExpense,
        {'facilityId': facilityId, 'expenseId': expenseId, 'reason': reason},
        () {},
      );
}
