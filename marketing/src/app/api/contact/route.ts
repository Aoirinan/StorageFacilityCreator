import { NextRequest, NextResponse } from 'next/server';
import { SUPPORT_EMAIL } from '@/config/site';

const SENDGRID_API_URL = 'https://api.sendgrid.com/v3/mail/send';

type ContactLeadPayload = {
  to: string;
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
      personalizations: [{ to: [{ email: payload.to }], subject: payload.subject }],
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

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const name = String(body.name ?? '').trim();
    const email = String(body.email ?? '').trim();
    const facilityName = String(body.facilityName ?? '').trim();
    const phone = String(body.phone ?? '').trim();
    const unitCount = String(body.unitCount ?? '').trim();
    const message = String(body.message ?? '').trim();
    const smsConsent = String(body.smsConsent ?? '').trim().toLowerCase() === 'on';
    const intent = String(body.intent ?? 'demo').trim().toLowerCase() === 'trial' ? 'trial' : 'demo';

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

    const notifyEmail = process.env.CONTACT_NOTIFY_EMAIL || SUPPORT_EMAIL;
    const sendgridApiKey = process.env.SENDGRID_API_KEY;
    const fromEmail = process.env.CONTACT_FROM_EMAIL || SUPPORT_EMAIL;
    const leadType = intent === 'trial' ? 'Trial request' : 'Demo request';
    const payload = {
      to: notifyEmail,
      from: fromEmail,
      replyTo: email,
      subject: `${leadType}: ${facilityName}`,
      body: [
        `Intent: ${leadType}`,
        `Name: ${name}`,
        `Email: ${email}`,
        `Facility: ${facilityName}`,
        phone ? `Phone: ${phone}` : null,
        unitCount ? `Units: ${unitCount}` : null,
        phone ? `SMS consent checkbox: ${smsConsent ? 'checked' : 'not checked'}` : null,
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

    return NextResponse.json({ success: true });
  } catch (error) {
    console.error('Contact form submit failed:', error);
    return NextResponse.json(
      { message: 'An error occurred. Please try again later.' },
      { status: 500 }
    );
  }
}
