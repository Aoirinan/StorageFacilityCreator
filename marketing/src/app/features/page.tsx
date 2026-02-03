import type { Metadata } from 'next';
import { Section } from '@/components/Section';
import { CtaButton } from '@/components/CtaButton';

export const metadata: Metadata = {
  title: 'Features',
  description:
    'Tenant and unit management, billing and payments, automated SMS/email reminders, reporting and delinquency tools for self-storage.',
};

const FEATURES = [
  {
    title: 'Tenant & Unit Management',
    bullets: [
      'Add tenants and assign units per facility.',
      'Quick add or bulk import from CSV/Excel.',
      'Track move-in, move-out, and unit status.',
      'Unit list and map editor for visual layout.',
    ],
  },
  {
    title: 'Billing & Payment Tracking',
    bullets: [
      'Recurring charges and one-time fees.',
      'Payment history and ledger per tenant.',
      'Track deposits and refunds.',
      'Billing history and payment reports.',
    ],
  },
  {
    title: 'Automated Reminders (SMS/Email)',
    bullets: [
      'Opt-in required for SMS. Message frequency varies.',
      'Payment reminders and notices via SMS and email.',
      'Reply STOP to opt out, HELP for help. Message & data rates may apply.',
      'Configurable templates and timing.',
    ],
  },
  {
    title: 'Late Fees & Notices',
    bullets: [
      'Late fees and delinquency automation.',
      'Notices and reminders for past-due accounts.',
      'Lien and lock-out workflow support.',
    ],
  },
  {
    title: 'Reporting & Delinquency',
    bullets: [
      'Past-due dashboard and occupancy rates.',
      'Revenue and tenant counts by facility.',
      'Activity logs and audit trails.',
    ],
  },
  {
    title: 'Security & Activity Logs',
    bullets: [
      'Role-based access and least-privilege controls.',
      'Activity logs for accountability.',
      'Secure authentication.',
    ],
  },
];

export default function FeaturesPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Features</h1>
        <p className="mt-2 text-lg text-slate-600 max-w-2xl">
          Everything you need to run your self-storage facility—tenant and unit management, billing, payments, and opt-in messaging.
        </p>
      </Section>

      {FEATURES.map((f, i) => (
        <Section key={f.title} tint={i % 2 === 1}>
          <h2 className="text-xl font-bold text-slate-900">{f.title}</h2>
          <ul className="mt-4 space-y-2 text-slate-600" role="list">
            {f.bullets.map((b) => (
              <li key={b} className="flex gap-2">
                <span className="text-primary shrink-0" aria-hidden>•</span>
                {b}
              </li>
            ))}
          </ul>
        </Section>
      ))}

      <Section>
        <div className="text-center">
          <CtaButton>Schedule a Demo</CtaButton>
        </div>
      </Section>
    </>
  );
}
