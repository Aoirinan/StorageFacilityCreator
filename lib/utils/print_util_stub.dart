/// Stub for printWindow (non-web): no-op.
void printWindow() {}

/// Stub: receipt printing is web-only.
void printPaymentReceipt({
  required String tenantName,
  required String amountFormatted,
  required String dateFormatted,
  String? transactionId,
  String? businessName,
}) {}
