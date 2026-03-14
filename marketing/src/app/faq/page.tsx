import type { Metadata } from 'next';
import Script from 'next/script';
import { Section } from '@/components/Section';
import { CtaButton } from '@/components/CtaButton';
import { A2pSnippet } from '@/components/A2pSnippet';
import { PAGE_OG_IMAGES, PRIMARY_CTA_HREF, SECONDARY_CTA_HREF } from '@/config/site';

export const metadata: Metadata = {
  title: 'FAQ',
  description:
    'Frequently asked questions for self-storage operators evaluating SFC: pricing, setup, messaging, security, e-sign, facilities, integrations, and migration.',
  openGraph: { images: [PAGE_OG_IMAGES.faq] },
  twitter: { images: [PAGE_OG_IMAGES.faq] },
};

const FAQ_ITEMS = [
  {
    category: 'Getting started',
    qas: [
      { q: 'Who is SFC built for?', a: 'SFC is built for independent and multi-facility self-storage operators who want modern operational software without bloated enterprise complexity.' },
      { q: 'Do you offer a free trial?', a: 'Yes. SFC offers a 30-day trial with first-month-free positioning as listed on pricing pages.' },
      { q: 'Is a credit card required to request a demo?', a: 'No. You can request a demo and review fit before committing to a paid subscription.' },
      { q: 'Do you help with setup or migration?', a: 'Yes. Setup and migration guidance is available based on your existing data and workflow complexity.' },
    ],
  },
  {
    category: 'Billing and pricing',
    qas: [
      { q: 'Is SFC priced per facility, per user, or per unit?', a: 'Public pricing is positioned as flat monthly pricing. See the pricing page for current terms and details.' },
      { q: 'Is there an onboarding fee?', a: 'No onboarding fee is included in current public pricing language.' },
      { q: 'Does SFC support autopay?', a: 'Yes. Stripe-backed autopay workflows are supported in product billing flows.' },
      { q: 'Can I manage multiple facilities?', a: 'Yes. Multi-facility workflows are supported and surfaced in product operations and reporting paths.' },
    ],
  },
  {
    category: 'Messaging',
    qas: [
      { q: 'Can SFC send SMS and email reminders?', a: 'Yes. SFC supports account-related SMS and email reminder workflows when configured by facility operators.' },
      { q: 'How is SMS consent handled?', a: 'SMS requires express opt-in. Message frequency varies. Recipients can reply STOP to opt out and HELP for help. Message/data rates may apply.' },
      { q: 'Do you send SMS without consent?', a: 'No. SMS workflows are designed around consent-based communication practices.' },
    ],
  },
  {
    category: 'Security and privacy',
    qas: [
      { q: 'Is my data secure?', a: 'SFC uses practical controls including secure authentication patterns, role-based access, and encrypted transport.' },
      { q: 'What third-party providers does SFC use?', a: 'Core providers in code include Stripe, Twilio, SendGrid, Google Cloud/Firebase, and QuickBooks integration paths.' },
      { q: 'Can I request a DPA?', a: 'Yes. DPA information and request instructions are available on the DPA page.' },
    ],
  },
  {
    category: 'Contracts and operations',
    qas: [
      { q: 'Does SFC support electronic signatures?', a: 'SFC includes e-sign and disclosure workflow support surfaces with a published e-sign disclosure page.' },
      { q: 'Does SFC help with delinquent accounts and lien workflows?', a: 'Yes. Delinquency and lien-support workflows are part of SFC’s operational feature set.' },
      { q: 'Does SFC include a tenant portal?', a: 'Tenant portal access flows are available. Confirm exact capabilities and rollout scope during your implementation review.' },
      { q: 'Does SFC support online rentals or move-ins?', a: 'Online rental/move-in workflow surfaces are present. Confirm production fit for your process during demo and onboarding planning.' },
    ],
  },
  {
    category: 'Integrations',
    qas: [
      { q: 'Does SFC integrate with QuickBooks?', a: 'Yes. QuickBooks integration callables and UI flows are present in the codebase and support accounting sync workflows.' },
      { q: 'Are integrations available now?', a: 'Current integration surface includes Stripe, Twilio, SendGrid, and QuickBooks. Additional integrations can be discussed based on roadmap priorities.' },
    ],
  },
];

export default function FaqPage() {
  const faqSchema = {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    mainEntity: FAQ_ITEMS.flatMap((category) =>
      category.qas.map((qa) => ({
        '@type': 'Question',
        name: qa.q,
        acceptedAnswer: { '@type': 'Answer', text: qa.a },
      })),
    ),
  };

  return (
    <>
      <Script
        id="faq-jsonld"
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(faqSchema) }}
      />
      <Section className="pt-10 pb-6">
        <span className="eyebrow">Buyer Questions</span>
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Frequently asked questions</h1>
        <p className="mt-2 text-lg text-slate-600 max-w-2xl">
          Buyer-focused answers on pricing, operations, messaging, security, and integrations.
        </p>
      </Section>

      {FAQ_ITEMS.map(({ category, qas }, index) => (
        <Section key={category} tint={index % 2 === 0}>
          <h2 className="text-xl font-bold text-slate-900">{category}</h2>
          <ul className="mt-6 space-y-6" role="list">
            {qas.map(({ q, a }) => (
              <li key={q} className="rounded-xl border border-slate-200 bg-white p-4 sm:p-5">
                <h3 className="font-semibold text-slate-900">{q}</h3>
                <p className="mt-2 text-slate-600 leading-relaxed">{a}</p>
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
        <p className="mt-3 text-sm text-slate-600">
          Review full details in <a className="text-primary hover:underline" href="/sms-terms">SMS Terms</a> and{' '}
          <a className="text-primary hover:underline" href="/privacy">Privacy Policy</a>.
        </p>
      </Section>

      <Section tint>
        <div className="text-center flex flex-wrap justify-center gap-3">
          <CtaButton href={PRIMARY_CTA_HREF} />
          <CtaButton href={SECONDARY_CTA_HREF} variant="secondary" />
        </div>
        <p className="mt-4 text-center text-sm text-slate-600">
          For implementation planning details, see <a href="/migration" className="text-primary hover:underline">Migration</a>.
        </p>
      </Section>
    </>
  );
}
