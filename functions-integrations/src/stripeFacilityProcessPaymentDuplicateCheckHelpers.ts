export const DUPLICATE_PAYMENT_WINDOW_MS = 5 * 60 * 1000;

export function duplicatePaymentWindowStartMs(nowMs: number): number {
  return nowMs - DUPLICATE_PAYMENT_WINDOW_MS;
}

export function shouldRejectDuplicatePayment(hasMatchingRecentPayment: boolean): boolean {
  return hasMatchingRecentPayment;
}
