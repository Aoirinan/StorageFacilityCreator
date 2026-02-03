import type { Metadata } from 'next';
import { Section } from '@/components/Section';
import { CtaButton } from '@/components/CtaButton';
import { A2pSnippet } from '@/components/A2pSnippet';

export const metadata: Metadata = {
  title: 'FAQ',
  description: 'Frequently asked questions about Storage Facility Creator: pricing, SMS messaging, opt-in and opt-out, security, and more.',
};

const FAQ_ITEMS = [
  {
    category: 'General',
    qas: [
      { q: 'Who is it best for?', a: 'Independent self-storage operators who want a simple, flat-rate system without per-unit pricing or expensive onboarding.' },
      { q: 'Can I import tenants from CSV/Excel?', a: 'Yes. You can bulk import tenants and unit data from CSV or Excel.' },
    ],
  },
  {
    category: 'Pricing',
    qas: [
      { q: 'Is there an onboarding fee?', a: 'No. There is no onboarding fee. Flat-rate $75/month with a 30-day trial and first month free.' },
      { q: 'Can I cancel anytime?', a: 'Yes. You can cancel according to the terms of your subscription. No long-term lock-in.' },
    ],
  },
  {
    category: 'Messaging & Consent (SMS)',
    qas: [
      { q: 'Do you send SMS text messages to tenants?', a: 'Yes. If a tenant provides a phone number and opts in, they may receive account-related SMS messages such as payment reminders and important updates.' },
      { q: 'How does opt-in work?', a: 'Tenants must explicitly opt in before receiving SMS. We do not send marketing or non-account SMS without consent.' },
      { q: 'How do tenants opt out? (STOP)', a: 'Tenants can reply STOP to opt out at any time. We process opt-outs and stop sending messages promptly.' },
      { q: 'What if a tenant needs help? (HELP)', a: 'Tenants can reply HELP for assistance. We provide clear support contact information.' },
      { q: 'How often are messages sent? (frequency varies)', a: 'Message frequency varies based on account activity (e.g. reminders, notices). We do not send high-volume marketing blasts. Message & data rates may apply.' },
    ],
  },
  {
    category: 'Security',
    qas: [
      { q: 'How is my data protected?', a: 'We use encryption in transit, role-based access, and activity logs. Data is hosted on reputable cloud infrastructure.' },
    ],
  },
];

export default function FaqPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Frequently asked questions</h1>
        <p className="mt-2 text-lg text-slate-600 max-w-2xl">
          Answers to common questions about pricing, messaging, and security.
        </p>
      </Section>

      {FAQ_ITEMS.map(({ category, qas }) => (
        <Section key={category} tint>
          <h2 className="text-xl font-bold text-slate-900">{category}</h2>
          <ul className="mt-6 space-y-6" role="list">
            {qas.map(({ q, a }) => (
              <li key={q}>
                <h3 className="font-semibold text-slate-900">{q}</h3>
                <p className="mt-2 text-slate-600">{a}</p>
              </li>
            ))}
          </ul>
        </Section>
      ))}

      <Section>
        <h2 className="text-lg font-bold text-slate-900">SMS messaging & consent</h2>
        <div className="mt-3">
          <A2pSnippet />
        </div>
      </Section>

      <Section tint>
        <div className="text-center">
          <CtaButton>Schedule a Demo</CtaButton>
        </div>
      </Section>
    </>
  );
}
