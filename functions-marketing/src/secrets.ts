import { defineSecret, defineString } from 'firebase-functions/params';

export const MARKETING_LEAD_CAPTURE_KEY = defineSecret('MARKETING_LEAD_CAPTURE_KEY');
export const TWILIO_AUTH_TOKEN = defineSecret('TWILIO_AUTH_TOKEN');

export const SFC_LEAD_LINE_NUMBER = defineString('SFC_LEAD_LINE_NUMBER', { default: '' });
export const SFC_LEAD_FORWARD_TO_NUMBER = defineString('SFC_LEAD_FORWARD_TO_NUMBER', { default: '' });
export const SFC_LEAD_SMS_AUTO_REPLY = defineString(
  'SFC_LEAD_SMS_AUTO_REPLY',
  { default: 'Thanks for contacting Storage Facility Creator. We got your message and will follow up shortly.' },
);

export const MARKETING_LEAD_SECRETS = [MARKETING_LEAD_CAPTURE_KEY];
export const SFC_LEAD_TWILIO_SECRETS = [TWILIO_AUTH_TOKEN];
