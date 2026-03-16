import Link from 'next/link';
import Script from 'next/script';
import {
  HERO_IMAGE_PATH,
  HERO_HEADLINE,
  HERO_SUBHEADLINE,
  MICROCOPY_POINTS,
  TRUST_STRIP_ITEMS,
  PRIMARY_CTA_HREF,
  PRIMARY_CTA_LABEL,
  SECONDARY_CTA_HREF,
  SECONDARY_CTA_LABEL,
  TERTIARY_CTA_HREF,
  TERTIARY_CTA_LABEL,
  SITE_DOMAIN,
  SITE_NAME,
  SUPPORT_EMAIL,
} from '@/config/site';
import { Section } from '@/components/Section';
import { CtaButton } from '@/components/CtaButton';
import { DemoFrame } from '@/components/DemoFrame';
import { A2pSnippet } from '@/components/A2pSnippet';

const KEY_FEATURES = [
  {
    title: 'Tenant management',
    description: 'Centralized tenant records with billing history, communication context, and account status.',
    icon: 'TM',
  },
  {
    title: 'Unit management',
    description: 'Track occupancy, status, and availability by facility with clear operational visibility.',
    icon: 'UM',
  },
  {
    title: 'Billing and ledgers',
    description: 'Recurring charges, one-time fees, and full ledger transparency by tenant.',
    icon: 'BL',
  },
  {
    title: 'Payments and autopay',
    description: 'Stripe-powered payments and autopay controls to reduce collections friction.',
    icon: 'PA',
  },
  {
    title: 'Delinquency workflows',
    description: 'Past-due workflows, notices, and overlock/lien support for practical collections operations.',
    icon: 'DW',
  },
  {
    title: 'Messaging and reporting',
    description: 'Opt-in SMS/email reminders, activity logs, and operator-focused reporting.',
    icon: 'MR',
  },
];

const HOW_IT_WORKS = [
  {
    step: 1,
    title: 'Set up your facility',
    description: 'Configure facilities, rates, and operational settings.',
  },
  {
    step: 2,
    title: 'Add units and tenants',
    description: 'Import data or onboard directly with clear account structure.',
  },
  {
    step: 3,
    title: 'Automate billing and reminders',
    description: 'Reduce manual follow-up with recurring billing and opt-in messaging.',
  },
  {
    step: 4,
    title: 'Run operations with confidence',
    description: 'Manage delinquencies, reporting, and integrations from one place.',
  },
];

const HOW_IT_WORKS_SCREENSHOTS = [
  {
    src: '/how-it-works-facility-setup.png',
    title: 'Facility setup',
    description: 'Configure facility details and operating basics in one guided form.',
    alt: 'Storage Facility Creator facility setup screen',
  },
  {
    src: '/how-it-works-tenants.png',
    title: 'Tenant and unit visibility',
    description: 'Track tenant records, unit assignments, rates, and balances from one list.',
    alt: 'Storage Facility Creator tenants list screen',
  },
  {
    src: '/how-it-works-autopay.png',
    title: 'Autopay controls',
    description: 'Manage payment methods and autopay status with full activity history.',
    alt: 'Storage Facility Creator autopay management screen',
  },
  {
    src: '/how-it-works-delinquency.png',
    title: 'Delinquency workflows',
    description: 'Review overdue balances and drive next-step collection actions.',
    alt: 'Storage Facility Creator delinquency overview screen',
  },
];

const TOUR_CARDS = [
  { title: 'Dashboard overview', description: 'Monitor occupancy, balances, and action items quickly.' },
  { title: 'Tenant records', description: 'View account, payment, and communication history in context.' },
  { title: 'Billing and ledger', description: 'Track invoices, payments, and account-level balances.' },
  { title: 'Facility map and units', description: 'Manage visual unit layout and status by location.' },
  { title: 'Contracts and e-sign', description: 'Support digital document workflows and disclosures.' },
  { title: 'Integrations', description: 'Use practical integrations like Stripe, Twilio, SendGrid, and QuickBooks.' },
];

const DIFFERENTIATORS = [
  'Flat monthly pricing without bloated enterprise packaging.',
  'Operator-first workflows built for real storage operations.',
  'Compliance transparency with published legal/compliance pages.',
  'Practical integrations supporting day-to-day billing and communications.',
  'Clean modern interface designed for independent and multi-facility teams.',
];

