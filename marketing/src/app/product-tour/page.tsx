import type { Metadata } from 'next';
import Link from 'next/link';
import { DemoFrame } from '@/components/DemoFrame';
import { Section } from '@/components/Section';
import { PageCtaBand } from '@/components/PageCtaBand';
import { EXTRA_DEMO_IMAGES, PAGE_OG_IMAGES } from '@/config/site';

export const metadata: Metadata = {
  title: 'Product Tour',
  description:
    'Take a guided product tour of SFC with real screenshots and practical workflow highlights for self-storage operations.',
  openGraph: { images: [PAGE_OG_IMAGES['product-tour']] },
  twitter: { images: [PAGE_OG_IMAGES['product-tour']] },
};

const highlights = [
  'Dashboard visibility for occupancy and financial operations',
  'Tenant account records with billing and communication context',
  'Unit and facility management workflows',
  'Messaging and delinquency support workflows',
  'Contracts and e-sign related process support',
];

const tourSteps = [
  {
    title: 'Dashboard and portfolio visibility',
    value: 'Track occupancy, balances, and action items from one operating view.',
  },
  {
    title: 'Tenant records and account history',
    value: 'Review billing, payment, and communications context before taking action.',
  },
  {
    title: 'Billing, notices, and delinquency operations',
    value: 'Support recurring charges, reminders, and past-due workflow follow-up.',
  },
  {
    title: 'Integrations and downstream workflows',
    value: 'Connect Stripe, Twilio, SendGrid, and QuickBooks where configured.',
  },
];

export default function ProductTourPage() {
  return (
    <>
      <Section className="pt-10 pb-6">
        <span className="eyebrow">Visual Walkthrough</span>
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Product tour</h1>
        <p className="mt-2 text-lg text-slate-600 max-w-3xl">
          Explore core SFC workflows through product screenshots and operator-focused feature callouts.
        </p>
      </Section>

      <Section tint>
        <ul className="space-y-2.5 text-slate-700 leading-relaxed">
          {highlights.map((item) => (
            <li key={item}>• {item}</li>
          ))}
        </ul>
        <div className="mt-6 grid sm:grid-cols-2 gap-4">
          {tourSteps.map((step) => (
            <article key={step.title} className="card-surface p-4">
              <h2 className="font-semibold text-slate-900">{step.title}</h2>
              <p className="mt-2 text-sm text-slate-600">{step.value}</p>
            </article>
          ))}
        </div>
      </Section>

      <Section>
        <p className="mb-6 text-sm text-slate-600">
          Compare platform fit on <Link href="/compare" className="text-primary hover:underline">Compare Options</Link>{' '}
          or review provider details on <Link href="/integrations" className="text-primary hover:underline">Integrations</Link>.
        </p>
        <div className="grid sm:grid-cols-2 lg:grid-cols-3 gap-4 sm:gap-6">
          {EXTRA_DEMO_IMAGES.map((image) => (
            <DemoFrame key={image.src} src={image.src} alt={image.alt} />
          ))}
          {EXTRA_DEMO_IMAGES.length === 0 && (
            <DemoFrame alt="Storage Facility Creator product screenshot" />
          )}
        </div>
      </Section>

      <Section tint>
        <PageCtaBand title="Want a guided walkthrough?" subtitle="Book a demo and we will tailor the walkthrough to your facility operations." />
      </Section>
    </>
  );
}
