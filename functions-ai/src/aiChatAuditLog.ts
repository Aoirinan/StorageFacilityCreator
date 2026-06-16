import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

export type AiChatAuditSource = 'aiAssistantChat' | 'aiAssistant';

/**
 * Persists one AI user/assistant turn for super-admin review (Admin SDK; not client-writable).
 * Failures are logged and swallowed so chat UX is not blocked by audit storage.
 */
export async function appendAiChatAuditLog(params: {
  facilityId: string;
  facilityName?: string;
  userId: string;
  userEmail?: string | null;
  userMessage: string;
  assistantReply: string;
  requestId: string;
  model: string;
  tokensUsed: number;
  latencyMs: number;
  providerUsed: string;
  source: AiChatAuditSource;
}): Promise<void> {
  try {
    await admin
      .firestore()
      .collection('facilities')
      .doc(params.facilityId)
      .collection('aiChatAuditLogs')
      .add({
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        facilityId: params.facilityId,
        facilityName: params.facilityName ?? null,
        userId: params.userId,
        userEmail: params.userEmail ?? null,
        userMessage: params.userMessage,
        assistantReply: params.assistantReply,
        requestId: params.requestId,
        model: params.model,
        tokensUsed: params.tokensUsed,
        latencyMs: params.latencyMs,
        providerUsed: params.providerUsed,
        source: params.source,
      });
  } catch (e: unknown) {
    const err = e as { message?: string };
    functions.logger.error('appendAiChatAuditLog failed', {
      facilityId: params.facilityId,
      error: err?.message,
    });
  }
}
