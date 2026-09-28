import * as functions from 'firebase-functions/v1';

import { STAYS_ERROR_REASONS, StaysErrorReason } from '@sfc/functions-shared/stays/contracts';

type FunctionsErrorCode = functions.https.FunctionsErrorCode;

/**
 * Every Stays error names a reason from contracts.ts in details.reason; the
 * app maps it to StaysCallableException(reason, details) and words it.
 */
export function staysError(
  code: FunctionsErrorCode,
  reason: StaysErrorReason,
  message: string,
  details?: Record<string, unknown>,
): functions.https.HttpsError {
  return new functions.https.HttpsError(code, message, { ...(details ?? {}), reason });
}

/** The reason an error carries, when it is a Stays HttpsError. */
export function staysErrorReason(error: unknown): StaysErrorReason | null {
  if (!(error instanceof functions.https.HttpsError)) return null;
  const details = error.details as { reason?: unknown } | undefined;
  const reason = details?.reason;
  return typeof reason === 'string' && (STAYS_ERROR_REASONS as readonly string[]).includes(reason)
    ? (reason as StaysErrorReason)
    : null;
}

export function isStaysError(error: unknown, reason?: StaysErrorReason): error is functions.https.HttpsError {
  const actual = staysErrorReason(error);
  return actual !== null && (reason === undefined || actual === reason);
}

/** Firestore's gRPC codes, as the Admin SDK reports them. */
export const GRPC_ABORTED = 10;
export const GRPC_ALREADY_EXISTS = 6;

export function grpcCode(error: unknown): number | string | undefined {
  return (error as { code?: number | string } | null)?.code;
}

export function isAlreadyExists(error: unknown): boolean {
  const code = grpcCode(error);
  return code === GRPC_ALREADY_EXISTS || code === 'already-exists' || code === 'ALREADY_EXISTS';
}

export function isAborted(error: unknown): boolean {
  const code = grpcCode(error);
  return code === GRPC_ABORTED || code === 'aborted' || code === 'ABORTED';
}
