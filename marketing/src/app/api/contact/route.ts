import { NextRequest, NextResponse } from 'next/server';
import { SUPPORT_EMAIL } from '@/config/site';

export async function POST(request: NextRequest) {
  try {
    const body = await request.json();
    const name = String(body.name ?? '').trim();
    const email = String(body.email ?? '').trim();
    const facilityName = String(body.facilityName ?? '').trim();
    const phone = String(body.phone ?? '').trim();
    const unitCount = String(body.unitCount ?? '').trim();
    const message = String(body.message ?? '').trim();

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

    // In production, send email via your provider (SendGrid, Resend, etc.).
    // For now we log and return success. Set CONTACT_NOTIFY_EMAIL to receive notifications.
    const notifyEmail = process.env.CONTACT_NOTIFY_EMAIL || SUPPORT_EMAIL;
    const payload = {
      to: notifyEmail,
      subject: `Demo request: ${facilityName}`,
      body: [
        `Name: ${name}`,
        `Email: ${email}`,
        `Facility: ${facilityName}`,
        phone ? `Phone: ${phone}` : null,
        unitCount ? `Units: ${unitCount}` : null,
        message ? `Message:\n${message}` : null,
      ]
        .filter(Boolean)
        .join('\n'),
    };

    // If you add a mailer (e.g. Resend), call it here:
    // await sendEmail(payload);
    if (process.env.NODE_ENV === 'development') {
      // eslint-disable-next-line no-console
      console.log('Demo request:', payload);
    }

    return NextResponse.json({ success: true });
  } catch {
    return NextResponse.json(
      { message: 'An error occurred. Please try again later.' },
      { status: 500 }
    );
  }
}
