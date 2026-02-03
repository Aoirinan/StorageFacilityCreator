import Link from 'next/link';
import {
  HERO_HEADLINE,
  HERO_SUBHEADLINE,
  TRUST_STRIP_ITEMS,
  PRICE_MONTHLY,
  TRIAL_LINE,
  APP_LOGIN_URL,
} from '@/config/site';
import { Section } from '@/components/Section';
import { CtaButton } from '@/components/CtaButton';
import { DemoFrame } from '@/components/DemoFrame';
import { A2pSnippet } from '@/components/A2pSnippet';

const KEY_FEATURES = [
  {
    title: 'Tenant & Unit Management',
    description: 'Track tenants and units across facilities. Quick add or bulk import from CSV/Excel.',
    icon: '👥',
  },
  {
    title: 'Billing & Payment Tracking',
    description: 'Recurring charges, one-time payments, and payment history in one place.',
    icon: '💰',
  },
  {
    title: 'Automated Reminders (SMS/Email)',
    description: 'Opt-in reminders for payments and notices. Message frequency varies; STOP/HELP supported.',
    icon: '📬',
  },
  {
    title: 'Reporting & Delinquency',
    description: 'Past-due views, occupancy rates, and activity logs to stay on top of operations.',
    icon: '📊',
  },
];

const HOW_IT_WORKS = [
  {
    step: 1,
    title: 'Set up your facility',
    description: 'Add units, rates, and settings for each location.',
  },
  {
    step: 2,
    title: 'Add tenants',
    description: 'Quick add or import from CSV/Excel.',
  },
  {
    step: 3,
    title: 'Automate reminders & track payments',
    description: 'Opt-in SMS/email reminders, notices, and reporting.',
  },
];

const FAQ_PREVIEW = [
  { q: 'Do you send SMS text messages to tenants?', a: 'Yes. Tenants who opt in may receive account-related SMS (e.g. payment reminders). Message frequency varies. Reply STOP to opt out, HELP for help.' },
  { q: 'Is there an onboarding fee?', a: 'No. Flat-rate $75/month with no onboarding fee.' },
  { q: 'Can I import tenants from CSV/Excel?', a: 'Yes. Bulk import is supported.' },
];

