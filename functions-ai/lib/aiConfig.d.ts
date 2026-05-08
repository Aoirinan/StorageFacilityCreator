export interface AIAssistantConfig {
    enabled: boolean;
    allowlistFacilityIds: string[];
    killSwitch: boolean;
    /** When false (default), aiAssistantExecuteAction rejects all requests (stub not ready for production). */
    executeActionsEnabled?: boolean;
    provider?: string;
    maxTokensPerRequest?: number;
    maxMessagesPerDay?: number;
    maxMessagesPerUser?: number;
    maxConversationHistory?: number;
    maxMessageLength?: number;
}
export declare const DEFAULT_AI_ASSISTANT_CONFIG: AIAssistantConfig;
export declare function getAIAssistantConfig(): Promise<AIAssistantConfig>;
export declare function isAIAssistantEnabled(facilityId?: string): Promise<boolean>;
export declare function shouldUseOpenAIChat(facilityId: string, config: AIAssistantConfig): {
    ok: boolean;
    allowlistPassed: boolean;
};
//# sourceMappingURL=aiConfig.d.ts.map