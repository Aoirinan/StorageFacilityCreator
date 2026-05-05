import { defineSecret, defineString } from 'firebase-functions/params';

export const SENDGRID_API_KEY = defineSecret('SENDGRID_API_KEY');
export const SENDGRID_SENDER_EMAIL = defineString('SENDGRID_SENDER_EMAIL', { default: '' });
export const SENDGRID_FROM_EMAIL = SENDGRID_SENDER_EMAIL;
export const SENDGRID_FROM_NAME = defineString('SENDGRID_FROM_NAME', { default: 'Storage Facility Creator' });

export const SENDGRID_SECRETS = [SENDGRID_API_KEY];
