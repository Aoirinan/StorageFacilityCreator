import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/contract_model.dart';
import 'package:sfcapp/models/invoice_line_item_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/ledger_service.dart';
import 'package:sfcapp/services/move_out_card_refund.dart';
import 'package:sfcapp/services/move_out_rent.dart';
import 'package:sfcapp/services/tenant_service.dart';

/// Service for managing move-out workflow
class MoveOutService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// The tenant's ledger entries the move-out rent line reads
  /// ([MoveOutRent.coverage]): their monthly rent charges, and the entries
  /// posted for [contractId], among them its move-in rent. processMoveOut
  /// reads all of their posted entries and keeps the same ones. Equality
  /// filters only, so no composite index is needed.
  static Future<List<Map<String, dynamic>>> _rentRows({
    required String facilityId,
    required String tenantId,
    required String contractId,
  }) async {
    final posted = _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('ledgers')
        .where('tenantId', isEqualTo: tenantId)
        .where('status', isEqualTo: 'posted');
    final reads = await Future.wait([
      posted.where('metadata.chargeType', isEqualTo: 'monthlyRent').get(),
      posted.where('referenceId', isEqualTo: contractId).get(),
    ]);
    final byId = <String, Map<String, dynamic>>{};
    for (final snapshot in reads) {
      for (final doc in snapshot.docs) {
        byId[doc.id] = doc.data();
      }
    }
    return byId.values.toList();
  }

  /// The move-out's lines, net and refund, from the rent line ([rent], null
  /// when not prorating) and the fees, on top of [currentBalance].
  ///
  /// The rent line is a charge for used days no rent covers and a credit
  /// for unused days rent already covers ([MoveOutRent]). The credit is
  /// negative and counts toward the refund, which is whatever the tenant is
  /// owed once every line is in: it is paid out only if the owner ticks
  /// Process Refund, and stays on the ledger as their credit otherwise.
  /// processMoveOut posts the same lines (moveOutLedgerRows).
  @visibleForTesting
  static MoveOutCalculation buildCalculation({
    required double currentBalance,
    required DateTime moveOutDate,
    MoveOutRentLine? rent,
    double? cleaningFee,
    double? damageFee,
    double? otherFees,
  }) {
    final lineItems = <InvoiceLineItem>[];
    final stamp = DateTime.now().millisecondsSinceEpoch;
    var rentNet = 0.0;
    if (rent != null && rent.chargeAmount > 0) {
      lineItems.add(InvoiceLineItem(
        id: 'prorated_rent_$stamp',
        type: InvoiceLineItemType.proratedRent,
        description: 'Prorated Rent (${rent.chargeDays} days)',
        amount: rent.chargeAmount,
        isProrated: true,
        dueDate: moveOutDate,
      ));
      rentNet += rent.chargeAmount;
    }
    if (rent != null && rent.creditAmount > 0) {
      lineItems.add(InvoiceLineItem(
        id: 'prorated_rent_credit_$stamp',
        type: InvoiceLineItemType.proratedRent,
        description: 'Prorated Rent Credit (${rent.creditDays} unused days)',
        amount: -rent.creditAmount,
        isProrated: true,
        dueDate: moveOutDate,
      ));
      rentNet -= rent.creditAmount;
    }

    var fees = 0.0;
    for (final (id, description, amount) in [
      ('cleaning_fee', 'Cleaning Fee', cleaningFee),
      ('damage_fee', 'Damage Fee', damageFee),
      ('other_fees', 'Other Fees', otherFees),
    ]) {
      if (amount == null || !amount.isFinite || amount <= 0) continue;
      lineItems.add(InvoiceLineItem(
        id: '${id}_$stamp',
        type: InvoiceLineItemType.otherFee,
        description: description,
        amount: amount,
        isProrated: false,
        dueDate: moveOutDate,
      ));
      fees += amount;
    }

    final newCharges = MoveOutRent.cents(rentNet + fees);
    final finalBalance = MoveOutRent.cents(currentBalance + newCharges);
    return MoveOutCalculation(
      lineItems: lineItems,
      currentBalance: currentBalance,
      newCharges: newCharges,
      finalBalance: finalBalance,
      refundAmount: finalBalance < 0 ? -finalBalance : 0.0,
      prorateRent: rent != null,
      fees: MoveOutRent.cents(fees),
    );
  }

  /// The monthly rate a move-out prorates: the tenant's own while the unit
  /// is the only one they hold, only the vacated unit's ([unitRate]) when
  /// they keep others. Their rate covers every unit they hold, so prorating
  /// all of it for one of two credited (or charged) the days of the unit
  /// they keep as well.
  static double prorationRate({
    required double tenantRate,
    required double? unitRate,
    required bool keepsOtherUnits,
  }) =>
      keepsOtherUnits && unitRate != null ? unitRate : tenantRate;

  /// Whether [tenantId] keeps a unit besides [vacated] among [units] (the
  /// screen's choices, from the Units list's read, archived units left
  /// out): one linked to them exactly, as processMoveOut's query matches
  /// the link, that [UnitModel] reads as not available (a unit with no
  /// status, or one that is not a [UnitStatus] name, reads as available).
  /// It decides the rate prorated ([prorationRate]).
  ///
  /// processMoveOut decides it again (isHeld in
  /// functions-tenant-lifecycle/src/moveOutTenantFields.ts) and refuses a
  /// net that is not the one shown here. It counted a linked unit with no
  /// status as kept, so every such move-out was refused. Both test suites
  /// run its src/test/fixtures/moveOutKeepsOtherUnits.json.
  static bool keepsOtherUnits({
    required String? tenantId,
    required UnitModel? vacated,
    required List<UnitModel> units,
  }) =>
      vacated != null &&
      tenantId != null &&
      units.any((u) =>
          u.id != vacated.id &&
          u.tenantId == tenantId &&
          u.status != UnitStatus.available);

  /// The unit an app contract was signed for, or null: online move-ins
  /// record it in customFields.onlineMoveInContext; contracts made in the
  /// app record none. processMoveOut refuses to end a contract signed for
  /// another unit the tenant still holds.
  static String? contractUnitId(ContractModel contract) {
    final context = contract.customFields?['onlineMoveInContext'];
    final id = context is Map ? context['unitId'] : null;
    return id is String && id.trim().isNotEmpty ? id.trim() : null;
  }

  /// The units a move-out of [tenantId] can free, and the one picked first.
  ///
  /// The units they hold (linked to them and not available), for the owner
  /// to pick from. The screen took the unit numbered as their unitNumber, or
  /// else the facility's first unit, and app contracts record no unit, so
  /// moving a two-unit tenant out through the second unit's contract freed
  /// their primary unit. Picked first: the unit the owner started from
  /// ([preferredUnitId], the unit's own Move out), the unit the contract was
  /// signed for ([contractUnitId]), their primary unit ([tenantUnitId], the
  /// tenant's `unitId`), then the one unit their unitNumber names, then the
  /// only choice. Null (the owner picks) when that leaves it open: where a
  /// facility repeats unit numbers across areas, a tenant can hold unit 12
  /// in two areas, and their number names neither. Holding none, a unit
  /// still linked to them or numbered as theirs, so the contract can still
  /// be ended; never another tenant's unit.
  static ({List<UnitModel> choices, UnitModel? initial}) moveOutUnitChoices({
    required String tenantId,
    required String tenantUnitNumber,
    required List<UnitModel> units,
    String? tenantUnitId,
    String? contractUnitId,
    String? preferredUnitId,
  }) {
    final number = tenantUnitNumber.trim();
    bool linked(UnitModel u) => (u.tenantId ?? '').trim() == tenantId;
    var choices = [
      for (final u in units)
        if (linked(u) && u.status != UnitStatus.available) u
    ];
    if (choices.isEmpty) {
      choices = [
        for (final u in units)
          if (linked(u) ||
              (number.isNotEmpty &&
                  u.unitNumber.trim() == number &&
                  (u.tenantId ?? '').trim().isEmpty))
            u
      ];
    }
    UnitModel? find(bool Function(UnitModel u) test) {
      for (final u in choices) {
        if (test(u)) return u;
      }
      return null;
    }

    final primary = tenantUnitId?.trim() ?? '';
    final numbered = [
      for (final u in choices)
        if (number.isNotEmpty && u.unitNumber.trim() == number) u
    ];
    final initial = find((u) => u.id == preferredUnitId) ??
        find((u) => u.id == contractUnitId) ??
        find((u) => primary.isNotEmpty && u.id == primary) ??
        (numbered.length == 1 ? numbered.single : null) ??
        (choices.length == 1 ? choices.single : null);
    return (choices: choices, initial: initial);
  }

  /// Calculate move-out charges and refunds. [unitRate] is the vacated
  /// unit's rate and [keepsOtherUnits] whether the tenant holds another
  /// unit: see [prorationRate]. [unitMoveInDate] is the vacated unit's
  /// moveInDate, the tenancy's start when its move-in rent does not say.
  static Future<MoveOutCalculation> calculateMoveOutCharges({
    required String tenantId,
    required String facilityId,
    required String contractId,
    required DateTime moveOutDate,
    double? cleaningFee,
    double? damageFee,
    double? otherFees,
    bool prorateRent = true,
    double? unitRate,
    bool keepsOtherUnits = false,
    DateTime? unitMoveInDate,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 [MoveOut] Calculating move-out charges for tenant: $tenantId');
      }

      // Get current ledger balance
      final currentBalance = await LedgerService.getLedgerBalance(
        tenantId: tenantId,
        facilityId: facilityId,
      );

      // Get tenant to find monthly rate
      final tenantModel = await TenantService.getTenantById(facilityId, tenantId);
      if (tenantModel == null) {
        throw Exception('Tenant not found');
      }

      // 1. Rent: charged for used days no rent covers, credited for days
      // after the move-out that rent already posted covers (MoveOutRent).
      // It counted days 1 to the move-out date as used whatever the
      // tenancy, and charged them unless the scheduled job had posted the
      // month: a tenancy starting 1 Oct, moved out on 24 Sep, was charged
      // for 24 September days, and a mid-month move-in for days its
      // move-in rent had billed. processMoveOut works this line out again
      // and refuses to post one that differs.
      final rate = prorationRate(
        tenantRate: tenantModel.monthlyRate,
        unitRate: unitRate,
        keepsOtherUnits: keepsOtherUnits,
      );
      MoveOutRentLine? rent;
      if (prorateRent) {
        rent = MoveOutRent.line(
          monthlyRate: rate,
          moveOutDay: MoveOutRent.wallDay(moveOutDate),
          contractId: contractId,
          rows: await _rentRows(
            facilityId: facilityId,
            tenantId: tenantId,
            contractId: contractId,
          ),
          unitMoveInDate: unitMoveInDate,
        );
      }

      // 2 to 4. Cleaning, damage and other fees.
      final calculation = buildCalculation(
        currentBalance: currentBalance,
        moveOutDate: moveOutDate,
        rent: rent,
        cleaningFee: cleaningFee,
        damageFee: damageFee,
        otherFees: otherFees,
      );

      if (kDebugMode) {
        print('💰 [MoveOut] Current Balance: \$${currentBalance.toStringAsFixed(2)}');
        print('💰 [MoveOut] New Charges: \$${calculation.newCharges.toStringAsFixed(2)}');
        print('💰 [MoveOut] Final Balance: \$${calculation.finalBalance.toStringAsFixed(2)}');
        print('💰 [MoveOut] Refund Amount: \$${calculation.refundAmount.toStringAsFixed(2)}');
      }

      return calculation;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [MoveOut] Error calculating charges: $e');
      }
      rethrow;
    }
  }

  /// Completes the move-out through processMoveOut, which posts the lines,
  /// ends the contract, frees the unit and settles the tenant in one
  /// transaction, then makes a card refund, if one was asked for, through
  /// processRefund ([MoveOutCardRefund]).
  ///
  /// There was a second path here (`useCloudFunction: false`, which nothing
  /// passed) that wrote the same records from the app, one by one. For a
  /// card refund it posted the refund as made and then called processRefund
  /// with the typed reference number: a PaymentIntent id there refunded the
  /// card and posted the refund a second time, and anything else refunded
  /// nothing. It is gone.
  static Future<MoveOutResult> completeMoveOut({
    required String tenantId,
    required String facilityId,
    required String contractId,
    required String unitId,
    required DateTime moveOutDate,
    required MoveOutCalculation calculation,
    String? moveOutNotes,
    bool processRefund = false,
    String? refundMethod, // 'cash', 'check', 'creditCard', 'ach'
    String? refundReferenceId,
  }) async {
    final user = _auth.currentUser;
    if (user == null) {
      return MoveOutResult(success: false, error: 'User not authenticated');
    }
    if (kDebugMode) {
      print('🔄 [MoveOut] Starting move-out process for tenant: $tenantId');
    }
    return _completeMoveOutViaCloudFunction(
      tenantId: tenantId,
      facilityId: facilityId,
      contractId: contractId,
      unitId: unitId,
      moveOutDate: moveOutDate,
      calculation: calculation,
      moveOutNotes: moveOutNotes,
      processRefund: processRefund,
      refundMethod: refundMethod,
      refundReferenceId: refundReferenceId,
    );
  }

  /// The app's own tenant step of a move-out: [TenantService.recordMoveOut],
  /// which switches the tenant (and their gate codes) off only when they
  /// hold no other unit. processMoveOut does this step on the server
  /// (tenantFieldsAfterMoveOut); this is kept, with its tests, as the app's
  /// statement of the same rule, since the app path that called it is gone. Returns what the owner is shown with the finished
  /// move-out: the tenant's new rent or a request to check it, or a warning
  /// instead of throwing, since it runs after fees and refunds are posted.
  /// The old step set every tenant inactive and turned every gate code off,
  /// even for one still renting another unit, and its failure read as
  /// "Error completing move-out". [records], [effects] and [actingUid] are
  /// for tests.
  @visibleForTesting
  static Future<String?> settleTenantAfterMoveOut({
    required String facilityId,
    required String tenantId,
    required String unitId,
    TenantRecordsStore? records,
    TenantUpdateEffects? effects,
    String? actingUid,
  }) async {
    try {
      return await TenantService.recordMoveOut(
        facilityId: facilityId,
        tenantId: tenantId,
        movedOutUnitId: unitId,
        records: records,
        effects: effects,
        actingUid: actingUid,
      );
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [MoveOut] Tenant record not updated after move-out: $e');
      }
      return 'The move-out, charges and refund are recorded, but the '
          "tenant's own record was not updated ($e). Open the tenant to "
          'check whether they should still be active and have gate access.';
    }
  }

  /// Complete move-out via Cloud Function (transaction-safe)
  static Future<MoveOutResult> _completeMoveOutViaCloudFunction({
    required String tenantId,
    required String facilityId,
    required String contractId,
    required String unitId,
    required DateTime moveOutDate,
    required MoveOutCalculation calculation,
    String? moveOutNotes,
    bool processRefund = false,
    String? refundMethod,
    String? refundReferenceId,
  }) async {
    try {
      final functions = FirebaseFunctions.instance;
      final callable = functions.httpsCallable('processMoveOut');

      if (kDebugMode) {
        print('🔄 [MoveOut] Calling processMoveOut Cloud Function...');
      }

      final result = await callable.call(<String, dynamic>{
        'facilityId': facilityId,
        'tenantId': tenantId,
        'contractId': contractId,
        'unitId': unitId,
        'moveOutDate': moveOutDay(moveOutDate),
        // The net of the lines (fees plus prorated rent, a credit when the
        // month was already billed) and the credit left after them. The
        // server posts the refund only when processRefund is true.
        'moveOutCharges': calculation.newCharges,
        'moveOutRefund': calculation.refundAmount,
        // processMoveOut works the rent line out again from these, posts it
        // and the fees as their own lines, and refuses when its net differs
        // from moveOutCharges (what the owner was shown).
        'prorateRent': calculation.prorateRent,
        'moveOutFees': calculation.fees,
        'moveOutNotes': moveOutNotes,
        'processRefund': processRefund && calculation.refundAmount > 0,
        'refundMethod': refundMethod,
        'refundReferenceId': refundReferenceId,
      });

      final data = Map<String, dynamic>.from(result.data as Map);

      if (kDebugMode) {
        print('✅ [MoveOut] Cloud Function completed successfully');
      }

      return afterProcessMoveOut(
        data,
        calculation,
        facilityId: facilityId,
        tenantId: tenantId,
        contractId: contractId,
      );
    } on FirebaseFunctionsException catch (e) {
      if (kDebugMode) {
        print('❌ [MoveOut] Cloud Function error: ${e.code} - ${e.message}');
      }
      return MoveOutResult(
        success: false,
        error: 'Cloud Function Error: ${e.message}',
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ [MoveOut] Error calling Cloud Function: $e');
      }
      return MoveOutResult(
        success: false,
        error: 'Failed to process move-out: $e',
      );
    }
  }

  /// What processMoveOut answered ([data]), with the card refund it left to
  /// the screen made. processMoveOut does not make one: it answers with the
  /// amount, refunded here through processRefund. Never on a retry of a
  /// finished move-out (the server answers 0 then): one the first press
  /// left pending is the screen's to ask the owner about
  /// (MoveOutResult.pendingCardRefund). The refund is checked against the
  /// commit ([cardRefundSince]): a second session can press Complete while
  /// this answer is on its way, be offered the pending refund and make it,
  /// and this press then planned its own from what that left, on another
  /// payment or at another amount, which Stripe refunded again.
  /// [readLedger] and [call] are for tests.
  @visibleForTesting
  static Future<MoveOutResult> afterProcessMoveOut(
    Map<String, dynamic> data,
    MoveOutCalculation calculation, {
    required String facilityId,
    required String tenantId,
    required String contractId,
    Future<List<Map<String, dynamic>>> Function()? readLedger,
    ProcessRefundCall? call,
  }) async {
    final moveOut = moveOutResultFromServer(data, calculation);
    final due = cardRefundDue(data);
    if (!moveOut.success || due <= 0) return moveOut;
    final outcome = await MoveOutCardRefund.refundAfterMoveOut(
      facilityId: facilityId,
      tenantId: tenantId,
      contractId: contractId,
      amount: due,
      since: cardRefundSince(data),
      readLedger: readLedger,
      call: call,
    );
    return withCardRefund(moveOut, outcome);
  }

  /// When processMoveOut committed a move-out that left a card refund to
  /// the screen (`cardRefundSince`): any refund row on the ledger from then
  /// on may be another press's refund of this one. Null from a server from
  /// before it, whose first press refunds unchecked, as before.
  @visibleForTesting
  static DateTime? cardRefundSince(Map<String, dynamic> data) {
    final since = data['cardRefundSince'];
    return since is String ? DateTime.tryParse(since) : null;
  }

  /// The move-out date as processMoveOut takes it: the calendar day the
  /// owner picked, 'yyyy-MM-dd', which the server dates at noon UTC.
  ///
  /// This sent [DateTime.toIso8601String], local midnight with no offset.
  /// Node reads a zoneless time as UTC, so an owner in a US time zone who
  /// picked the 23rd had the contract, the unit and the ledger dated the
  /// evening of the 22nd.
  @visibleForTesting
  static String moveOutDay(DateTime moveOutDate) =>
      DateFormat('yyyy-MM-dd').format(moveOutDate);

  /// The card refund processMoveOut left to the screen (`cardRefundDue`),
  /// or 0: none asked for, a retry of a finished move-out, or a server from
  /// before it (which recorded a card refund as made and says so in
  /// refundPosted, so nothing is refunded here on top of it).
  @visibleForTesting
  static double cardRefundDue(Map<String, dynamic> data) {
    if (data['alreadyCompleted'] == true) return 0;
    final due = data['cardRefundDue'];
    return due is num && due.isFinite && due > 0 ? MoveOutCardRefund.cents(due.toDouble()) : 0;
  }

  /// The card refund a finished move-out left pending, from processMoveOut's
  /// answer to a second press (`pendingCardRefund`): the first press
  /// committed, but its answer never arrived, so the card was never
  /// refunded, and this press was told only that nothing had changed. Null
  /// when none is pending, on a first press, or from a server that does not
  /// say.
  @visibleForTesting
  static PendingCardRefund? pendingCardRefund(Map<String, dynamic> data) {
    if (data['alreadyCompleted'] != true) return null;
    final pending = data['pendingCardRefund'];
    if (pending is! Map) return null;
    final requested = pending['requested'];
    if (requested is! num || !requested.isFinite || requested <= 0) return null;
    final since = pending['since'];
    return (
      requested: MoveOutCardRefund.cents(requested.toDouble()),
      since: since is String ? DateTime.tryParse(since) : null,
    );
  }

  /// What processMoveOut answered, for the screen. A move-out that had
  /// already been completed (a retry after a dropped connection) charged
  /// and freed nothing this time: its charges are not shown as posted
  /// again, and the owner is told. The tenant's new rent, or a request to
  /// check it, comes with the result. The refund is shown only when the
  /// server recorded one (`refundRecorded`, or `refundPosted` from a server
  /// that sends only that): with Process Refund off the credit stays on the
  /// ledger. A card refund the server leaves to the screen ([cardRefundDue])
  /// is made next ([withCardRefund]), so the server's refundWarning, which
  /// says it was not made, is not shown for it. "Refund: $36.67" was shown
  /// for a card refund nothing had made. A card refund an earlier press
  /// left pending comes back with a repeat ([pendingCardRefund]).
  @visibleForTesting
  static MoveOutResult moveOutResultFromServer(
    Map<String, dynamic> data,
    MoveOutCalculation calculation,
  ) {
    final repeat = data['alreadyCompleted'] == true;
    String? text(Object? value) =>
        value is String && value.trim().isNotEmpty ? value.trim() : null;
    // refundPosted is the same answer from a server that sends only that.
    // A server that sends neither predates both and recorded every refund.
    final recorded = data['refundRecorded'] ?? data['refundPosted'];
    final refundRecorded = recorded is bool ? recorded : true;
    final cardRefundNext = cardRefundDue(data) > 0;
    final warnings = [
      if (text(data['rentWarning']) != null) text(data['rentWarning'])!,
      if (!cardRefundNext && text(data['refundWarning']) != null) text(data['refundWarning'])!,
    ];
    return MoveOutResult(
      success: data['success'] == true,
      charges: repeat ? null : calculation.newCharges,
      refund: repeat || !refundRecorded ? null : calculation.refundAmount,
      notice: text(data['rentNotice']),
      warning: repeat
          ? text(data['message'])
          : warnings.isEmpty
              ? null
              : warnings.join(' '),
      pendingCardRefund: pendingCardRefund(data),
    );
  }

  /// [moveOut] with the card refund [outcome] made after it: the amount
  /// refunded to the card is shown as the refund, and when not all of it
  /// was refunded, [MoveOutResult.refundAlert] says what happened and what
  /// the owner does now (refund the rest in Stripe, then record it with Add
  /// entry, type Refund). The screen keeps that on screen until they close
  /// it, not in a snackbar that is gone in seconds.
  @visibleForTesting
  static MoveOutResult withCardRefund(MoveOutResult moveOut, CardRefundOutcome outcome) =>
      MoveOutResult(
        success: moveOut.success,
        ledgerEntryIds: moveOut.ledgerEntryIds,
        charges: moveOut.charges,
        refund: outcome.refunded > 0 ? outcome.refunded : null,
        refundByCard: outcome.refunded > 0,
        refundAlert: outcome.ownerAlert,
        refundAlertTitle: outcome.alertTitle,
        error: moveOut.error,
        warning: moveOut.warning,
        notice: moveOut.notice,
        pendingCardRefund: moveOut.pendingCardRefund,
      );
}

