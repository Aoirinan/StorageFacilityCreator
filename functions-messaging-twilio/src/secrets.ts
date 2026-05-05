import { defineSecret, defineString } from 'firebase-functions/params';

export const SENDGRID_API_KEY = defineSecret('SENDGRID_API_KEY');
export const SENDGRID_SENDER_EMAIL = defineString('SENDGRID_SENDER_EMAIL');
export const SENDGRID_FROM_EMAIL = SENDGRID_SENDER_EMAIL;
export const SENDGRID_FROM_NAME = defineString('SENDGRID_FROM_NAME', { default: 'Storage Facility Creator' });

export const TWILIO_ACCOUNT_SID = defineString('TWILIO_ACCOUNT_SID');
export const TWILIO_AUTH_TOKEN = defineSecret('TWILIO_AUTH_TOKEN');
export const TWILIO_PHONE_NUMBER = defineString('TWILIO_PHONE_NUMBER');
export const TWILIO_DRY_RUN = defineString('TWILIO_DRY_RUN', { default: 'false' });

/** Same env names as default functions / functions-marketing — registry reads via provider in index. */
export const SFC_LEAD_LINE_NUMBER = defineString('SFC_LEAD_LINE_NUMBER', { default: '' });
export const SFC_LEAD_SMS_AUTO_REPLY = defineString(
  'SFC_LEAD_SMS_AUTO_REPLY',
  { default: 'Thanks for contacting Storage Facility Creator. We got your message and will follow up shortly.' },
);

export const SENDGRID_SECRETS = [SENDGRID_API_KEY];
export const TWILIO_SECRETS = [TWILIO_AUTH_TOKEN];