const COMPLIANCE_LINKS = [
  { href: '/sms-terms', label: 'SMS Terms' },
  { href: '/esign-disclosure', label: 'E-Sign Disclosure' },
  { href: '/privacy', label: 'Privacy Policy' },
  { href: '/subprocessors', label: 'Subprocessors' },
  { href: '/dpa', label: 'DPA Availability' },
];

export default function HomePage() {
  const orgSchema = {
    '@context': 'https://schema.org',
    '@type': 'Organization',
    name: SITE_NAME,
    url: SITE_DOMAIN,
    email: SUPPORT_EMAIL,
  };

  const appSchema = {
    '@context': 'https://schema.org',
    '@type': 'SoftwareApplication',
    name: SITE_NAME,
    applicationCategory: 'BusinessApplication',
    operatingSystem: 'Web',
    description: HERO_SUBHEADLINE,
    offers: {
      '@type': 'Offer',
      price: '75',
      priceCurrency: 'USD',
    },
  };

  return (
    <>
      <Script id="org-jsonld" type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(orgSchema) }} />
      <Script id="software-jsonld" type="application/ld+json" dangerouslySetInnerHTML={{ __html: JSON.stringify(appSchema) }} />
      {/* Hero */}
      <Section className="pt-8 sm:pt-12 pb-12 sm:pb-16">
        <div className="grid lg:grid-cols-2 gap-10 lg:gap-16 items-center">
          <div>
            <span className="eyebrow">Self-Storage SaaS</span>
            <h1 className="mt-3 text-3xl sm:text-4xl lg:text-5xl font-bold text-slate-900 tracking-tight">
              {HERO_HEADLINE}
            </h1>
            <p className="mt-4 text-lg text-slate-600 max-w-xl">
              {HERO_SUBHEADLINE}
            </p>
            <ul className="mt-4 text-sm text-slate-600 flex flex-wrap gap-x-4 gap-y-1" role="list">
              {MICROCOPY_POINTS.map((item) => (
                <li key={item}>• {item}</li>
              ))}
            </ul>
            <div className="mt-8 flex flex-wrap gap-3">
              <CtaButton href={PRIMARY_CTA_HREF}>{PRIMARY_CTA_LABEL}</CtaButton>
              <CtaButton href={SECONDARY_CTA_HREF} variant="secondary">
                {SECONDARY_CTA_LABEL}
              </CtaButton>
              <CtaButton href={TERTIARY_CTA_HREF} variant="tertiary">
                {TERTIARY_CTA_LABEL}
              </CtaButton>
            </div>
            <p className="mt-4 text-sm text-slate-500">
              Practical onboarding, transparent policy pages, and production integrations for serious operators.
            </p>
          </div>
          <div className="order-first lg:order-0">
            <DemoFrame src={HERO_IMAGE_PATH} alt="Storage Facility Creator dashboard screenshot" priority />
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
        <h2 className="text-2xl sm:text-3xl font-bold text-slate-900 text-center">Everything you need to run your facility</h2>
        <p className="mt-2 text-slate-600 text-center max-w-2xl mx-auto">
          Tenant and unit management, billing, late notices, autopay, and reporting—built for independent and multi-site operators.
        </p>
        <ul className="mt-12 grid sm:grid-cols-2 lg:grid-cols-3 gap-6" role="list">
          {KEY_FEATURES.map((f) => (
            <li key={f.title} className="rounded-xl bg-white p-6 shadow-xs border border-slate-100">
              <span
                className="inline-flex h-9 w-9 items-center justify-center rounded-lg bg-blue-50 text-xs font-semibold text-primary"
                aria-hidden
              >
                {f.icon}
              </span>
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

      {/* Product tour */}
      <Section>
        <h2 className="text-2xl sm:text-3xl font-bold text-slate-900 text-center">Product tour highlights</h2>
        <p className="mt-2 text-slate-600 text-center max-w-2xl mx-auto">
          A guided look at the workflows operators use most.
        </p>
        <div className="mt-10 grid md:grid-cols-2 lg:grid-cols-3 gap-6">
          {TOUR_CARDS.map(({ title, description }) => (
            <article key={title} className="rounded-xl border border-slate-200 bg-white p-5">
              <h3 className="font-semibold text-slate-900">{title}</h3>
              <p className="mt-2 text-sm text-slate-600">{description}</p>
            </article>
          ))}
        </div>
        <div className="mt-8 text-center">
          <Link href="/product-tour" className="text-primary font-medium hover:underline">
            View full product tour →
          </Link>
        </div>
      </Section>

      {/* How it works */}
      <Section tint>
        <h2 className="text-2xl sm:text-3xl font-bold text-slate-900 text-center">How it works</h2>
        <p className="mt-2 text-slate-600 text-center max-w-2xl mx-auto">
          A straightforward workflow from setup to daily operations, shown with real in-app screens.
        </p>
        <div className="mt-10 grid sm:grid-cols-2 lg:grid-cols-4 gap-5">
          {HOW_IT_WORKS.map(({ step, title, description }) => (
            <div key={step} className="rounded-xl bg-white border border-slate-200 p-5">
              <span className="inline-flex h-9 w-9 items-center justify-center rounded-full bg-primary text-white text-sm font-semibold">
                {step}
              </span>
              <h3 className="mt-3 font-semibold text-slate-900">{title}</h3>
              <p className="mt-1 text-sm text-slate-600">{description}</p>
            </div>
          ))}
        </div>
        <div className="mt-10 grid sm:grid-cols-2 gap-6">
          {HOW_IT_WORKS_SCREENSHOTS.map(({ src, title, description, alt }) => (
            <article key={src} className="card-surface p-3 sm:p-4">
              <DemoFrame src={src} alt={alt} sizes="(max-width: 640px) 100vw, (max-width: 1024px) 50vw, 540px" />
              <h3 className="mt-4 font-semibold text-slate-900">{title}</h3>
              <p className="mt-1 text-sm text-slate-600">{description}</p>
            </article>
          ))}
        </div>
      </Section>

      {/* Why choose SFC */}
      <Section tint>
        <h2 className="text-2xl sm:text-3xl font-bold text-slate-900 text-center">Why operators choose SFC</h2>
        <ul className="mt-8 max-w-3xl mx-auto space-y-3 text-slate-700">
          {DIFFERENTIATORS.map((item) => (
            <li key={item} className="flex gap-2">
              <span className="text-primary" aria-hidden>
                ✓
              </span>
              {item}
            </li>
          ))}
        </ul>
        <div className="mt-8 text-center">
          <Link href="/compare" className="text-primary font-medium hover:underline">
            Compare options →
          </Link>
        </div>
      </Section>

      {/* Security and compliance */}
      <Section>
        <h2 className="text-2xl sm:text-3xl font-bold text-slate-900 text-center">Security and compliance transparency</h2>
        <p className="mt-2 text-slate-600 text-center max-w-2xl mx-auto">
          Role-based access, secure cloud infrastructure, and published policy pages to support clear operations.
        </p>
        <ul className="mt-8 max-w-4xl mx-auto grid sm:grid-cols-2 lg:grid-cols-3 gap-4">
          {COMPLIANCE_LINKS.map(({ href, label }) => (
            <li key={href} className="rounded-lg border border-slate-200 p-4 text-center">
              <Link href={href} className="text-sm font-medium text-slate-700 hover:text-primary">
                {label}
              </Link>
            </li>
          ))}
        </ul>
        <div className="mt-8 text-center">
          <Link href="/security" className="text-primary font-medium hover:underline">
            Explore security overview →
          </Link>
        </div>
      </Section>

      {/* Final CTA */}
      <Section className="bg-primary text-white">
        <div className="text-center max-w-2xl mx-auto">
          <h2 className="text-2xl sm:text-3xl font-bold">Ready to simplify operations?</h2>
          <p className="mt-2 text-blue-100">
            Start your trial or book a guided demo. No onboarding fee. Flat monthly pricing.
          </p>
          <div className="mt-8 flex flex-wrap gap-3 justify-center">
            <Link href={PRIMARY_CTA_HREF} className="inline-flex items-center justify-center rounded-lg bg-white px-5 py-2.5 text-sm font-medium text-primary hover:bg-blue-50 transition-colors">
              {PRIMARY_CTA_LABEL}
            </Link>
            <Link href={SECONDARY_CTA_HREF} className="inline-flex items-center justify-center rounded-lg border border-blue-200 px-5 py-2.5 text-sm font-medium text-white hover:bg-blue-500 transition-colors">
              {SECONDARY_CTA_LABEL}
            </Link>
          </div>
          <div className="mt-4 text-blue-100 text-sm">
            <A2pSnippet brief />
          </div>
        </div>
      </Section>
    </>
  );
}
