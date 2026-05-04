import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

import { MARKETING_LEAD_CAPTURE_KEY, MARKETING_LEAD_SECRETS } from './secrets';

/**
 * Public marketing lead capture endpoint.
 * Called by marketing site's /api/contact route using a shared API key.
 */
export const captureMarketingLead = functions
  .runWith({ secrets: MARKETING_LEAD_SECRETS })
  .https.onRequest(async (req, res) => {
    res.set('Access-Control-Allow-Origin', '*');
    res.set('Access-Control-Allow-Headers', 'Content-Type, x-api-key');
    res.set('Access-Control-Allow-Methods', 'POST, OPTIONS');

    if (req.method === 'OPTIONS') {
      res.status(204).send('');
      return;
    }

    if (req.method !== 'POST') {
      res.status(405).json({ error: 'Method not allowed' });
      return;
    }

    try {
      const expectedKey = MARKETING_LEAD_CAPTURE_KEY.value().trim();
      const providedKey = String(req.headers['x-api-key'] || '').trim();
      if (!expectedKey || providedKey !== expectedKey) {
        res.status(401).json({ error: 'Unauthorized' });
        return;
      }

      const payload = (req.body || {}) as Record<string, unknown>;
      const name = String(payload.name || '').trim();
      const email = String(payload.email || '').trim();
      const facilityName = String(payload.facilityName || '').trim();
      const phone = String(payload.phone || '').trim();
      const unitCount = String(payload.unitCount || '').trim();
      const message = String(payload.message || '').trim();
      const intentRaw = String(payload.intent || 'demo').trim().toLowerCase();
      const intent = intentRaw === 'trial' ? 'trial' : 'demo';
      const smsConsent = Boolean(payload.smsConsent);
      const utmSource = String(payload.utmSource || '').trim();
      const utmMedium = String(payload.utmMedium || '').trim();
      const utmCampaign = String(payload.utmCampaign || '').trim();
      const utmTerm = String(payload.utmTerm || '').trim();
      const utmContent = String(payload.utmContent || '').trim();
      const landingPath = String(payload.landingPath || '').trim();
      const referrer = String(payload.referrer || '').trim();

      if (!name || !email || !facilityName) {
        res.status(400).json({ error: 'name, email, and facilityName are required' });
        return;
      }
      if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
        res.status(400).json({ error: 'Invalid email format' });
        return;
      }

      const now = admin.firestore.FieldValue.serverTimestamp();
      const docRef = await admin.firestore().collection('marketing_leads').add({
        source: 'website_contact',
        status: 'new',
        intent,
        name,
        email,
        facilityName,
        phone: phone || null,
        unitCount: unitCount || null,
        message: message || null,
        utmSource: utmSource || null,
        utmMedium: utmMedium || null,
        utmCampaign: utmCampaign || null,
        utmTerm: utmTerm || null,
        utmContent: utmContent || null,
        landingPath: landingPath || null,
        referrer: referrer || null,
        smsConsent,
        assignedToUid: null,
        assignedToEmail: null,
        assignedToName: null,
        lastCalledAt: null,
        saleStatus: 'pending',
        saleAmount: null,
        createdAt: now,
        updatedAt: now,
      });

      await docRef.collection('activities').add({
        type: 'lead_created',
        summary: `Lead created from website contact form (${intent}).`,
        actorUid: 'system',
        actorEmail: 'system',
        actorName: 'System',
        createdAt: now,
      });

      res.status(200).json({ success: true, id: docRef.id });
    } catch (error) {
      functions.logger.error('captureMarketingLead failed', { error });
      res.status(500).json({ error: 'Internal error' });
    }
  });
