import type { Metadata } from 'next';
import { Section } from '@/components/Section';
import { SITE_NAME, SUPPORT_EMAIL } from '@/config/site';

export const metadata: Metadata = {
  title: 'Data Processing Agreement',
  description: `Data Processing Agreement (DPA) information for ${SITE_NAME} customers.`,
};

const LAST_UPDATED = 'February 26, 2026';

export default function DpaPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Data Processing Agreement</h1>
        <p className="mt-2 text-slate-600">Last updated: {LAST_UPDATED}.</p>
      </Section>

      <Section tint>
        <div className="prose prose-slate max-w-none">

          <h2 className="text-xl font-bold text-slate-900">DPA Available Upon Request</h2>
          <p className="text-slate-600 mt-2">
            {SITE_NAME} acts as a data processor on behalf of Customers (storage facility operators) with respect to the personal data of their tenants and other End Users that Customers input into the Service.
          </p>
          <p className="text-slate-600 mt-2">
            A Data Processing Agreement (DPA) is available upon request for Customers who require one for compliance purposes (e.g., GDPR, CCPA, or contractual requirements). The DPA sets out the terms under which {SITE_NAME} processes personal data on your behalf, including:
          </p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Subject matter and duration of processing</li>
            <li>Nature and purpose of processing</li>
            <li>Types of personal data processed</li>
            <li>Categories of data subjects</li>
            <li>Obligations and rights of the Customer (data controller)</li>
            <li>Subprocessor terms and our current subprocessor list</li>
            <li>Security measures and breach notification obligations</li>
            <li>Data subject rights support</li>
            <li>Data deletion and return upon termination</li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">How to Request a DPA</h2>
          <p className="text-slate-600 mt-2">
            To request a DPA, email us at{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>{' '}
            with the subject line "DPA Request" and include your account email and business name. We will respond within 14 business days.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Related Documents</h2>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li><a href="/privacy" className="text-primary hover:underline">Privacy Policy</a> — how we collect and use data</li>
            <li><a href="/subprocessors" className="text-primary hover:underline">Subprocessor List</a> — third-party processors we use</li>
            <li><a href="/security" className="text-primary hover:underline">Security Overview</a> — our security controls and practices</li>
            <li><a href="/terms" className="text-primary hover:underline">Terms of Service</a> — Customer Data ownership and processing terms</li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Contact</h2>
          <p className="text-slate-600 mt-2">
            Data processing questions:{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>.
          </p>
        </div>
      </Section>
    </>
  );
}
