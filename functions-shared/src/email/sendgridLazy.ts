import * as functions from 'firebase-functions/v1';

import { requireSendgridMailConfigProvider } from './sendgridRegistry';

let sgMailCached: unknown = null;

export function getSgMail(): unknown {
  if (!sgMailCached) {
    const sgMailModule = require('@sendgrid/mail') as typeof import('@sendgrid/mail');
    sgMailCached = (sgMailModule as { default?: unknown }).default ?? sgMailModule;
  }
  return sgMailCached;
}

export function getSendgridAsmGroupId(): number | null {
  const v = process.env.SENDGRID_ASM_GROUP_ID?.trim();
  if (!v) return null;
  const n = parseInt(v, 10);
  return Number.isFinite(n) ? n : null;
}

let sendGridInitialized = false;

export function initializeSendGrid(): void {
  if (!sendGridInitialized) {
    functions.logger.info('🔍 [initializeSendGrid] Starting SendGrid initialization');

    const { getApiKey, getFromEmail } = requireSendgridMailConfigProvider();
    const apiKey = getApiKey();

    functions.logger.info('🔍 [initializeSendGrid] API key retrieved from secret', {
      keyExists: !!apiKey,
    });

    if (!apiKey) {
      functions.logger.error('❌ [initializeSendGrid] SENDGRID_API_KEY is null or empty');
      throw new Error('SENDGRID_API_KEY environment variable is not set');
    }

    const fromEmail = getFromEmail();

    functions.logger.info('🔍 [initializeSendGrid] From email retrieved', {
      emailExists: !!fromEmail,
      email: fromEmail || 'N/A',
    });

    if (!fromEmail) {
      functions.logger.error('❌ [initializeSendGrid] SENDGRID_FROM_EMAIL is null or empty');
      throw new Error('SENDGRID_SENDER_EMAIL environment variable is not set');
    }

    functions.logger.info('🔍 [initializeSendGrid] Setting API key on sgMail client');

    (getSgMail() as { setApiKey: (k: string) => void }).setApiKey(apiKey);
    sendGridInitialized = true;

    functions.logger.info('✅ [initializeSendGrid] SendGrid initialization complete', {
      sendGridInitialized,
      fromEmail,
    });
  } else {
    functions.logger.info('⚠️ [initializeSendGrid] SendGrid already initialized, skipping');
  }
}
