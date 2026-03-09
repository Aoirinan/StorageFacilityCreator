import 'package:flutter/material.dart';

/// All calendar event categories
enum CalendarEventType {
  // Billing & Payments
  billingDue,
  autopayRun,
  lateFeeApplied,
  paymentReceived,

  // Delinquency & Legal
  delinquencyNotice,
  lienFiled,
  auctionScheduled,
  auctionComplete,

  // Tenant Lifecycle
  moveIn,
  moveOut,
  reservation,
  transfer,

  // Contracts
  contractExpiring,
  contractSigned,

  // Insurance
  insuranceExpiring,

  // Communications
  scheduledMessage,
  reminderDue,

  // Operations
  overlockScheduled,
  maintenanceWindow,
  staffNote,
}

/// Priority / urgency level for visual differentiation
enum CalendarEventPriority {
  low,
  normal,
  high,
  critical,
}

/// A unified calendar event that aggregates data from all facility subsystems.
/// Events are derived (not stored separately) — the service builds them from
/// existing Firestore documents (tenants, payments, liens, contracts, etc.).
class CalendarEvent {
  final String id;
  final String facilityId;

  /// Human-readable title shown on the calendar tile
  final String title;

  /// Optional subtitle / description shown in the detail sheet
  final String? subtitle;

  final CalendarEventType type;
  final CalendarEventPriority priority;

  /// The date this event occurs on (time component is used for sorting)
  final DateTime date;

  /// Optional end date for range events (e.g. maintenance windows)
  final DateTime? endDate;

  /// Related entity IDs for deep-linking
  final String? tenantId;
  final String? tenantName;
  final String? unitId;
  final String? unitNumber;
  final String? contractId;
  final String? lienId;
  final String? paymentId;

  /// Monetary amount, if relevant (e.g. payment due, late fee)
  final double? amount;

  /// Whether this event has already been acted on / completed
  final bool isCompleted;

  /// Deep-link route to navigate to when the event is tapped
  final String? actionRoute;

  /// Extra query parameters for the action route
  final Map<String, String>? actionParams;

  const CalendarEvent({
    required this.id,
    required this.facilityId,
    required this.title,
    this.subtitle,
    required this.type,
    this.priority = CalendarEventPriority.normal,
    required this.date,
    this.endDate,
    this.tenantId,
    this.tenantName,
    this.unitId,
    this.unitNumber,
    this.contractId,
    this.lienId,
    this.paymentId,
    this.amount,
    this.isCompleted = false,
    this.actionRoute,
    this.actionParams,
  });

  // ── Display helpers ────────────────────────────────────────────────────────

  Color get color {
    switch (type) {
      case CalendarEventType.billingDue:
      case CalendarEventType.autopayRun:
        return const Color(0xFF3B82F6); // blue
      case CalendarEventType.lateFeeApplied:
        return const Color(0xFFF59E0B); // amber
      case CalendarEventType.paymentReceived:
        return const Color(0xFF10B981); // green
      case CalendarEventType.delinquencyNotice:
        return const Color(0xFFF97316); // orange
      case CalendarEventType.lienFiled:
      case CalendarEventType.auctionScheduled:
      case CalendarEventType.auctionComplete:
        return const Color(0xFFEF4444); // red
      case CalendarEventType.moveIn:
        return const Color(0xFF10B981); // green
      case CalendarEventType.moveOut:
        return const Color(0xFF6366F1); // indigo
      case CalendarEventType.reservation:
        return const Color(0xFF8B5CF6); // violet
      case CalendarEventType.transfer:
        return const Color(0xFF06B6D4); // cyan
      case CalendarEventType.contractExpiring:
        return const Color(0xFFF59E0B); // amber
      case CalendarEventType.contractSigned:
        return const Color(0xFF10B981); // green
      case CalendarEventType.insuranceExpiring:
        return const Color(0xFFF97316); // orange
      case CalendarEventType.scheduledMessage:
        return const Color(0xFF3B82F6); // blue
      case CalendarEventType.reminderDue:
        return const Color(0xFFF59E0B); // amber
      case CalendarEventType.overlockScheduled:
        return const Color(0xFFEF4444); // red
      case CalendarEventType.maintenanceWindow:
        return const Color(0xFF6B7280); // gray
      case CalendarEventType.staffNote:
        return const Color(0xFF6B7280); // gray
    }
  }

