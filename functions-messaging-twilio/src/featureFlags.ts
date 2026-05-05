import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

export async function isFeatureFlagEnabled(flagKey: string): Promise<boolean> {
  try {
    const doc = await admin.firestore().collection('appConfig').doc('featureFlags').get();
    if (!doc.exists) return false;
    const data = doc.data() || {};
    const flagValue = data[flagKey] as Record<string, unknown> | undefined;
    return flagValue?.enabled === true;
  } catch (error: unknown) {
    const message = error instanceof Error ? error.message : String(error);
    functions.logger.error('Error reading feature flag, defaulting OFF', { flagKey, error: message });
    return false;
  }
}
