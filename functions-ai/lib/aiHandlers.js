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
exports.aiAssistantExecuteAction = exports.aiAssistantChat = exports.aiAssistant = void 0;
const admin = __importStar(require("firebase-admin"));
const functions = __importStar(require("firebase-functions/v1"));
const functions_shared_1 = require("@sfc/functions-shared");
const aiConfig_1 = require("./aiConfig");
const aiGuards_1 = require("./aiGuards");
const secrets_1 = require("./secrets");
const aiChatAuditLog_1 = require("./aiChatAuditLog");
exports.aiAssistant = functions.runWith({ secrets: secrets_1.AI_SECRETS }).https.onCall(async (data, context) => {
    var _a, _b, _c, _d, _e;
    if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
    }
    (0, functions_shared_1.enforceAppCheckOrThrow)(context);
    const { facilityId, message, conversationId } = data;
    if (!facilityId || !message) {
        throw new functions.https.HttpsError('invalid-argument', 'facilityId and message are required');
    }
    try {
        const config = await (0, aiConfig_1.getAIAssistantConfig)();
        const aiEnabled = await (0, aiConfig_1.isAIAssistantEnabled)(facilityId);
        if (!aiEnabled) {
            throw new functions.https.HttpsError('failed-precondition', 'AI assistant is not enabled for this facility');
        }
        const maxLength = config.maxMessageLength || 2000;
        if (message.length > maxLength) {
            throw new functions.https.HttpsError('invalid-argument', `Message too long. Maximum ${maxLength} characters allowed.`);
        }
        await (0, functions_shared_1.enforceRateLimit)({
            facilityId,
            userId: context.auth.uid,
            key: 'aiAssistant_user',
            limit: 10,
            windowSeconds: 60,
        });
        await (0, functions_shared_1.enforceRateLimit)({
            facilityId,
            userId: context.auth.uid,
            key: 'aiAssistant_facility',
            limit: 30,
            windowSeconds: 60,
        });
        const maxFacilityDaily = (_a = config.maxMessagesPerDay) !== null && _a !== void 0 ? _a : aiConfig_1.DEFAULT_AI_ASSISTANT_CONFIG.maxMessagesPerDay;
        const maxUserDaily = functions_shared_1.DAILY_AI_USER_LIMIT;
        await (0, functions_shared_1.enforceAndConsumeDailyAiQuota)({
            uid: context.auth.uid,
            facilityId,
            dailyLimitPerUser: maxUserDaily,
            dailyLimitPerFacility: maxFacilityDaily,
        });
        const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
        if (!facilityDoc.exists) {
            throw new functions.https.HttpsError('not-found', 'Facility not found');
        }
        const facilityData = facilityDoc.data();
        const ownerUid = facilityData === null || facilityData === void 0 ? void 0 : facilityData.ownerUid;
        const roles = (facilityData === null || facilityData === void 0 ? void 0 : facilityData.roles) || {};
        if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'employee') {
            throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
        }
        let convId = conversationId;
        let conversationMessages = [];
        if (convId) {
            const convDoc = await admin
                .firestore()
                .collection('facilities')
                .doc(facilityId)
                .collection('aiConversations')
                .doc(convId)
                .get();
            if (convDoc.exists) {
                conversationMessages = ((_b = convDoc.data()) === null || _b === void 0 ? void 0 : _b.messages) || [];
            }
            else {
                convId = undefined;
            }
        }
        if (!convId) {
            const convRef = admin.firestore().collection('facilities').doc(facilityId).collection('aiConversations').doc();
            await convRef.set({
                facilityId,
                messages: [],
                createdAt: admin.firestore.FieldValue.serverTimestamp(),
                updatedAt: admin.firestore.FieldValue.serverTimestamp(),
            });
            convId = convRef.id;
        }
        const facilityName = (facilityData === null || facilityData === void 0 ? void 0 : facilityData.name) || 'your facility';
        const totalUnits = (facilityData === null || facilityData === void 0 ? void 0 : facilityData.totalUnits) || 0;
        const occupiedUnits = (facilityData === null || facilityData === void 0 ? void 0 : facilityData.occupiedUnits) || 0;
        const occupancyRate = totalUnits > 0 ? Math.round((occupiedUnits / totalUnits) * 100) : 0;
        const systemPrompt = `You are an AI assistant for a self-storage facility management system. Your role is to:
1. Answer questions about facility operations, tenant management, payments, and best practices
2. Propose actions when users request to do something (create tenant, send message, etc.)
3. Always require user confirmation before executing any action

Available actions you can propose:
- createTenant: Create a new tenant (requires: name, email, phone, unitNumber)
- createPayment: Create a payment record (requires: tenantId, amount, dueDate)
- sendMessage: Send SMS or email to tenant (requires: tenantId, message, channel)
- createReminder: Create a payment reminder (requires: tenantId, dueDate)
- updateTenant: Update tenant information (requires: tenantId, fields to update)
- createContract: Create a lease contract (requires: tenantId, unitId, terms)

When proposing actions, return a JSON object with this exact structure:
{
  "response": "A natural language response explaining what you'll do",
  "actions": [
    {
      "type": "createTenant",
      "description": "Description of the action",
      "parameters": {},
      "estimatedImpact": "What will happen",
      "requiresConfirmation": true
    }
  ]
}

If no actions are needed, return: {"response": "your response", "actions": []}

Facility context:
- Facility: ${facilityName}
- Total units: ${totalUnits}
- Occupied units: ${occupiedUnits}
- Occupancy rate: ${occupancyRate}%

Always be helpful, professional, and safety-conscious. Never execute actions without explicit user confirmation.`;
        let response = '';
        let actions = [];
        try {
            const apiKey = secrets_1.OPENAI_API_KEY.value();
            if (!apiKey) {
                throw new Error('OpenAI API key not configured');
            }
            const { default: OpenAI } = await Promise.resolve().then(() => __importStar(require('openai')));
            const openai = new OpenAI({ apiKey });
            const openaiMessages = [{ role: 'system', content: systemPrompt }];
            const maxHistory = config.maxConversationHistory || 10;
            const recentMessages = conversationMessages.slice(-maxHistory);
            for (const msg of recentMessages) {
                const m = msg;
                if (m.role === 'user' || m.role === 'assistant') {
                    openaiMessages.push({
                        role: m.role,
                        content: m.content || '',
                    });
                }
            }
            openaiMessages.push({ role: 'user', content: message });
            const completion = await openai.chat.completions.create({
                model: 'gpt-4o-mini',
                messages: openaiMessages,
                temperature: 0.7,
                max_tokens: config.maxTokensPerRequest || 1000,
                response_format: { type: 'json_object' },
            });
            const aiResponse = ((_d = (_c = completion.choices[0]) === null || _c === void 0 ? void 0 : _c.message) === null || _d === void 0 ? void 0 : _d.content) || '';
            try {
                const parsed = JSON.parse(aiResponse);
                response = parsed.response || aiResponse;
                actions = parsed.actions || [];
            }
            catch (_f) {
                response = aiResponse;
                actions = [];
            }
        }
        catch (apiError) {
            functions.logger.error('OpenAI API error:', apiError);
            const lowerMessage = message.toLowerCase();
            if (lowerMessage.includes('create tenant') || lowerMessage.includes('add tenant')) {
                response =
                    "I can help you create a new tenant. I'll need some information:\n\n" +
                        '• Tenant name\n' +
                        '• Email address\n' +
                        '• Phone number\n' +
                        '• Unit number (optional)\n\n' +
                        'Would you like me to create a tenant?';
                actions = [
                    {
                        type: 'createTenant',
                        description: 'Create a new tenant',
                        parameters: {},
                        estimatedImpact: 'Will create a new tenant record in the system',
                        requiresConfirmation: true,
                    },
                ];
            }
            else if (lowerMessage.includes('send reminder') || lowerMessage.includes('remind tenant')) {
                response =
                    "I can help you send a payment reminder to a tenant. I'll need:\n\n" +
                        '• Tenant name or email\n' +
                        '• Message content (optional)\n\n' +
                        'Would you like me to send a reminder?';
                actions = [
                    {
                        type: 'sendMessage',
                        description: 'Send payment reminder to tenant',
                        parameters: {},
                        estimatedImpact: 'Will send an SMS or email reminder to the tenant',
                        requiresConfirmation: true,
                    },
                ];
            }
            else {
                response =
                    "I understand you're asking about storage facility management. " +
                        'I can help you with:\n\n' +
                        '• Creating tenants, payments, contracts\n' +
                        '• Sending messages and reminders\n' +
                        '• Answering questions about facility operations\n\n' +
                        'What would you like me to do?';
            }
        }
        const conversationRef = admin
            .firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('aiConversations')
            .doc(convId);
        const userMessage = {
            role: 'user',
            content: message,
            timestamp: admin.firestore.FieldValue.serverTimestamp(),
        };
        const assistantMessage = {
            role: 'assistant',
            content: response,
            actions: actions,
            timestamp: admin.firestore.FieldValue.serverTimestamp(),
        };
        await conversationRef.update({
            messages: admin.firestore.FieldValue.arrayUnion(userMessage, assistantMessage),
            updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        const auditRequestId = `ai-assistant-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
        const callerEmail = (_e = context.auth.token) === null || _e === void 0 ? void 0 : _e.email;
        void (0, aiChatAuditLog_1.appendAiChatAuditLog)({
            facilityId,
            facilityName,
            userId: context.auth.uid,
            userEmail: callerEmail !== null && callerEmail !== void 0 ? callerEmail : null,
            userMessage: message,
            assistantReply: response,
            requestId: auditRequestId,
            model: 'gpt-4o-mini',
            tokensUsed: 0,
            latencyMs: 0,
            providerUsed: 'openai',
            source: 'aiAssistant',
        });
        return {
            conversationId: convId,
            response,
            actions,
        };
    }
    catch (error) {
        const err = error;
        functions.logger.error('Error in AI assistant:', error);
        throw new functions.https.HttpsError('internal', `Failed to process AI request: ${err.message || error}`);
    }
});
exports.aiAssistantChat = functions
    .runWith({ secrets: secrets_1.AI_SECRETS, timeoutSeconds: 60, memory: '256MB' })
    .https.onCall(async (data, context) => {
    var _a, _b, _c, _d, _e, _f, _g, _h, _j, _k, _l, _m, _o, _p, _q;
    const startMs = Date.now();
    const requestId = `ai-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
    if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
    }
    (0, functions_shared_1.enforceAppCheckOrThrow)(context);
    const { facilityId, userId, message, conversationId: _conversationId, threadId: _threadId, facilityName } = data;
    if (!facilityId || !message || typeof message !== 'string') {
        throw new functions.https.HttpsError('invalid-argument', 'facilityId and message are required');
    }
    const uid = context.auth.uid;
    if (userId && userId !== uid) {
        throw new functions.https.HttpsError('invalid-argument', 'userId must match authenticated user');
    }
    if (message.length > aiGuards_1.MAX_INPUT_CHARS) {
        throw new functions.https.HttpsError('invalid-argument', `Message too long. Maximum ${aiGuards_1.MAX_INPUT_CHARS} characters allowed.`);
    }
    const structureCheck = (0, aiGuards_1.isValidMessageStructure)(message);
    if (!structureCheck.valid) {
        functions.logger.warn('aiAssistantChat invalid message structure', {
            facilityId,
            reason: structureCheck.reason,
            messageLength: message.length,
        });
        throw new functions.https.HttpsError('invalid-argument', structureCheck.reason || 'Invalid message format');
    }
    if ((0, aiGuards_1.containsPromptInjection)(message)) {
        functions.logger.warn('aiAssistantChat prompt injection detected', { facilityId });
        throw new functions.https.HttpsError('invalid-argument', 'Invalid request. Please ask a question about storage facility management.');
    }
    const suspiciousCheck = (0, aiGuards_1.containsSuspiciousPatterns)(message);
    if (suspiciousCheck.detected) {
        functions.logger.warn('aiAssistantChat suspicious patterns detected', {
            facilityId,
            patterns: suspiciousCheck.patterns,
        });
        throw new functions.https.HttpsError('invalid-argument', 'Invalid request format. Please ask a question about storage facility management.');
    }
    const config = await (0, aiConfig_1.getAIAssistantConfig)();
    functions.logger.info('aiAssistantChat config check', {
        enabled: config.enabled,
        killSwitch: config.killSwitch,
        provider: config.provider,
        providerType: typeof config.provider,
        allowlistLength: ((_a = config.allowlistFacilityIds) === null || _a === void 0 ? void 0 : _a.length) || 0,
        facilityId,
        allowlistIncludesFacility: ((_b = config.allowlistFacilityIds) === null || _b === void 0 ? void 0 : _b.includes(facilityId)) || false,
    });
    const { ok, allowlistPassed } = (0, aiConfig_1.shouldUseOpenAIChat)(facilityId, config);
    if (!ok) {
        functions.logger.warn('aiAssistantChat rejected', {
            facilityId,
            enabled: config.enabled,
            killSwitch: config.killSwitch,
            provider: config.provider,
            providerMatches: config.provider === 'openai',
            allowlistPassed,
        });
        throw new functions.https.HttpsError('failed-precondition', 'AI Assistant (OpenAI) is not enabled for this facility. Check app config or allowlist.');
    }
    await (0, functions_shared_1.enforceUserRateLimit)(uid, 'aiAssistantChat', aiGuards_1.MAX_REQUESTS_PER_USER_PER_MINUTE, 60);
    const maxFacilityDaily = (_c = config.maxMessagesPerDay) !== null && _c !== void 0 ? _c : aiConfig_1.DEFAULT_AI_ASSISTANT_CONFIG.maxMessagesPerDay;
    const maxUserDaily = functions_shared_1.DAILY_AI_USER_LIMIT;
    const { refund } = await (0, functions_shared_1.enforceAndConsumeDailyAiQuota)({
        uid,
        facilityId,
        dailyLimitPerUser: maxUserDaily,
        dailyLimitPerFacility: maxFacilityDaily,
    });
    const facilityData = await (0, functions_shared_1.getFacilityDataForUserOrThrow)(uid, facilityId);
    const displayName = facilityName || (facilityData === null || facilityData === void 0 ? void 0 : facilityData.name) || 'your facility';
    const systemPrompt = `You are a helpful AI assistant for ${displayName}, a self-storage facility. You help facility owners and managers with anything related to running their business — tenant management, payments, pricing, occupancy, delinquency, best practices, marketing, legal questions about storage, and how to use this software. Be conversational, practical, and thorough. You can draft template messages, emails, or notices (e.g. late payment notices, move-out confirmations) since these are general templates, not sent to specific people. If asked something completely unrelated to the storage business or facility management, gently redirect back to how you can help. Keep responses focused and actionable.`;
    let replyText;
    let tokensUsed;
    const providerUsed = 'openai';
    const model = aiGuards_1.OPENAI_CHAT_MODEL;
    try {
        const apiKey = secrets_1.OPENAI_API_KEY.value();
        if (!apiKey) {
            throw new Error('OpenAI API key not configured');
        }
        const { default: OpenAI } = await Promise.resolve().then(() => __importStar(require('openai')));
        const openai = new OpenAI({ apiKey });
        try {
            const moderationResult = await openai.moderations.create({ input: message });
            const flagged = ((_d = moderationResult.results[0]) === null || _d === void 0 ? void 0 : _d.flagged) || false;
            const categories = ((_e = moderationResult.results[0]) === null || _e === void 0 ? void 0 : _e.categories) || {};
            if (flagged) {
                const flaggedCategories = Object.entries(categories)
                    .filter(([, isFlagged]) => isFlagged)
                    .map(([category]) => category);
                functions.logger.warn('aiAssistantChat content flagged by moderation API', {
                    facilityId,
                    categories: flaggedCategories,
                });
                throw new functions.https.HttpsError('invalid-argument', 'Your message contains inappropriate content. Please ask a question about storage facility management.');
            }
        }
        catch (modErr) {
            const me = modErr;
            functions.logger.warn('aiAssistantChat moderation API check failed', {
                facilityId,
                error: me === null || me === void 0 ? void 0 : me.message,
            });
        }
        const completion = await openai.chat.completions.create({
            model: aiGuards_1.OPENAI_CHAT_MODEL,
            messages: [
                { role: 'system', content: systemPrompt },
                { role: 'user', content: message },
            ],
            temperature: 0.4,
            max_tokens: Math.min(aiGuards_1.MAX_OUTPUT_TOKENS, (_f = config.maxTokensPerRequest) !== null && _f !== void 0 ? _f : aiGuards_1.MAX_OUTPUT_TOKENS),
        });
        const choice = completion.choices[0];
        replyText =
            (((_g = choice === null || choice === void 0 ? void 0 : choice.message) === null || _g === void 0 ? void 0 : _g.content) || '').trim() || "I couldn't generate a response. Please try again.";
        if (replyText.length > aiGuards_1.MAX_OUTPUT_TOKENS * 4) {
            replyText = replyText.substring(0, aiGuards_1.MAX_OUTPUT_TOKENS * 4) + '...';
            functions.logger.warn('aiAssistantChat response truncated', { facilityId });
        }
        if ((0, aiGuards_1.containsPromptInjection)(replyText)) {
            functions.logger.warn('aiAssistantChat prompt injection in response', { facilityId });
            replyText = 'I can only help with storage facility management questions.';
        }
        tokensUsed =
            ((_j = (_h = completion.usage) === null || _h === void 0 ? void 0 : _h.total_tokens) !== null && _j !== void 0 ? _j : 0) ||
                ((_l = (_k = completion.usage) === null || _k === void 0 ? void 0 : _k.completion_tokens) !== null && _l !== void 0 ? _l : 0) + ((_o = (_m = completion.usage) === null || _m === void 0 ? void 0 : _m.prompt_tokens) !== null && _o !== void 0 ? _o : 0);
    }
    catch (apiErr) {
        try {
            await refund();
        }
        catch (refundErr) {
            const re = refundErr;
            functions.logger.error('aiAssistantChat quota refund failed', {
                requestId,
                facilityId,
                userId: uid,
                error: re === null || re === void 0 ? void 0 : re.message,
            });
        }
        const ae = apiErr;
        functions.logger.error('aiAssistantChat OpenAI error', { requestId, error: ae === null || ae === void 0 ? void 0 : ae.message });
        throw new functions.https.HttpsError('internal', ((_p = ae === null || ae === void 0 ? void 0 : ae.message) === null || _p === void 0 ? void 0 : _p.includes('rate'))
            ? 'Service is busy. Please try again shortly.'
            : 'Failed to get AI response. Please try again.');
    }
    const latencyMs = Date.now() - startMs;
    const userIdHashed = (0, aiGuards_1.hashUserId)(uid);
    functions.logger.info('aiAssistantChat', {
        facilityId,
        userIdHashed,
        providerUsed,
        model,
        requestId,
        tokensUsed,
        latencyMs,
        allowlistPassed,
        facilityUsageLimit: maxFacilityDaily,
        userUsageLimit: maxUserDaily,
    });
    const callerEmail = (_q = context.auth.token) === null || _q === void 0 ? void 0 : _q.email;
    void (0, aiChatAuditLog_1.appendAiChatAuditLog)({
        facilityId,
        facilityName: displayName,
        userId: uid,
        userEmail: callerEmail !== null && callerEmail !== void 0 ? callerEmail : null,
        userMessage: message,
        assistantReply: replyText,
        requestId,
        model,
        tokensUsed,
        latencyMs,
        providerUsed,
        source: 'aiAssistantChat',
    });
    return {
        replyText,
        providerUsed,
        model,
        requestId,
        tokensUsed,
        latencyMs,
    };
});
exports.aiAssistantExecuteAction = functions.https.onCall(async (data, context) => {
    var _a;
    if (!context.auth) {
        throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
    }
    (0, functions_shared_1.enforceAppCheckOrThrow)(context);
    const { facilityId, conversationId, action } = data;
    if (!facilityId || !conversationId || !action) {
        throw new functions.https.HttpsError('invalid-argument', 'facilityId, conversationId, and action are required');
    }
    try {
        const aiCfg = await (0, aiConfig_1.getAIAssistantConfig)();
        if (aiCfg.executeActionsEnabled !== true) {
            throw new functions.https.HttpsError('failed-precondition', 'AI action execution is not enabled. Set appConfig/aiAssistant.executeActionsEnabled to true when ready.');
        }
        const aiEnabled = await (0, aiConfig_1.isAIAssistantEnabled)(facilityId);
        if (!aiEnabled) {
            throw new functions.https.HttpsError('failed-precondition', 'AI assistant is not enabled for this facility');
        }
        const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();
        if (!facilityDoc.exists) {
            throw new functions.https.HttpsError('not-found', 'Facility not found');
        }
        const actionType = action.type;
        let result = { success: false, message: 'Action not implemented' };
        switch (actionType) {
            case 'createTenant':
                result = { success: false, message: 'Action execution not yet implemented. API integration pending.' };
                break;
            case 'sendMessage':
                result = { success: false, message: 'Action execution not yet implemented. API integration pending.' };
                break;
            default:
                result = { success: false, message: `Unknown action type: ${actionType}` };
        }
        const conversationRef = admin
            .firestore()
            .collection('facilities')
            .doc(facilityId)
            .collection('aiConversations')
            .doc(conversationId);
        const conversation = await conversationRef.get();
        if (conversation.exists) {
            const messages = (((_a = conversation.data()) === null || _a === void 0 ? void 0 : _a.messages) || []);
            let lastAssistantMessage;
            for (let i = messages.length - 1; i >= 0; i--) {
                if (messages[i].role === 'assistant') {
                    lastAssistantMessage = messages[i];
                    break;
                }
            }
            if (lastAssistantMessage) {
                lastAssistantMessage.confirmedAction = action;
                lastAssistantMessage.executedAt = admin.firestore.FieldValue.serverTimestamp();
                await conversationRef.update({
                    messages: messages,
                    updatedAt: admin.firestore.FieldValue.serverTimestamp(),
                });
            }
        }
        return result;
    }
    catch (error) {
        const err = error;
        functions.logger.error('Error executing AI action:', error);
        throw new functions.https.HttpsError('internal', `Failed to execute action: ${err.message || error}`);
    }
});
//# sourceMappingURL=aiHandlers.js.map