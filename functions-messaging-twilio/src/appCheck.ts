import * as functions from 'firebase-functions/v1';

export function enforceAppCheckOrThrow(context: functions.https.CallableContext) {
  if (!context.app) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'App Check token required. Please update your app.',
    );
  }
}
