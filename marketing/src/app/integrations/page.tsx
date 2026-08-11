import type { Metadata } from 'next';
import Link from 'next/link';
import { Section } from '@/components/Section';
import { PageCtaBand } from '@/components/PageCtaBand';

export const metadata: Metadata = {
  title: 'Integrations',
  description:
    'SFC integrations: Stripe payments, Twilio messaging, SendGrid email workflows, and QuickBooks accounting sync.',
  alternates: { canonical: '/integrations' },
};

const INTEGRATIONS = [
  {
    name: 'Stripe',
    purpose: 'Payment processing and billing workflows',
    details:
      'Supports payment collection and autopay-related workflows in product billing surfaces.',
  },
  {
    name: 'Twilio',
    purpose: 'SMS delivery',
    details:
      'Supports account-related SMS messaging workflows with consent-aware STOP/HELP handling.',
  },
  {
    name: 'SendGrid',
    purpose: 'Email delivery',
    details:
      'Supports transactional and notification email flows for product and operational messaging.',
  },
  {
    name: 'QuickBooks',
    purpose: 'Accounting sync workflows',
    details:
      'Supports facility-level connection and accounting sync paths for invoices and payments.',
  },
];

export default function IntegrationsPage() {
  return (
    <>
      <Section className="pt-10 pb-6">
        <span className="eyebrow">Connected Services</span>
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Integrations</h1>
        <p className="mt-2 text-lg text-slate-600 max-w-3xl">
          SFC focuses on practical integrations that matter most to storage operators today.
        </p>
      </Section>

      <Section tint>
        <div className="grid sm:grid-cols-2 gap-4 sm:gap-6">
          {INTEGRATIONS.map((item) => (
            <article key={item.name} className="card-surface p-5 sm:p-6">
              <h2 className="text-xl font-semibold text-slate-900">{item.name}</h2>
              <p className="mt-2 text-sm font-medium text-primary">{item.purpose}</p>
              <p className="mt-2 text-sm text-slate-600">{item.details}</p>
            </article>
          ))}
        </div>
      </Section>

      <Section>
        <h2 className="text-2xl font-bold text-slate-900">Integration direction</h2>
        <p className="mt-3 text-slate-600 max-w-3xl">
          SFC continues to prioritize integrations that reduce manual work across operations, accounting, and tenant
          communications. If you need a specific integration, discuss requirements during demo and onboarding planning.
        </p>
        <p className="mt-3 text-sm text-slate-600">
          Need a side-by-side fit check against other platforms? See{' '}
          <Link href="/compare" className="text-primary hover:underline font-medium">the full comparison</Link>{' '}
          or review workflow coverage on{' '}
          <Link href="/product-tour" className="text-primary hover:underline">Product Tour</Link>.
        </p>
      </Section>

      <Section tint>
        <div className="mx-auto max-w-3xl text-center">
          <h2 className="text-2xl font-bold text-slate-900">How does this compare?</h2>
          <p className="mt-3 text-slate-600">
            See how SFC&rsquo;s integration set stacks up against the other major self-storage management
            platforms — factual, side-by-side, and kept up to date.
          </p>
          <div className="mt-5">
            <Link
              href="/compare"
              className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-5 py-2.5 text-sm font-semibold text-slate-700 hover:bg-slate-50 transition-colors"
            >
              See how SFC compares →
            </Link>
          </div>
        </div>
      </Section>

      <Section>
        <PageCtaBand title="Want to confirm integration fit?" subtitle="Book a demo and we can walk through your current tools and workflow needs." />
      </Section>
    </>
  );
}
