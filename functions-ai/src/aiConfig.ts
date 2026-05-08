import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

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

export const DEFAULT_AI_ASSISTANT_CONFIG: AIAssistantConfig = {
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

export async function getAIAssistantConfig(): Promise<AIAssistantConfig> {
  try {
    const configDoc = await admin.firestore().collection('appConfig').doc('aiAssistant').get();

    if (!configDoc.exists) {
      return DEFAULT_AI_ASSISTANT_CONFIG;
    }

    const data = configDoc.data() || {};
    const config = {
      enabled: data.enabled ?? false,
      allowlistFacilityIds: data.allowlistFacilityIds || [],
      killSwitch: data.killSwitch ?? false,
      executeActionsEnabled: data.executeActionsEnabled === true,
      provider: data.provider as string | undefined,
      maxTokensPerRequest: data.maxTokensPerRequest ?? DEFAULT_AI_ASSISTANT_CONFIG.maxTokensPerRequest,
      maxMessagesPerDay: data.maxMessagesPerDay ?? DEFAULT_AI_ASSISTANT_CONFIG.maxMessagesPerDay,
      maxMessagesPerUser: data.maxMessagesPerUser ?? DEFAULT_AI_ASSISTANT_CONFIG.maxMessagesPerUser,
      maxConversationHistory: data.maxConversationHistory ?? DEFAULT_AI_ASSISTANT_CONFIG.maxConversationHistory,
      maxMessageLength: data.maxMessageLength ?? DEFAULT_AI_ASSISTANT_CONFIG.maxMessageLength,
    };

    functions.logger.info('getAIAssistantConfig read from Firestore', {
      docExists: configDoc.exists,
      rawData: data,
      parsedConfig: config,
    });

    return config;
  } catch (error: unknown) {
    functions.logger.error('Error getting AI assistant config, using defaults:', error);
    return DEFAULT_AI_ASSISTANT_CONFIG;
  }
}

export async function isAIAssistantEnabled(facilityId?: string): Promise<boolean> {
  const config = await getAIAssistantConfig();

  if (config.killSwitch) {
    return false;
  }

  const inAllowlist = facilityId ? config.allowlistFacilityIds.includes(facilityId) : false;
  return config.enabled || inAllowlist;
}

export function shouldUseOpenAIChat(
  facilityId: string,
  config: AIAssistantConfig,
): { ok: boolean; allowlistPassed: boolean } {
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
