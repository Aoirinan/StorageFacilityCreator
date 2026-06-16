import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import {
  DAILY_AI_USER_LIMIT,
  enforceAndConsumeDailyAiQuota,
  enforceAppCheckOrThrow,
  enforceRateLimit,
  enforceUserRateLimit,
  getFacilityDataForUserOrThrow,
} from '@sfc/functions-shared';

import {
  DEFAULT_AI_ASSISTANT_CONFIG,
  getAIAssistantConfig,
  isAIAssistantEnabled,
  shouldUseOpenAIChat,
} from './aiConfig';
import {
  containsPromptInjection,
  containsSuspiciousPatterns,
  hashUserId,
  isValidMessageStructure,
  MAX_INPUT_CHARS,
  MAX_OUTPUT_TOKENS,
  MAX_REQUESTS_PER_USER_PER_MINUTE,
  OPENAI_CHAT_MODEL,
} from './aiGuards';
import { AI_SECRETS, OPENAI_API_KEY } from './secrets';
import { appendAiChatAuditLog } from './aiChatAuditLog';

export const aiAssistant = functions.runWith({ secrets: AI_SECRETS }).https.onCall(async (data: unknown, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, message, conversationId } = data as {
    facilityId?: string;
    message?: string;
    conversationId?: string;
  };

  if (!facilityId || !message) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId and message are required');
  }

  try {
    const config = await getAIAssistantConfig();

    const aiEnabled = await isAIAssistantEnabled(facilityId);
    if (!aiEnabled) {
      throw new functions.https.HttpsError('failed-precondition', 'AI assistant is not enabled for this facility');
    }

    const maxLength = config.maxMessageLength || 2000;
    if (message.length > maxLength) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        `Message too long. Maximum ${maxLength} characters allowed.`,
      );
    }

    await enforceRateLimit({
      facilityId,
      userId: context.auth.uid,
      key: 'aiAssistant_user',
      limit: 10,
      windowSeconds: 60,
    });

    await enforceRateLimit({
      facilityId,
      userId: context.auth.uid,
      key: 'aiAssistant_facility',
      limit: 30,
      windowSeconds: 60,
    });

    const maxFacilityDaily = config.maxMessagesPerDay ?? DEFAULT_AI_ASSISTANT_CONFIG.maxMessagesPerDay!;
    const maxUserDaily = DAILY_AI_USER_LIMIT;
    await enforceAndConsumeDailyAiQuota({
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
    const ownerUid = facilityData?.ownerUid;
    const roles = facilityData?.roles || {};

    if (ownerUid !== context.auth.uid && roles[context.auth.uid] !== 'manager' && roles[context.auth.uid] !== 'employee') {
      throw new functions.https.HttpsError('permission-denied', 'User does not have permission');
    }

    let convId = conversationId;
    let conversationMessages: unknown[] = [];

    if (convId) {
      const convDoc = await admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('aiConversations')
        .doc(convId)
        .get();

      if (convDoc.exists) {
        conversationMessages = convDoc.data()?.messages || [];
      } else {
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

    const facilityName = facilityData?.name || 'your facility';
    const totalUnits = facilityData?.totalUnits || 0;
    const occupiedUnits = facilityData?.occupiedUnits || 0;
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
    let actions: unknown[] = [];

    try {
      const apiKey = OPENAI_API_KEY.value();
      if (!apiKey) {
        throw new Error('OpenAI API key not configured');
      }

      const { default: OpenAI } = await import('openai');
      const openai = new OpenAI({ apiKey });

      const openaiMessages: { role: string; content: string }[] = [{ role: 'system', content: systemPrompt }];

      const maxHistory = config.maxConversationHistory || 10;
      const recentMessages = conversationMessages.slice(-maxHistory);
      for (const msg of recentMessages) {
        const m = msg as { role?: string; content?: string };
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
        messages: openaiMessages as Parameters<typeof openai.chat.completions.create>[0]['messages'],
        temperature: 0.7,
        max_tokens: config.maxTokensPerRequest || 1000,
        response_format: { type: 'json_object' },
      });

      const aiResponse = completion.choices[0]?.message?.content || '';

      try {
        const parsed = JSON.parse(aiResponse) as { response?: string; actions?: unknown[] };
        response = parsed.response || aiResponse;
        actions = parsed.actions || [];
      } catch {
        response = aiResponse;
        actions = [];
      }
    } catch (apiError: unknown) {
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
      } else if (lowerMessage.includes('send reminder') || lowerMessage.includes('remind tenant')) {
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
      } else {
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
      .doc(convId!);

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
    const callerEmail = context.auth.token?.email as string | undefined;
    void appendAiChatAuditLog({
      facilityId,
      facilityName,
      userId: context.auth.uid,
      userEmail: callerEmail ?? null,
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
  } catch (error: unknown) {
    const err = error as { message?: string };
    functions.logger.error('Error in AI assistant:', error);
    throw new functions.https.HttpsError('internal', `Failed to process AI request: ${err.message || error}`);
  }
});

export const aiAssistantChat = functions
  .runWith({ secrets: AI_SECRETS, timeoutSeconds: 60, memory: '256MB' })
  .https.onCall(async (data: unknown, context) => {
    const startMs = Date.now();
    const requestId = `ai-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;

    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
    }
    enforceAppCheckOrThrow(context);

    const { facilityId, userId, message, conversationId: _conversationId, threadId: _threadId, facilityName } = data as {
      facilityId?: string;
      userId?: string;
      message?: string;
      conversationId?: string;
      threadId?: string;
      facilityName?: string;
    };

    if (!facilityId || !message || typeof message !== 'string') {
      throw new functions.https.HttpsError('invalid-argument', 'facilityId and message are required');
    }
    const uid = context.auth.uid;
    if (userId && userId !== uid) {
      throw new functions.https.HttpsError('invalid-argument', 'userId must match authenticated user');
    }

    if (message.length > MAX_INPUT_CHARS) {
      throw new functions.https.HttpsError(
        'invalid-argument',
        `Message too long. Maximum ${MAX_INPUT_CHARS} characters allowed.`,
      );
    }

    const structureCheck = isValidMessageStructure(message);
    if (!structureCheck.valid) {
      functions.logger.warn('aiAssistantChat invalid message structure', {
        facilityId,
        reason: structureCheck.reason,
        messageLength: message.length,
      });
      throw new functions.https.HttpsError(
        'invalid-argument',
        structureCheck.reason || 'Invalid message format',
      );
    }

    if (containsPromptInjection(message)) {
      functions.logger.warn('aiAssistantChat prompt injection detected', { facilityId });
      throw new functions.https.HttpsError(
        'invalid-argument',
        'Invalid request. Please ask a question about storage facility management.',
      );
    }

    const suspiciousCheck = containsSuspiciousPatterns(message);
    if (suspiciousCheck.detected) {
      functions.logger.warn('aiAssistantChat suspicious patterns detected', {
        facilityId,
        patterns: suspiciousCheck.patterns,
      });
      throw new functions.https.HttpsError(
        'invalid-argument',
        'Invalid request format. Please ask a question about storage facility management.',
      );
    }

    const config = await getAIAssistantConfig();

    functions.logger.info('aiAssistantChat config check', {
      enabled: config.enabled,
      killSwitch: config.killSwitch,
      provider: config.provider,
      providerType: typeof config.provider,
      allowlistLength: config.allowlistFacilityIds?.length || 0,
      facilityId,
      allowlistIncludesFacility: config.allowlistFacilityIds?.includes(facilityId) || false,
    });

    const { ok, allowlistPassed } = shouldUseOpenAIChat(facilityId, config);
    if (!ok) {
      functions.logger.warn('aiAssistantChat rejected', {
        facilityId,
        enabled: config.enabled,
        killSwitch: config.killSwitch,
        provider: config.provider,
        providerMatches: config.provider === 'openai',
        allowlistPassed,
      });
      throw new functions.https.HttpsError(
        'failed-precondition',
        'AI Assistant (OpenAI) is not enabled for this facility. Check app config or allowlist.',
      );
    }

    await enforceUserRateLimit(uid, 'aiAssistantChat', MAX_REQUESTS_PER_USER_PER_MINUTE, 60);

    const maxFacilityDaily = config.maxMessagesPerDay ?? DEFAULT_AI_ASSISTANT_CONFIG.maxMessagesPerDay!;
    const maxUserDaily = DAILY_AI_USER_LIMIT;
    const { refund } = await enforceAndConsumeDailyAiQuota({
      uid,
      facilityId,
      dailyLimitPerUser: maxUserDaily,
      dailyLimitPerFacility: maxFacilityDaily,
    });

    const facilityData = await getFacilityDataForUserOrThrow(uid, facilityId);

    const displayName = facilityName || (facilityData?.name as string) || 'your facility';
    const systemPrompt = `You are a helpful AI assistant for ${displayName}, a self-storage facility. You help facility owners and managers with anything related to running their business — tenant management, payments, pricing, occupancy, delinquency, best practices, marketing, legal questions about storage, and how to use this software. Be conversational, practical, and thorough. You can draft template messages, emails, or notices (e.g. late payment notices, move-out confirmations) since these are general templates, not sent to specific people. If asked something completely unrelated to the storage business or facility management, gently redirect back to how you can help. Keep responses focused and actionable.`;

    let replyText: string;
    let tokensUsed: number;
    const providerUsed = 'openai';
    const model = OPENAI_CHAT_MODEL;

    try {
      const apiKey = OPENAI_API_KEY.value();
      if (!apiKey) {
        throw new Error('OpenAI API key not configured');
      }
      const { default: OpenAI } = await import('openai');
      const openai = new OpenAI({ apiKey });

      try {
        const moderationResult = await openai.moderations.create({ input: message });
        const flagged = moderationResult.results[0]?.flagged || false;
        const categories = moderationResult.results[0]?.categories || {};

        if (flagged) {
          const flaggedCategories = Object.entries(categories)
            .filter(([, isFlagged]) => isFlagged)
            .map(([category]) => category);

          functions.logger.warn('aiAssistantChat content flagged by moderation API', {
            facilityId,
            categories: flaggedCategories,
          });

          throw new functions.https.HttpsError(
            'invalid-argument',
            'Your message contains inappropriate content. Please ask a question about storage facility management.',
          );
        }
      } catch (modErr: unknown) {
        const me = modErr as { message?: string };
        functions.logger.warn('aiAssistantChat moderation API check failed', {
          facilityId,
          error: me?.message,
        });
      }

      const completion = await openai.chat.completions.create({
        model: OPENAI_CHAT_MODEL,
        messages: [
          { role: 'system', content: systemPrompt },
          { role: 'user', content: message },
        ],
        temperature: 0.4,
        max_tokens: Math.min(MAX_OUTPUT_TOKENS, config.maxTokensPerRequest ?? MAX_OUTPUT_TOKENS),
      });

      const choice = completion.choices[0];
      replyText =
        (choice?.message?.content || '').trim() || "I couldn't generate a response. Please try again.";

      if (replyText.length > MAX_OUTPUT_TOKENS * 4) {
        replyText = replyText.substring(0, MAX_OUTPUT_TOKENS * 4) + '...';
        functions.logger.warn('aiAssistantChat response truncated', { facilityId });
      }

      if (containsPromptInjection(replyText)) {
        functions.logger.warn('aiAssistantChat prompt injection in response', { facilityId });
        replyText = 'I can only help with storage facility management questions.';
      }

      tokensUsed =
        (completion.usage?.total_tokens ?? 0) ||
        (completion.usage?.completion_tokens ?? 0) + (completion.usage?.prompt_tokens ?? 0);
    } catch (apiErr: unknown) {
      try {
        await refund();
      } catch (refundErr: unknown) {
        const re = refundErr as { message?: string };
        functions.logger.error('aiAssistantChat quota refund failed', {
          requestId,
          facilityId,
          userId: uid,
          error: re?.message,
        });
      }
      const ae = apiErr as { message?: string };
      functions.logger.error('aiAssistantChat OpenAI error', { requestId, error: ae?.message });
      throw new functions.https.HttpsError(
        'internal',
        ae?.message?.includes('rate')
          ? 'Service is busy. Please try again shortly.'
          : 'Failed to get AI response. Please try again.',
      );
    }

    const latencyMs = Date.now() - startMs;
    const userIdHashed = hashUserId(uid);

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

    const callerEmail = context.auth.token?.email as string | undefined;
    void appendAiChatAuditLog({
      facilityId,
      facilityName: displayName,
      userId: uid,
      userEmail: callerEmail ?? null,
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

export const aiAssistantExecuteAction = functions.https.onCall(async (data: unknown, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  enforceAppCheckOrThrow(context);

  const { facilityId, conversationId, action } = data as {
    facilityId?: string;
    conversationId?: string;
    action?: { type?: string };
  };

  if (!facilityId || !conversationId || !action) {
    throw new functions.https.HttpsError('invalid-argument', 'facilityId, conversationId, and action are required');
  }

  try {
    const aiCfg = await getAIAssistantConfig();
    if (aiCfg.executeActionsEnabled !== true) {
      throw new functions.https.HttpsError(
        'failed-precondition',
        'AI action execution is not enabled. Set appConfig/aiAssistant.executeActionsEnabled to true when ready.',
      );
    }

    const aiEnabled = await isAIAssistantEnabled(facilityId);
    if (!aiEnabled) {
      throw new functions.https.HttpsError('failed-precondition', 'AI assistant is not enabled for this facility');
    }

    const facilityDoc = await admin.firestore().collection('facilities').doc(facilityId).get();

    if (!facilityDoc.exists) {
      throw new functions.https.HttpsError('not-found', 'Facility not found');
    }

    const actionType = action.type as string;
    let result: Record<string, unknown> = { success: false, message: 'Action not implemented' };

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
      const messages = (conversation.data()?.messages || []) as Array<Record<string, unknown>>;
      let lastAssistantMessage: Record<string, unknown> | undefined;
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
  } catch (error: unknown) {
    const err = error as { message?: string };
    functions.logger.error('Error executing AI action:', error);
    throw new functions.https.HttpsError('internal', `Failed to execute action: ${err.message || error}`);
  }
});
