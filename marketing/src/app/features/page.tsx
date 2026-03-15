import type { Metadata } from 'next';
import Link from 'next/link';
import { Section } from '@/components/Section';
import { PageCtaBand } from '@/components/PageCtaBand';
import { DemoFrame } from '@/components/DemoFrame';
import { HERO_IMAGE_PATH, PAGE_OG_IMAGES } from '@/config/site';

export const metadata: Metadata = {
  title: 'Features',
  description:
    'Explore SFC features for self-storage operations: tenant and unit workflows, billing, payments, delinquency management, messaging, reporting, security, and integrations.',
  openGraph: { images: [PAGE_OG_IMAGES.features] },
  twitter: { images: [PAGE_OG_IMAGES.features] },
};

const FEATURE_GROUPS = [
  {
    title: 'Operations',
    summary: 'Run day-to-day facility workflows with clear visibility and fewer manual handoffs.',
    bullets: [
      'Tenant profiles with account history and core contact context.',
      'Unit tracking with status visibility and occupancy awareness.',
      'Move-in/move-out workflows and day-to-day account operations.',
      'Facility map and visual unit management for easier oversight.',
    ],
  },
  {
    title: 'Billing and payments',
    summary: 'Maintain predictable billing operations and cleaner ledgers across facilities.',
    bullets: [
      'Recurring charges and one-time fees with ledger tracking.',
      'Stripe-powered payment workflows and payment history.',
      'Autopay support where enabled.',
      'Deposit and transaction records tied to tenant accounts.',
    ],
  },
  {
    title: 'Delinquency management',
    summary: 'Handle past-due accounts with practical, operator-friendly workflows.',
    bullets: [
      'Past-due dashboards and delinquency tracking.',
      'Late notices and collections-oriented account visibility.',
      'Lien and overlock workflow support where applicable.',
    ],
  },
  {
    title: 'Messaging and notifications',
    summary: 'Reach tenants through account-related communications with consent-aware messaging.',
    bullets: [
      'SMS and email reminders for billing and account updates.',
      'Opt-in required for SMS; STOP/HELP workflows supported.',
      'Message frequency varies and message/data rates may apply.',
      'Template-friendly communication workflows for teams.',
    ],
  },
  {
    title: 'Contracts and documents',
    summary: 'Support digital records and disclosures as part of your operating process.',
    bullets: [
      'Contract and disclosure workflows with e-sign support surfaces.',
      'Document access tied to account operations.',
      'Policy-linked legal disclosure pages for transparency.',
    ],
  },
  {
    title: 'Reporting and visibility',
    summary: 'Keep operators aligned with actionable reporting and operational signals.',
    bullets: [
      'Activity logs and operational accountability.',
      'Occupancy and revenue visibility by facility.',
      'Workflow-oriented operational reporting.',
    ],
  },
  {
    title: 'Security and permissions',
    summary: 'Use practical controls designed for SaaS operations, teams, and data stewardship.',
    bullets: [
      'Role-based access controls and secure authentication.',
      'Cloud-hosted infrastructure with transport security.',
      'Published security/privacy/legal pages for buyer trust.',
    ],
  },
  {
    title: 'Integrations',
    summary: 'Connect core financial and communications workflows to proven provider ecosystems.',
    bullets: [
      'Stripe for payment processing.',
      'Twilio for SMS delivery.',
      'SendGrid for email workflows.',
      'QuickBooks integration for accounting sync paths.',
    ],
  },
];

export default function FeaturesPage() {
  return (
    <>
      <Section className="pt-10 pb-6">
        <span className="eyebrow">Feature Coverage</span>
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Features</h1>
        <p className="mt-2 text-lg text-slate-600 max-w-2xl">
          A complete operations platform for self-storage teams: facility workflows, billing, messaging, delinquency,
          reporting, and integrations.
        </p>
        <div className="mt-8">
          <DemoFrame src={HERO_IMAGE_PATH} alt="Storage Facility Creator operations dashboard screenshot" />
        </div>
      </Section>

      {FEATURE_GROUPS.map((f, i) => (
        <Section key={f.title} tint={i % 2 === 1}>
          <div className="max-w-4xl">
            <h2 className="text-xl font-bold text-slate-900">{f.title}</h2>
            <p className="mt-2 text-slate-600 leading-relaxed">{f.summary}</p>
            <ul className="mt-4 grid sm:grid-cols-2 gap-2.5 text-slate-600 leading-relaxed" role="list">
            {f.bullets.map((b) => (
              <li key={b} className="card-surface flex gap-2 p-3">
                <span className="text-primary shrink-0" aria-hidden>•</span>
                {b}
              </li>
            ))}
            </ul>
          </div>
        </Section>
      ))}

      <Section>
        <div className="mb-8 rounded-xl border border-slate-200 p-4 sm:p-5 text-sm text-slate-700 leading-relaxed">
          Compare feature depth and positioning on the <Link href="/compare" className="text-primary hover:underline">Compare Options</Link>{' '}
          page, or review pricing on <Link href="/pricing" className="text-primary hover:underline">Pricing</Link>.
        </div>
        <PageCtaBand title="See these workflows in your context" subtitle="Book a demo and we will map features to your operating process." />
      </Section>
    </>
  );
}