  IconData get icon {
    switch (type) {
      case CalendarEventType.billingDue:
        return Icons.receipt_long;
      case CalendarEventType.autopayRun:
        return Icons.autorenew;
      case CalendarEventType.lateFeeApplied:
        return Icons.money_off;
      case CalendarEventType.paymentReceived:
        return Icons.payments;
      case CalendarEventType.delinquencyNotice:
        return Icons.warning_amber;
      case CalendarEventType.lienFiled:
        return Icons.gavel;
      case CalendarEventType.auctionScheduled:
        return Icons.sell;
      case CalendarEventType.auctionComplete:
        return Icons.check_circle;
      case CalendarEventType.moveIn:
        return Icons.login;
      case CalendarEventType.moveOut:
        return Icons.logout;
      case CalendarEventType.reservation:
        return Icons.bookmark;
      case CalendarEventType.transfer:
        return Icons.swap_horiz;
      case CalendarEventType.contractExpiring:
        return Icons.description;
      case CalendarEventType.contractSigned:
        return Icons.draw;
      case CalendarEventType.insuranceExpiring:
        return Icons.shield;
      case CalendarEventType.scheduledMessage:
        return Icons.schedule_send;
      case CalendarEventType.reminderDue:
        return Icons.notifications;
      case CalendarEventType.overlockScheduled:
        return Icons.lock;
      case CalendarEventType.maintenanceWindow:
        return Icons.build;
      case CalendarEventType.staffNote:
        return Icons.note;
    }
  }

  String get typeLabel {
    switch (type) {
      case CalendarEventType.billingDue:
        return 'Billing Due';
      case CalendarEventType.autopayRun:
        return 'Autopay Run';
      case CalendarEventType.lateFeeApplied:
        return 'Late Fee';
      case CalendarEventType.paymentReceived:
        return 'Payment';
      case CalendarEventType.delinquencyNotice:
        return 'Delinquency Notice';
      case CalendarEventType.lienFiled:
        return 'Lien Filed';
      case CalendarEventType.auctionScheduled:
        return 'Auction';
      case CalendarEventType.auctionComplete:
        return 'Auction Complete';
      case CalendarEventType.moveIn:
        return 'Move-In';
      case CalendarEventType.moveOut:
        return 'Move-Out';
      case CalendarEventType.reservation:
        return 'Reservation';
      case CalendarEventType.transfer:
        return 'Transfer';
      case CalendarEventType.contractExpiring:
        return 'Contract Expiring';
      case CalendarEventType.contractSigned:
        return 'Contract Signed';
      case CalendarEventType.insuranceExpiring:
        return 'Insurance Expiring';
      case CalendarEventType.scheduledMessage:
        return 'Scheduled Message';
      case CalendarEventType.reminderDue:
        return 'Reminder';
      case CalendarEventType.overlockScheduled:
        return 'Overlock';
      case CalendarEventType.maintenanceWindow:
        return 'Maintenance';
      case CalendarEventType.staffNote:
        return 'Staff Note';
    }
  }

  String? get formattedAmount {
    if (amount == null) return null;
    return '\$${amount!.toStringAsFixed(2)}';
  }
}

/// Filter state for which event categories are visible
class CalendarFilter {
  final bool showBilling;
  final bool showDelinquency;
  final bool showMoveInOut;
  final bool showContracts;
  final bool showInsurance;
  final bool showCommunications;
  final bool showOperations;

  const CalendarFilter({
    this.showBilling = true,
    this.showDelinquency = true,
    this.showMoveInOut = true,
    this.showContracts = true,
    this.showInsurance = true,
    this.showCommunications = true,
    this.showOperations = true,
  });

  CalendarFilter copyWith({
    bool? showBilling,
    bool? showDelinquency,
    bool? showMoveInOut,
    bool? showContracts,
    bool? showInsurance,
    bool? showCommunications,
    bool? showOperations,
  }) {
    return CalendarFilter(
      showBilling: showBilling ?? this.showBilling,
      showDelinquency: showDelinquency ?? this.showDelinquency,
      showMoveInOut: showMoveInOut ?? this.showMoveInOut,
      showContracts: showContracts ?? this.showContracts,
      showInsurance: showInsurance ?? this.showInsurance,
      showCommunications: showCommunications ?? this.showCommunications,
      showOperations: showOperations ?? this.showOperations,
    );
  }

  bool isVisible(CalendarEventType type) {
    switch (type) {
      case CalendarEventType.billingDue:
      case CalendarEventType.autopayRun:
      case CalendarEventType.lateFeeApplied:
      case CalendarEventType.paymentReceived:
        return showBilling;
      case CalendarEventType.delinquencyNotice:
      case CalendarEventType.lienFiled:
      case CalendarEventType.auctionScheduled:
      case CalendarEventType.auctionComplete:
        return showDelinquency;
      case CalendarEventType.moveIn:
      case CalendarEventType.moveOut:
      case CalendarEventType.reservation:
      case CalendarEventType.transfer:
        return showMoveInOut;
      case CalendarEventType.contractExpiring:
      case CalendarEventType.contractSigned:
        return showContracts;
      case CalendarEventType.insuranceExpiring:
        return showInsurance;
      case CalendarEventType.scheduledMessage:
      case CalendarEventType.reminderDue:
        return showCommunications;
      case CalendarEventType.overlockScheduled:
      case CalendarEventType.maintenanceWindow:
      case CalendarEventType.staffNote:
        return showOperations;
    }
  }
}
