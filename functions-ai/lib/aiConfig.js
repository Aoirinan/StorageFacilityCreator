"use strict";
var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));
var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});
var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();
Object.defineProperty(exports, "__esModule", { value: true });
exports.DEFAULT_AI_ASSISTANT_CONFIG = void 0;
exports.getAIAssistantConfig = getAIAssistantConfig;
exports.isAIAssistantEnabled = isAIAssistantEnabled;
exports.shouldUseOpenAIChat = shouldUseOpenAIChat;
const admin = __importStar(require("firebase-admin"));
const functions = __importStar(require("firebase-functions/v1"));
exports.DEFAULT_AI_ASSISTANT_CONFIG = {
    enabled: false,
    allowlistFacilityIds: [],
    killSwitch: false,
    executeActionsEnabled: false,
    maxTokensPerRequest: 1000,
    maxMessagesPerDay: 30,
    maxMessagesPerUser: 10,
    maxConversationHistory: 10,
    maxMessageLength: 2000,
};
async function getAIAssistantConfig() {
    var _a, _b, _c, _d, _e, _f, _g;
    try {
        const configDoc = await admin.firestore().collection('appConfig').doc('aiAssistant').get();
        if (!configDoc.exists) {
            return exports.DEFAULT_AI_ASSISTANT_CONFIG;
        }
        const data = configDoc.data() || {};
        const config = {
            enabled: (_a = data.enabled) !== null && _a !== void 0 ? _a : false,
            allowlistFacilityIds: data.allowlistFacilityIds || [],
            killSwitch: (_b = data.killSwitch) !== null && _b !== void 0 ? _b : false,
            executeActionsEnabled: data.executeActionsEnabled === true,
            provider: data.provider,
            maxTokensPerRequest: (_c = data.maxTokensPerRequest) !== null && _c !== void 0 ? _c : exports.DEFAULT_AI_ASSISTANT_CONFIG.maxTokensPerRequest,
            maxMessagesPerDay: (_d = data.maxMessagesPerDay) !== null && _d !== void 0 ? _d : exports.DEFAULT_AI_ASSISTANT_CONFIG.maxMessagesPerDay,
            maxMessagesPerUser: (_e = data.maxMessagesPerUser) !== null && _e !== void 0 ? _e : exports.DEFAULT_AI_ASSISTANT_CONFIG.maxMessagesPerUser,
            maxConversationHistory: (_f = data.maxConversationHistory) !== null && _f !== void 0 ? _f : exports.DEFAULT_AI_ASSISTANT_CONFIG.maxConversationHistory,
            maxMessageLength: (_g = data.maxMessageLength) !== null && _g !== void 0 ? _g : exports.DEFAULT_AI_ASSISTANT_CONFIG.maxMessageLength,
        };
        functions.logger.info('getAIAssistantConfig read from Firestore', {
            docExists: configDoc.exists,
            rawData: data,
            parsedConfig: config,
        });
        return config;
    }
    catch (error) {
        functions.logger.error('Error getting AI assistant config, using defaults:', error);
        return exports.DEFAULT_AI_ASSISTANT_CONFIG;
    }
}
async function isAIAssistantEnabled(facilityId) {
    const config = await getAIAssistantConfig();
    if (config.killSwitch) {
        return false;
    }
    const inAllowlist = facilityId ? config.allowlistFacilityIds.includes(facilityId) : false;
    return config.enabled || inAllowlist;
}
function shouldUseOpenAIChat(facilityId, config) {
    const providerCheck = config.provider === 'openai';
    const enabledCheck = config.enabled;
    const killSwitchCheck = !config.killSwitch;
    if (config.killSwitch || !config.enabled || !providerCheck) {
        functions.logger.warn('shouldUseOpenAIChat failed', {
            facilityId,
            killSwitch: config.killSwitch,
            enabled: config.enabled,
            provider: config.provider,
            providerMatches: providerCheck,
            killSwitchPassed: killSwitchCheck,
            enabledPassed: enabledCheck,
        });
        return { ok: false, allowlistPassed: false };
    }
    const allowlist = config.allowlistFacilityIds || [];
    const allowlistPassed = allowlist.length === 0 || allowlist.includes(facilityId);
    return { ok: allowlistPassed, allowlistPassed };
}
//# sourceMappingURL=aiConfig.js.map