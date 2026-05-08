export declare const MAX_INPUT_CHARS = 2000;
export declare const MAX_OUTPUT_TOKENS = 380;
export declare const MAX_REQUESTS_PER_USER_PER_MINUTE = 5;
export declare const OPENAI_CHAT_MODEL = "gpt-4o-mini";
export declare function hashUserId(userId: string): string;
/** Currently unused by handlers; kept for parity with legacy index. */
export declare function isStorageFacilityRelated(message: string): boolean;
export declare function containsPromptInjection(message: string): boolean;
export declare function containsSuspiciousPatterns(message: string): {
    detected: boolean;
    patterns: string[];
};
export declare function isValidMessageStructure(message: string): {
    valid: boolean;
    reason?: string;
};
export declare function containsNonsenseOrPersonalizedRequest(message: string): boolean;
//# sourceMappingURL=aiGuards.d.ts.map