import type { Metadata } from 'next';
import Link from 'next/link';
import { Section } from '@/components/Section';
import { LegalLinksPanel } from '@/components/LegalLinksPanel';
import { SITE_NAME, SUPPORT_EMAIL } from '@/config/site';

export const metadata: Metadata = {
  title: 'Subprocessor List',
  description: `Third-party subprocessors used by ${SITE_NAME} to deliver the Service.`,
  alternates: { canonical: '/subprocessors' },
};

const LAST_UPDATED = 'July 13, 2026';

const SUBPROCESSORS = [
  {
    vendor: 'Google Cloud / Firebase',
    website: 'https://cloud.google.com',
    purpose: 'Cloud infrastructure, authentication, database (Firestore), file storage (Cloud Storage), and serverless functions (Cloud Functions)',
    dataCategories: 'Account data, facility data, tenant data, application logs, authentication tokens',
    location: 'United States (primary)',
  },
  {
    vendor: 'Stripe',
    website: 'https://stripe.com',
    purpose: 'Payment processing, subscription billing, and Stripe Connect for facility payment accounts',
    dataCategories: 'Billing contact information, payment method details (tokenized), transaction records',
    location: 'United States',
  },
  {
    vendor: 'Twilio',
    website: 'https://www.twilio.com',
    purpose: 'SMS message delivery to tenants on behalf of facility operators',
    dataCategories: 'Tenant phone numbers, SMS message content, delivery status logs',
    location: 'United States',
  },
  {
    vendor: 'SendGrid (Twilio)',
    website: 'https://sendgrid.com',
    purpose: 'Transactional and notification email delivery',
    dataCategories: 'Recipient email addresses, email message content, delivery status',
    location: 'United States',
  },
  {
    vendor: 'OpenAI',
    website: 'https://openai.com',
    purpose: 'Optional in-app AI assistant for facility staff questions',
    dataCategories: 'Staff-submitted assistant messages and facility name; no bulk tenant records are transmitted',
    location: 'United States',
  },
  {
    vendor: 'Intuit (QuickBooks Online)',
    website: 'https://quickbooks.intuit.com',
    purpose: 'Optional accounting sync for Customers who connect their own QuickBooks account',
    dataCategories: 'Tenant name, email, phone, and invoice/payment records synced at the Customer\u2019s direction',
    location: 'United States',
  },
];

export default function SubprocessorsPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Subprocessor List</h1>
        <p className="mt-2 text-slate-600">Last updated: {LAST_UPDATED}.</p>
        <p className="mt-2 text-slate-600">
          {SITE_NAME} uses the following third-party service providers ("subprocessors") to deliver the Service. Each subprocessor is bound by data processing agreements and is required to protect data in accordance with applicable law.
        </p>
      </Section>

      <Section tint>
        <div className="prose prose-slate max-w-4xl legal-prose leading-relaxed">

          <h2 className="text-xl font-bold text-slate-900">Current Subprocessors</h2>

          <div className="mt-6 overflow-x-auto rounded-lg border border-slate-200">
            <table className="w-full min-w-[760px] text-sm text-slate-600 border-collapse">
              <thead>
                <tr className="bg-slate-100">
                  <th className="text-left p-3 border border-slate-200 font-semibold">Vendor</th>
                  <th className="text-left p-3 border border-slate-200 font-semibold">Purpose</th>
                  <th className="text-left p-3 border border-slate-200 font-semibold">Data Categories</th>
                  <th className="text-left p-3 border border-slate-200 font-semibold">Location</th>
                </tr>
              </thead>
              <tbody>
                {SUBPROCESSORS.map((sp, i) => (
                  <tr key={sp.vendor} className={i % 2 === 1 ? 'bg-slate-50' : ''}>
                    <td className="p-3 border border-slate-200 font-medium">
                      <a href={sp.website} target="_blank" rel="noopener noreferrer" className="text-primary hover:underline">
                        {sp.vendor}
                      </a>
                    </td>
                    <td className="p-3 border border-slate-200">{sp.purpose}</td>
                    <td className="p-3 border border-slate-200">{sp.dataCategories}</td>
                    <td className="p-3 border border-slate-200">{sp.location}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Updates to This List</h2>
          <p className="text-slate-600 mt-2">
            We will update this list when we add or remove subprocessors. Material changes will be reflected in the "Last updated" date above. If you have questions about a specific subprocessor or require advance notice of changes, contact us at{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Related Policies</h2>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li><Link href="/privacy" className="text-primary hover:underline">Privacy Policy</Link> — how we collect and use data</li>
            <li><Link href="/security" className="text-primary hover:underline">Security Overview</Link> — our security controls</li>
            <li><Link href="/dpa" className="text-primary hover:underline">Data Processing Agreement</Link> — DPA information</li>
          </ul>
          <LegalLinksPanel />
        </div>
      </Section>
    </>
  );
}