class MoveOutCalculation {
  final List<InvoiceLineItem> lineItems;
  final double currentBalance;
  final double newCharges;
  final double finalBalance;
  final double refundAmount;

  /// Whether the rent line was worked out (Prorate Rent ticked).
  final bool prorateRent;

  /// The cleaning, damage and other fees together.
  final double fees;

  MoveOutCalculation({
    required this.lineItems,
    required this.currentBalance,
    required this.newCharges,
    required this.finalBalance,
    required this.refundAmount,
    this.prorateRent = false,
    this.fees = 0,
  });
}

class MoveOutResult {
  final bool success;
  final List<String> ledgerEntryIds;
  final double? charges;
  final double? refund;
  final String? error;

  /// The move-out went through but a later step needs a look.
  final String? warning;

  /// For the owner with the finished move-out: the tenant's new rent.
  final String? notice;

  /// [refund] went back to the tenant's card through Stripe.
  final bool refundByCard;

  /// A card refund that was not (all) made: what happened and what the
  /// owner does now. Shown until they close it.
  final String? refundAlert;

  /// The heading for [refundAlert].
  final String? refundAlertTitle;

  /// On a repeat of a finished move-out: the card refund the first press
  /// left pending, which the screen tells the owner about and makes only if
  /// they say so.
  final PendingCardRefund? pendingCardRefund;

  MoveOutResult({
    required this.success,
    this.ledgerEntryIds = const [],
    this.charges,
    this.refund,
    this.error,
    this.warning,
    this.notice,
    this.refundByCard = false,
    this.refundAlert,
    this.refundAlertTitle,
    this.pendingCardRefund,
  });
}

