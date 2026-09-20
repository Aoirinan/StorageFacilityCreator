import { NextRequest, NextResponse } from 'next/server';
import { SUPPORT_EMAIL } from '@/config/site';

const SENDGRID_API_URL = 'https://api.sendgrid.com/v3/mail/send';

type ContactLeadPayload = {
  to: string[];
  from: string;
  replyTo: string;
  subject: string;
  body: string;
};

async function sendContactLeadEmail(payload: ContactLeadPayload, apiKey: string): Promise<void> {
  const response = await fetch(SENDGRID_API_URL, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${apiKey}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      personalizations: [{ to: payload.to.map((email) => ({ email })), subject: payload.subject }],
      from: { email: payload.from },
      reply_to: { email: payload.replyTo },
      content: [{ type: 'text/plain', value: payload.body }],
    }),
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`SendGrid rejected contact lead email (${response.status}): ${errText}`);
  }
}

async function captureLeadForSuperAdmin(payload: Record<string, unknown>): Promise<void> {
  const endpoint = (process.env.MARKETING_LEAD_CAPTURE_URL ?? '').trim();
  const apiKey = (process.env.MARKETING_LEAD_CAPTURE_KEY ?? '').trim();
  if (!endpoint || !apiKey) return;

  const response = await fetch(endpoint, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-api-key': apiKey,
    },
    body: JSON.stringify(payload),
  });

  if (!response.ok) {
    const errText = await response.text();
    throw new Error(`Lead capture endpoint rejected payload (${response.status}): ${errText}`);
  }
}

/** Submissions faster than this after the form rendered are treated as automated. */
const MIN_FILL_TIME_MS = 3000;
/** Best-effort per-IP throttle; state lives only for the life of a warm instance. */
const RATE_LIMIT_WINDOW_MS = 10 * 60 * 1000;
const RATE_LIMIT_MAX = 5;
const recentSubmissions = new Map<string, number[]>();

function isRateLimited(ip: string): boolean {
  const now = Date.now();
  const stamps = (recentSubmissions.get(ip) ?? []).filter((t) => now - t < RATE_LIMIT_WINDOW_MS);
  if (stamps.length >= RATE_LIMIT_MAX) {
    recentSubmissions.set(ip, stamps);
    return true;
  }
  stamps.push(now);
  recentSubmissions.set(ip, stamps);
  if (recentSubmissions.size > 5000) recentSubmissions.clear();
  return false;
}

function looksAutomated(body: Record<string, unknown>): boolean {
  const honeypot = String(body.companyWebsite ?? '').trim();
  if (honeypot) return true;
  const openedAt = Number(String(body.formOpenedAt ?? '').trim());
  if (Number.isFinite(openedAt) && openedAt > 0 && Date.now() - openedAt < MIN_FILL_TIME_MS) return true;
  return false;
}

export async function POST(request: NextRequest) {
  try {
    const body = (await request.json()) as Record<string, unknown>;
    const ip = (request.headers.get('x-forwarded-for') ?? '').split(',')[0].trim() || 'unknown';
    if (isRateLimited(ip)) {
      return NextResponse.json(
        { message: 'Too many requests. Please wait a few minutes and try again, or email us.' },
        { status: 429 }
      );
    }
    if (looksAutomated(body)) {
      // Pretend success so bots do not learn what tripped them; nothing is sent.
      return NextResponse.json({ success: true });
    }

    const name = String(body.name ?? '').trim();
    const email = String(body.email ?? '').trim();
    const facilityName = String(body.facilityName ?? '').trim();
    const facilityAddress = String(body.facilityAddress ?? '').trim();
    const phone = String(body.phone ?? '').trim();
    const unitCount = String(body.unitCount ?? '').trim();
    const message = String(body.message ?? '').trim();
    const smsConsent = String(body.smsConsent ?? '').trim().toLowerCase() === 'on';
    const intent = String(body.intent ?? 'demo').trim().toLowerCase() === 'trial' ? 'trial' : 'demo';
    const utmSource = String(body.utmSource ?? '').trim();
    const utmMedium = String(body.utmMedium ?? '').trim();
    const utmCampaign = String(body.utmCampaign ?? '').trim();
    const utmTerm = String(body.utmTerm ?? '').trim();
    const utmContent = String(body.utmContent ?? '').trim();
    const landingPath = String(body.landingPath ?? '').trim();
    const referrer = String(body.referrer ?? '').trim();

    if (!name || !email || !facilityName) {
      return NextResponse.json(
        { message: 'Name, email, and facility name are required.' },
        { status: 400 }
      );
    }

    // Basic email format check
    if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return NextResponse.json(
        { message: 'Please enter a valid email address.' },
        { status: 400 }
      );
    }

    // Comma-separated list so more than one inbox sees a lead the moment it lands.
    const notifyEmails = (process.env.CONTACT_NOTIFY_EMAIL || '')
      .split(',')
      .map((value) => value.trim())
      .filter(Boolean);
    if (notifyEmails.length === 0) notifyEmails.push(SUPPORT_EMAIL);
    const sendgridApiKey = process.env.SENDGRID_API_KEY;
    const fromEmail = process.env.CONTACT_FROM_EMAIL || SUPPORT_EMAIL;
    const leadType = intent === 'trial' ? 'Trial request' : 'Demo request';
    const payload = {
      to: notifyEmails,
      from: fromEmail,
      replyTo: email,
      subject: `${leadType}: ${facilityName}`,
      body: [
        `Intent: ${leadType}`,
        `Name: ${name}`,
        `Email: ${email}`,
        `Facility: ${facilityName}`,
        facilityAddress ? `Facility address: ${facilityAddress}` : null,
        phone ? `Phone: ${phone}` : null,
        unitCount ? `Units: ${unitCount}` : null,
        phone ? `SMS consent checkbox: ${smsConsent ? 'checked' : 'not checked'}` : null,
        utmSource ? `UTM Source: ${utmSource}` : null,
        utmMedium ? `UTM Medium: ${utmMedium}` : null,
        utmCampaign ? `UTM Campaign: ${utmCampaign}` : null,
        utmTerm ? `UTM Term: ${utmTerm}` : null,
        utmContent ? `UTM Content: ${utmContent}` : null,
        landingPath ? `Landing Path: ${landingPath}` : null,
        referrer ? `Referrer: ${referrer}` : null,
        message ? `Message:\n${message}` : null,
      ]
        .filter(Boolean)
        .join('\n'),
    };

    if (sendgridApiKey) {
      await sendContactLeadEmail(payload, sendgridApiKey);
    } else if (process.env.NODE_ENV === 'development') {
      console.log('Contact lead email skipped (missing SENDGRID_API_KEY). Payload:', payload);
    } else {
      throw new Error('SENDGRID_API_KEY is required in production for contact form delivery.');
    }

    try {
      await captureLeadForSuperAdmin({
        name,
        email,
        facilityName,
        facilityAddress,
        phone,
        unitCount,
        message,
        smsConsent,
        intent,
        utmSource,
        utmMedium,
        utmCampaign,
        utmTerm,
        utmContent,
        landingPath,
        referrer,
      });
    } catch (leadCaptureError) {
      console.error('Superadmin lead capture failed:', leadCaptureError);
    }

    return NextResponse.json({ success: true });
  } catch (error) {
    console.error('Contact form submit failed:', error);
    return NextResponse.json(
      { message: 'An error occurred. Please try again later.' },
      { status: 500 }
    );
  }
}
