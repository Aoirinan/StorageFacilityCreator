export type AiChatAuditSource = 'aiAssistantChat' | 'aiAssistant';
/**
 * Persists one AI user/assistant turn for super-admin review (Admin SDK; not client-writable).
 * Failures are logged and swallowed so chat UX is not blocked by audit storage.
 */
export declare function appendAiChatAuditLog(params: {
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
}): Promise<void>;
//# sourceMappingURL=aiChatAuditLog.d.ts.map