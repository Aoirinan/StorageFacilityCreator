import * as functions from 'firebase-functions/v1';
import { getPublicAppUrl } from './publicApp';

/**
 * HTTP callback target for Intuit OAuth.
 * Redirects into the Flutter hash route while preserving OAuth params.
 */
export const quickBooksOAuthCallback = functions.https.onRequest((req, res) => {
  const code = typeof req.query.code === 'string' ? req.query.code.trim() : '';
  const realmId = typeof req.query.realmId === 'string' ? req.query.realmId.trim() : '';
  const state = typeof req.query.state === 'string' ? req.query.state.trim() : '';
  const error = typeof req.query.error === 'string' ? req.query.error.trim() : '';

  const params = new URLSearchParams();
  params.set('tab', 'accounting');
  if (code) params.set('code', code);
  if (realmId) params.set('realmId', realmId);
  if (state) params.set('state', state);
  if (error) params.set('error', error);

  const redirectUrl = `${getPublicAppUrl()}/#/subscription?${params.toString()}`;
  res.set('Cache-Control', 'no-store');
  res.redirect(302, redirectUrl);
});