export default function HomePage() {
  return (
    <>
      {/* Hero */}
      <Section className="pt-8 sm:pt-12 pb-12 sm:pb-16">
        <div className="grid lg:grid-cols-2 gap-10 lg:gap-16 items-center">
          <div>
            <h1 className="text-3xl sm:text-4xl lg:text-5xl font-bold text-slate-900 tracking-tight">
              {HERO_HEADLINE}
            </h1>
            <p className="mt-4 text-lg text-slate-600 max-w-xl">
              {HERO_SUBHEADLINE}
            </p>
            <div className="mt-8 flex flex-wrap gap-4">
              <CtaButton href="/contact" primary>Schedule a Demo</CtaButton>
              <a
                href={APP_LOGIN_URL}
                className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-5 py-2.5 text-sm font-medium text-slate-700 hover:bg-slate-50 transition-colors"
              >
                Login
              </a>
            </div>
          </div>
          <div className="order-first lg:order-none">
            <DemoFrame />
          </div>
        </div>
      </Section>

      {/* Trust strip */}
      <div className="border-y border-slate-200 bg-slate-50/50">
        <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8 py-4">
          <ul className="flex flex-wrap justify-center gap-x-8 gap-y-2 text-sm text-slate-700" role="list">
            {TRUST_STRIP_ITEMS.map((item) => (
              <li key={item} className="flex items-center gap-2">
                <span className="text-primary" aria-hidden>✓</span>
                {item}
              </li>
            ))}
          </ul>
        </div>
      </div>

      {/* Key Features */}
      <Section tint id="features">
        <h2 className="text-2xl sm:text-3xl font-bold text-slate-900 text-center">Key Features</h2>
        <p className="mt-2 text-slate-600 text-center max-w-2xl mx-auto">
          Built for independent operators. No per-unit pricing.
        </p>
        <ul className="mt-12 grid sm:grid-cols-2 lg:grid-cols-4 gap-6" role="list">
          {KEY_FEATURES.map((f) => (
            <li key={f.title} className="rounded-xl bg-white p-6 shadow-sm border border-slate-100">
              <span className="text-2xl" aria-hidden>{f.icon}</span>
              <h3 className="mt-3 font-semibold text-slate-900">{f.title}</h3>
              <p className="mt-2 text-sm text-slate-600">{f.description}</p>
            </li>
          ))}
        </ul>
        <div className="mt-10 text-center">
          <Link href="/features" className="text-primary font-medium hover:underline">
            See all features →
          </Link>
        </div>
      </Section>

      {/* How it works */}
      <Section>
        <h2 className="text-2xl sm:text-3xl font-bold text-slate-900 text-center">How it works</h2>
        <p className="mt-2 text-slate-600 text-center max-w-2xl mx-auto">
          Get started in three steps.
        </p>
        <div className="mt-12 grid md:grid-cols-3 gap-8">
          {HOW_IT_WORKS.map(({ step, title, description }) => (
            <div key={step} className="text-center">
              <span className="inline-flex h-12 w-12 items-center justify-center rounded-full bg-primary text-white font-semibold text-lg">
                {step}
              </span>
              <h3 className="mt-4 font-semibold text-slate-900">{title}</h3>
              <p className="mt-2 text-slate-600 text-sm">{description}</p>
            </div>
          ))}
        </div>
        <div className="mt-12 flex justify-center">
          <DemoFrame />
        </div>
      </Section>

      {/* Pricing preview */}
      <Section tint>
        <h2 className="text-2xl sm:text-3xl font-bold text-slate-900 text-center">Simple pricing</h2>
        <p className="mt-2 text-slate-600 text-center max-w-2xl mx-auto">
          ${PRICE_MONTHLY}/month flat rate. {TRIAL_LINE}.
        </p>
        <div className="mt-8 flex flex-col items-center">
          <CtaButton href="/pricing">View pricing</CtaButton>
        </div>
      </Section>

      {/* Security preview */}
      <Section>
        <h2 className="text-2xl sm:text-3xl font-bold text-slate-900 text-center">Security & privacy</h2>
        <p className="mt-2 text-slate-600 text-center max-w-2xl mx-auto">
          Secure authentication, role-based access, and activity logs. We take data protection seriously.
        </p>
        <div className="mt-8 flex flex-col items-center">
          <Link href="/security" className="text-primary font-medium hover:underline">
            Learn more →
          </Link>
        </div>
      </Section>

      {/* FAQ preview */}
      <Section tint>
        <h2 className="text-2xl sm:text-3xl font-bold text-slate-900 text-center">Frequently asked questions</h2>
        <ul className="mt-8 max-w-2xl mx-auto space-y-6" role="list">
          {FAQ_PREVIEW.map(({ q, a }) => (
            <li key={q}>
              <h3 className="font-semibold text-slate-900">{q}</h3>
              <p className="mt-1 text-slate-600 text-sm">{a}</p>
            </li>
          ))}
        </ul>
        <div className="mt-8 text-center">
          <Link href="/faq" className="text-primary font-medium hover:underline">
            More FAQs →
          </Link>
        </div>
      </Section>

      {/* A2P brief on home */}
      <Section>
        <div className="max-w-2xl">
          <h2 className="text-lg font-semibold text-slate-900">SMS messaging</h2>
          <A2pSnippet brief />
        </div>
      </Section>

      {/* Final CTA */}
      <Section className="bg-primary text-white">
        <div className="text-center max-w-2xl mx-auto">
          <h2 className="text-2xl sm:text-3xl font-bold">Ready to try it?</h2>
          <p className="mt-2 text-blue-100">
            Schedule a demo. No credit card required. We’ll walk you through setup.
          </p>
          <div className="mt-8">
            <Link
              href="/contact"
              className="inline-flex items-center justify-center rounded-lg bg-white px-5 py-2.5 text-sm font-medium text-primary hover:bg-blue-50 transition-colors"
            >
              Schedule a Demo
            </Link>
          </div>
        </div>
      </Section>
    </>
  );
}
