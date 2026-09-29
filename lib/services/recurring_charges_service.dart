import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/utils/callable_failure.dart';

/// Monthly rent for a whole facility, posted by the generateMonthlyRentCharges
/// callable (functions-automation).
///
/// The app used to post these charges itself. Its check for an existing
/// charge only recognised an earlier monthly rent charge, not rent a move-in
/// had already charged for the month, so a move-in dated the 1st or an online
/// "Next Month Rent" was billed a second time. The callable decides the same
/// way as the scheduled rent job (planTenantRentCharge in rentChargeReads.ts),
/// so the app, the callable and the job cannot disagree about a month.
class RecurringChargesService {
  /// Posts, or with [dryRun] counts, the month's rent for every active tenant
  /// of [facilityId]. Only the month of [forDate] is used: the server dates
  /// the charges itself. [callable] is for tests.
  ///
  /// Throws [CallableFailureException] when the server refuses or can't be
  /// reached.
  static Future<RecurringChargesResult> generateMonthlyRentCharges({
    required String facilityId,
    required DateTime forDate,
    bool dryRun = false,
    Future<Object?> Function(Map<String, Object?> payload)? callable,
  }) async {
    try {
      final data = await (callable ?? _callGenerateMonthlyRentCharges)(
        monthlyRentChargesPayload(
          facilityId: facilityId,
          forDate: forDate,
          dryRun: dryRun,
        ),
      );
      return RecurringChargesResult.fromCallable(data);
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        debugPrint('❌ [RecurringCharges] generateMonthlyRentCharges: ${e.code} ${e.message}');
      }
      throw callableFailure(
        e,
        permissionDenied: "Only the facility's owner or a manager can post "
            'rent charges. Nothing was charged.',
        notFound: "This facility wasn't found. Nothing was charged.",
        // Re-running is safe: the callable skips a tenant whose month is
        // already charged.
        unreachable: dryRun
            ? "Couldn't reach the server. Nothing was charged; try the "
                'preview again.'
            : "Couldn't reach the server, so some charges may have posted. "
                'Running it again is safe: tenants already charged for the '
                'month are skipped.',
      );
    }
  }

  /// What the callable is sent. The month goes as the 1st of [forDate]'s
  /// month, a local time with no offset, as the Automation Preview screen
  /// sends it: the callable reads the leading year and month as written
  /// (rentChargeMonthFromInput), not as an instant in UTC.
  @visibleForTesting
  static Map<String, Object?> monthlyRentChargesPayload({
    required String facilityId,
    required DateTime forDate,
    required bool dryRun,
  }) {
    return {
      'facilityId': facilityId,
      'forDate': DateTime(forDate.year, forDate.month, 1).toIso8601String(),
      'dryRun': dryRun,
    };
  }

  static Future<Object?> _callGenerateMonthlyRentCharges(
      Map<String, Object?> payload) async {
    final result = await FirebaseFunctions.instance
        .httpsCallable('generateMonthlyRentCharges')
        .call<dynamic>(payload);
    return result.data;
  }
}

/// The callable's reply. [skippedCount] covers tenants already charged for
/// the month (by an earlier run, the scheduled job, or their move-in), tenants
/// with no rate, and tenants left to check by hand. [errors] lists each
/// tenant that needs a look, including those flagged for review, which are
/// counted as skipped rather than in [errorCount].
class RecurringChargesResult {
  final int totalTenants;
  final int successCount;
  final int skippedCount;
  final int errorCount;
  final List<String> errors;

  const RecurringChargesResult({
    required this.totalTenants,
    required this.successCount,
    required this.skippedCount,
    required this.errorCount,
    this.errors = const [],
  });

  factory RecurringChargesResult.fromCallable(Object? data) {
    final map = Map<String, dynamic>.from(data as Map);
    int count(String key) => (map[key] as num?)?.toInt() ?? 0;
    final errors = map['errors'];
    return RecurringChargesResult(
      totalTenants: count('totalTenants'),
      successCount: count('successCount'),
      skippedCount: count('skippedCount'),
      errorCount: count('errorCount'),
      errors: errors is List ? [for (final e in errors) '$e'] : const [],
    );
  }
}
