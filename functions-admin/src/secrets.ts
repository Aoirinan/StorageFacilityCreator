import { defineSecret, defineString } from 'firebase-functions/params';

export const SENDGRID_API_KEY = defineSecret('SENDGRID_API_KEY');
export const SENDGRID_SENDER_EMAIL = defineString('SENDGRID_SENDER_EMAIL', { default: '' });
/** Same Firebase param as sender email (alias for call sites that use "from" naming). */
export const SENDGRID_FROM_EMAIL = SENDGRID_SENDER_EMAIL;
/** Non-interactive deploy reads from functions-admin/.env (see predeploy). */
export const SENDGRID_FROM_NAME = defineString('SENDGRID_FROM_NAME', { default: 'Storage Facility Creator' });

export const STRIPE_SECRET_KEY = defineSecret('STRIPE_SECRET_KEY');
export const STRIPE_WEBHOOK_SECRET = defineSecret('STRIPE_WEBHOOK_SECRET');
export const STRIPE_PUBLISHABLE_KEY = defineSecret('STRIPE_PUBLISHABLE_KEY');

export const SENDGRID_SECRETS = [SENDGRID_API_KEY];
export const STRIPE_SECRETS = [STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PUBLISHABLE_KEY];

export const HOSTING_PROJECT_ID = defineString('HOSTING_PROJECT_ID', { default: 'storage-facility-creator' });
export const HOSTING_SITE_ID = defineString('HOSTING_SITE_ID', { default: 'storage-facility-creator' });
