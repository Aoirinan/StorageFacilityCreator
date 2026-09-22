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

/// Stub: invoice printing is web-only.
void printInvoice({
  required String facilityName,
  String? facilityAddress,
  String? facilityPhone,
  String? facilityEmail,
  required String tenantName,
  String? tenantAddress,
  String? tenantPhone,
  String? tenantEmail,
  String? unitNumber,
  required String invoiceNumber,
  required String issueDateFormatted,
  required String dueDateFormatted,
  required List<({String description, String amount})> lineItems,
  required String subtotalFormatted,
  String? taxFormatted,
  required String totalFormatted,
  required String balanceFormatted,
  String? notes,
  String? statusLabel,
}) {}
