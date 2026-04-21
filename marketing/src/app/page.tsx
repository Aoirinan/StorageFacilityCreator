import Image from 'next/image';
import Link from 'next/link';
import Script from 'next/script';
import {
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
  PRICE_MONTHLY,
  TRIAL_LINE,
} from '@/config/site';
import { Section } from '@/components/Section';
import { CtaButton } from '@/components/CtaButton';
import { DemoFrame } from '@/components/DemoFrame';
import { A2pSnippet } from '@/components/A2pSnippet';
import {
  FeatureIcon,
  FeatureVisual,
  getFeatureTheme,
  type FeatureIconKey,
} from '@/components/FeatureIcon';
import { IntegrationLogos } from '@/components/IntegrationLogos';
import { HeroShowcase } from '@/components/HeroShowcase';
import { HomeFaq } from '@/components/HomeFaq';
import { Reveal } from '@/components/Reveal';

type KeyFeature = {
  title: string;
  description: string;
  featureKey: FeatureIconKey;
};

const KEY_FEATURES: KeyFeature[] = [
  {
    title: 'Tenant management',
    description: 'Centralized tenant records with billing history, communication context, and account status.',
    featureKey: 'tenants',
  },
  {
    title: 'Unit management',
    description: 'Track occupancy, status, and availability by facility with clear operational visibility.',
    featureKey: 'units',
  },
  {
    title: 'Billing and ledgers',
    description: 'Recurring charges, one-time fees, and full ledger transparency by tenant.',
    featureKey: 'billing',
  },
  {
    title: 'Payments and autopay',
    description: 'Stripe-powered payments and autopay controls to reduce collections friction.',
    featureKey: 'payments',
  },
  {
    title: 'Delinquency workflows',
    description: 'Past-due workflows, notices, and overlock/lien support for practical collections operations.',
    featureKey: 'delinquency',
  },
  {
    title: 'Messaging and reporting',
    description: 'Opt-in SMS/email reminders, activity logs, and operator-focused reporting.',
    featureKey: 'messaging',
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

type TourCard = {
  title: string;
  description: string;
  featureKey: FeatureIconKey;
  image?: { src: string; alt: string };
};

const TOUR_CARDS: TourCard[] = [
  {
    title: 'Dashboard overview',
    description: 'Monitor occupancy, balances, and action items quickly.',
    featureKey: 'dashboard',
    image: {
      src: '/sfc_dashboard_hero_clean.png',
      alt: 'Storage Facility Creator dashboard overview screen',
    },
  },
  {
    title: 'Tenant records',
    description: 'View account, payment, and communication history in context.',
    featureKey: 'tenants',
    image: {
      src: '/how-it-works-tenants.png',
      alt: 'Storage Facility Creator tenants list screen',
    },
  },
  {
    title: 'Billing and ledger',
    description: 'Track invoices, payments, and account-level balances.',
    featureKey: 'billing',
    image: {
      src: '/how-it-works-autopay.png',
      alt: 'Storage Facility Creator autopay and billing screen',
    },
  },
  {
    title: 'Facility map and units',
    description: 'Manage visual unit layout and status by location.',
    featureKey: 'map',
    image: {
      src: '/how-it-works-facility-setup.png',
      alt: 'Storage Facility Creator facility setup screen',
    },
  },
  {
    title: 'Contracts and e-sign',
    description: 'Support digital document workflows and disclosures.',
    featureKey: 'contracts',
  },
  {
    title: 'Integrations',
    description: 'Use practical integrations like Stripe, Twilio, SendGrid, and QuickBooks.',
    featureKey: 'integrations',
  },
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

const DNR_USE_CASES = [
  'Abandoned units, damage, or serious rule violations documented by your team',
  'Operational risk visibility across participating facilities',
  'Built-in accountability with facility identity and submitting employee details',
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
      <Section className="pt-8 sm:pt-12 pb-12 sm:pb-16 bg-gradient-to-b from-blue-50 via-white to-indigo-50/50">
        <div className="grid lg:grid-cols-2 gap-10 lg:gap-16 items-center">
          <div>
            <span className="eyebrow">Self-Storage SaaS</span>
            <h1 className="font-display mt-3 text-4xl sm:text-5xl lg:text-6xl font-extrabold text-slate-900 leading-[1.05] text-balance">
              Stop running your facility on{' '}
              <span className="relative inline-block">
                <span className="relative z-10 text-primary">spreadsheets</span>
                <span
                  aria-hidden
                  className="absolute inset-x-0 bottom-1 -z-0 h-3 bg-amber-200/70"
                />
              </span>
              .
            </h1>
            <p className="mt-5 text-lg text-slate-600 max-w-xl">
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
            <p className="mt-4 text-sm font-medium text-slate-700">
              <span className="text-slate-900 font-semibold">${PRICE_MONTHLY}/month</span>
              <span className="mx-2 text-slate-300" aria-hidden>·</span>
              <span>Flat rate</span>
              <span className="mx-2 text-slate-300" aria-hidden>·</span>
              <span>{TRIAL_LINE}</span>
            </p>

            {/* Hero stats ribbon */}
            <dl className="mt-8 grid max-w-lg grid-cols-3 gap-3 border-t border-slate-200 pt-6">
              <div>
                <dt className="text-xs uppercase tracking-wider text-slate-500">Facilities</dt>
                <dd className="font-display text-2xl font-extrabold text-slate-900">Unlimited</dd>
              </div>
              <div>
                <dt className="text-xs uppercase tracking-wider text-slate-500">Integrations</dt>
                <dd className="font-display text-2xl font-extrabold text-slate-900">
                  5<span className="text-primary">+</span>
                </dd>
              </div>
              <div>
                <dt className="text-xs uppercase tracking-wider text-slate-500">Setup time</dt>
                <dd className="font-display text-2xl font-extrabold text-slate-900">
                  &lt;1<span className="text-slate-500 text-base font-semibold"> day</span>
                </dd>
              </div>
            </dl>
          </div>
          <div className="order-first lg:order-0">
            <HeroShowcase />
          </div>
        </div>
      </Section>

      {/* Trust strip + integrations */}
      <div className="border-y border-blue-100 bg-gradient-to-r from-blue-50/80 via-indigo-50/60 to-blue-50/80">
        <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8 py-6">
          <ul className="flex flex-wrap justify-center gap-x-8 gap-y-2 text-sm text-slate-700" role="list">
            {TRUST_STRIP_ITEMS.map((item) => (
              <li key={item} className="flex items-center gap-2">
                <span className="text-primary" aria-hidden>✓</span>
                {item}
              </li>
            ))}
          </ul>
          <IntegrationLogos />
        </div>
      </div>

      {/* Key Features */}
      <Section tint id="features" className="bg-gradient-to-b from-sky-50 to-blue-50/60">
        <Reveal>
          <h2 className="font-display text-3xl sm:text-4xl font-extrabold text-slate-900 text-center">Everything you need to run your facility</h2>
          <p className="mt-3 text-slate-600 text-center max-w-2xl mx-auto">
            Tenant and unit management, billing, late notices, autopay, and reporting—built for independent and multi-site operators.
          </p>
        </Reveal>
        <ul className="mt-12 grid sm:grid-cols-2 lg:grid-cols-3 gap-6" role="list">
          {KEY_FEATURES.map((f) => {
            const theme = getFeatureTheme(f.featureKey);
            return (
              <li
                key={f.title}
                className={`group relative overflow-hidden rounded-xl bg-white p-6 shadow-sm border ${theme.border} transition-all hover:-translate-y-0.5 hover:shadow-md`}
              >
                <span
                  className={`pointer-events-none absolute -right-8 -top-8 h-24 w-24 rounded-full ${theme.bg} opacity-50 blur-2xl transition-opacity group-hover:opacity-80`}
                  aria-hidden
                />
                <FeatureIcon featureKey={f.featureKey} size="md" />
                <h3 className="mt-4 font-semibold text-slate-900">{f.title}</h3>
                <p className="mt-2 text-sm text-slate-600">{f.description}</p>
              </li>
            );
          })}
        </ul>
        <div className="mt-10 text-center">
          <Link href="/features" className="text-primary font-medium hover:underline">
            See all features →
          </Link>
        </div>
      </Section>

      {/* Product tour */}
      <Section className="bg-white">
        <Reveal>
          <h2 className="font-display text-3xl sm:text-4xl font-extrabold text-slate-900 text-center">Product tour highlights</h2>
          <p className="mt-3 text-slate-600 text-center max-w-2xl mx-auto">
            A guided look at the workflows operators use most.
          </p>
        </Reveal>
        <div className="mt-10 grid md:grid-cols-2 lg:grid-cols-3 gap-6">
          {TOUR_CARDS.map(({ title, description, featureKey, image }) => {
            const theme = getFeatureTheme(featureKey);
            return (
              <article
                key={title}
                className="group overflow-hidden rounded-xl border border-slate-200 bg-white shadow-xs transition-all hover:-translate-y-0.5 hover:shadow-md"
              >
                {image ? (
                  <div className={`relative aspect-4/3 w-full overflow-hidden ${theme.panel}`}>
                    <Image
                      src={image.src}
                      alt={image.alt}
                      fill
                      className="object-contain p-3 transition-transform duration-300 group-hover:scale-[1.02]"
                      sizes="(max-width: 768px) 100vw, (max-width: 1024px) 50vw, 33vw"
                    />
                  </div>
                ) : (
                  <FeatureVisual featureKey={featureKey} className="rounded-none border-0" />
                )}
                <div className="p-5">
                  <div className="flex items-center gap-3">
                    <FeatureIcon featureKey={featureKey} size="sm" />
                    <h3 className="font-semibold text-slate-900">{title}</h3>
                  </div>
                  <p className="mt-2 text-sm text-slate-600">{description}</p>
                </div>
              </article>
            );
          })}
        </div>
        <div className="mt-8 text-center">
          <Link href="/product-tour" className="text-primary font-medium hover:underline">
            View full product tour →
          </Link>
        </div>
      </Section>

      {/* How it works */}
      <Section tint className="bg-gradient-to-b from-indigo-50/80 to-blue-50/60">
        <Reveal>
          <h2 className="font-display text-3xl sm:text-4xl font-extrabold text-slate-900 text-center">How it works</h2>
          <p className="mt-3 text-slate-600 text-center max-w-2xl mx-auto">
            A straightforward workflow from setup to daily operations, shown with real in-app screens.
          </p>
        </Reveal>
        <div className="mt-10 grid sm:grid-cols-2 lg:grid-cols-4 gap-5">
          {HOW_IT_WORKS.map(({ step, title, description }) => (
            <div key={step} className="rounded-xl bg-white border border-indigo-100 p-5 shadow-xs">
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

      {/* Built for operators */}
      <Section className="bg-gradient-to-b from-white to-amber-50/40">
        <div className="grid lg:grid-cols-5 gap-10 items-center">
          <Reveal className="lg:col-span-2">
            <span className="eyebrow">Built for operators</span>
            <h2 className="font-display mt-3 text-3xl sm:text-4xl font-extrabold text-slate-900">
              Designed around real storage operations.
            </h2>
            <p className="mt-4 text-slate-600 leading-relaxed">
              SFC is built around the day-to-day problems independent and multi-facility operators actually have:
              late payments, messy ledgers, lien timelines, scattered tenant communication. Every workflow is shaped
              by the operational reality of running a facility — not by enterprise software committee.
            </p>
            <div className="mt-6 flex flex-wrap gap-2 text-xs font-medium text-slate-600">
              <span className="rounded-full border border-slate-200 bg-white px-3 py-1">Independent operators</span>
              <span className="rounded-full border border-slate-200 bg-white px-3 py-1">Multi-site portfolios</span>
              <span className="rounded-full border border-slate-200 bg-white px-3 py-1">Self-service rentals</span>
              <span className="rounded-full border border-slate-200 bg-white px-3 py-1">Manager-assisted move-ins</span>
            </div>
          </Reveal>

          <Reveal className="lg:col-span-3" delay={80}>
            <ul role="list" className="grid sm:grid-cols-2 gap-4">
              {[
                {
                  key: 'delinquency' as FeatureIconKey,
                  problem: 'Chasing late payments across 3 tabs',
                  solution: 'Stage-based delinquency workflow with notices, overlocks, and lien timelines built in.',
                },
                {
                  key: 'billing' as FeatureIconKey,
                  problem: 'Reconciling ledgers by hand each month',
                  solution: 'Per-tenant ledger with recurring charges, fees, and payments — always in sync.',
                },
                {
                  key: 'messaging' as FeatureIconKey,
                  problem: 'Forgetting to send payment reminders',
                  solution: 'Opt-in SMS/email reminders with delivery status and carrier-compliant STOP/HELP handling.',
                },
                {
                  key: 'units' as FeatureIconKey,
                  problem: 'Not knowing what is actually empty',
                  solution: 'Visual unit map with live status, holds, and maintenance flags across facilities.',
                },
              ].map(({ key, problem, solution }) => {
                const theme = getFeatureTheme(key);
                return (
                  <li
                    key={problem}
                    className={`relative overflow-hidden rounded-xl border ${theme.border} bg-white p-5 shadow-xs`}
                  >
                    <span
                      aria-hidden
                      className={`pointer-events-none absolute -right-10 -top-10 h-24 w-24 rounded-full ${theme.bg} opacity-60 blur-2xl`}
                    />
                    <div className="flex items-start gap-3">
                      <FeatureIcon featureKey={key} size="sm" />
                      <div>
                        <p className="text-xs font-semibold uppercase tracking-wider text-slate-500">
                          Instead of
                        </p>
                        <p className="text-sm font-semibold text-slate-900">{problem}</p>
                        <p className="mt-2 text-sm text-slate-600 leading-relaxed">{solution}</p>
                      </div>
                    </div>
                  </li>
                );
              })}
            </ul>
          </Reveal>
        </div>
      </Section>

      {/* Why choose SFC */}
      <Section className="bg-gradient-to-b from-white to-sky-50/70">
        <Reveal>
          <h2 className="font-display text-3xl sm:text-4xl font-extrabold text-slate-900 text-center">Why operators choose SFC</h2>
        </Reveal>
        <ul className="mt-8 max-w-3xl mx-auto space-y-3 text-slate-700 rounded-2xl border border-blue-100 bg-white/90 p-6 shadow-sm">
          {DIFFERENTIATORS.map((item) => (
            <li key={item} className="flex gap-2">
              <span className="text-primary" aria-hidden>
                ✓
              </span>
              {item}
            </li>
          ))}
        </ul>
      </Section>

      {/* Global DNR */}
      <Section className="bg-gradient-to-b from-white to-emerald-50/50">
        <Reveal>
          <h2 className="font-display text-3xl sm:text-4xl font-extrabold text-slate-900 text-center">Global Do Not Rent List</h2>
        </Reveal>
        <p className="mt-2 text-slate-600 text-center max-w-3xl mx-auto">
          SFC includes a Global Do Not Rent workflow that helps operators share documented, operationally relevant risk
          signals with other participating facilities before approving a new renter.
        </p>
        <div className="mt-8 grid lg:grid-cols-2 gap-6">
          <article className="card-surface p-5 sm:p-6">
            <h3 className="font-semibold text-slate-900">What operators can record</h3>
            <ul className="mt-3 space-y-2 text-sm text-slate-700" role="list">
              {DNR_USE_CASES.map((item) => (
                <li key={item} className="flex gap-2">
                  <span className="text-primary" aria-hidden>
                    •
                  </span>
                  {item}
                </li>
              ))}
            </ul>
            <p className="mt-4 text-sm text-slate-600">
              Submissions can include incident context and supporting unit photos, and are tied to the submitting
              facility, contact information, and employee identity for traceability.
            </p>
          </article>

          <article className="card-surface p-5 sm:p-6">
            <h3 className="font-semibold text-slate-900">Compliance and responsible use</h3>
            <p className="mt-3 text-sm text-slate-700 leading-relaxed">
              This workflow is intended for legitimate business-risk documentation. Customers are responsible for using
              it lawfully, including compliance with applicable privacy, housing, consumer reporting, and defamation
              laws, and for ensuring entries are factual, accurate, and supported by internal records.
            </p>
            <p className="mt-3 text-sm text-slate-700 leading-relaxed">
              Use only information you are authorized to share, and do not submit protected-class or discriminatory
              content. Review{' '}
              <Link href="/acceptable-use" className="text-primary hover:underline">
                Acceptable Use
              </Link>{' '}
              and{' '}
              <Link href="/terms" className="text-primary hover:underline">
                Terms
              </Link>{' '}
              for baseline requirements.
            </p>
          </article>
        </div>
      </Section>

      {/* Security and compliance */}
      <Section className="bg-gradient-to-b from-white via-emerald-50/40 to-white">
        <div className="grid lg:grid-cols-2 gap-10 lg:gap-14 items-center">
          <div className="relative mx-auto w-full max-w-md lg:max-w-none">
            <div className="absolute inset-0 -z-10 rounded-[2rem] bg-gradient-to-br from-emerald-200/40 via-emerald-100/30 to-transparent blur-2xl" aria-hidden />
            <div className="relative rounded-2xl border border-emerald-100 bg-white/90 p-6 shadow-sm backdrop-blur">
              <div className="relative aspect-square w-full">
                <Image
                  src="/shield-secure.png"
                  alt="Shield with checkmark representing secure storage facility operations"
                  fill
                  className="object-contain"
                  sizes="(max-width: 1024px) 60vw, 480px"
                />
              </div>
              <ul className="mt-4 grid grid-cols-2 gap-2 text-xs text-slate-600" role="list">
                <li className="flex items-center gap-1.5">
                  <span className="inline-block h-1.5 w-1.5 rounded-full bg-emerald-500" aria-hidden />
                  Role-based access
                </li>
                <li className="flex items-center gap-1.5">
                  <span className="inline-block h-1.5 w-1.5 rounded-full bg-emerald-500" aria-hidden />
                  Secure cloud infrastructure
                </li>
                <li className="flex items-center gap-1.5">
                  <span className="inline-block h-1.5 w-1.5 rounded-full bg-emerald-500" aria-hidden />
                  Published policy pages
                </li>
                <li className="flex items-center gap-1.5">
                  <span className="inline-block h-1.5 w-1.5 rounded-full bg-emerald-500" aria-hidden />
                  Stripe-handled card data
                </li>
              </ul>
            </div>
          </div>

          <div>
            <span className="eyebrow">Security &amp; compliance</span>
            <h2 className="font-display mt-3 text-3xl sm:text-4xl font-extrabold text-slate-900">
              Security and compliance transparency
            </h2>
            <p className="mt-3 text-slate-600">
              Role-based access, secure cloud infrastructure, and published policy pages to support clear operations.
              Payments are processed by Stripe — we never see or store full card numbers or CVV codes.
            </p>
            <ul className="mt-6 grid sm:grid-cols-2 gap-3" role="list">
              {COMPLIANCE_LINKS.map(({ href, label }) => (
                <li key={href}>
                  <Link
                    href={href}
                    className="flex items-center justify-between rounded-lg border border-emerald-100 bg-white px-4 py-3 text-sm font-medium text-slate-700 shadow-xs transition-all hover:-translate-y-0.5 hover:border-emerald-300 hover:text-primary hover:shadow-sm"
                  >
                    <span>{label}</span>
                    <span className="text-emerald-500" aria-hidden>
                      →
                    </span>
                  </Link>
                </li>
              ))}
            </ul>
            <div className="mt-6">
              <Link href="/security" className="text-primary font-medium hover:underline">
                Explore security overview →
              </Link>
            </div>
          </div>
        </div>
      </Section>

      {/* Pricing teaser */}
      <Section className="bg-gradient-to-b from-white via-blue-50/40 to-white">
        <Reveal>
          <div className="mx-auto max-w-3xl rounded-3xl border border-blue-200/70 bg-white p-8 sm:p-10 shadow-lg shadow-blue-900/5 relative overflow-hidden">
            <div
              aria-hidden
              className="pointer-events-none absolute -right-20 -top-20 h-56 w-56 rounded-full bg-gradient-to-br from-amber-200/60 to-primary/20 blur-3xl"
            />
            <div className="relative text-center">
              <span className="eyebrow">Simple pricing</span>
              <h2 className="font-display mt-3 text-3xl sm:text-4xl font-extrabold text-slate-900">
                One flat rate. No surprises.
              </h2>
              <div className="mt-6 inline-flex items-baseline gap-1">
                <span className="font-display text-6xl sm:text-7xl font-extrabold text-slate-900">
                  ${PRICE_MONTHLY}
                </span>
                <span className="text-lg text-slate-500 font-medium">/month</span>
              </div>
              <p className="mt-3 text-slate-600">
                Unlimited facilities. Unlimited users. All features included. No onboarding fee.
              </p>
              <p className="mt-2 text-sm font-semibold text-emerald-700">
                {TRIAL_LINE}
              </p>
              <div className="mt-8 flex flex-wrap justify-center gap-3">
                <CtaButton href={PRIMARY_CTA_HREF}>{PRIMARY_CTA_LABEL}</CtaButton>
                <Link href="/pricing" className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-5 py-2.5 text-sm font-medium text-slate-700 hover:bg-slate-50 transition-colors">
                  See full pricing
                </Link>
              </div>
            </div>
          </div>
        </Reveal>
      </Section>

      {/* Home FAQ */}
      <Section tint className="bg-gradient-to-b from-slate-50 to-white">
        <Reveal>
          <h2 className="font-display text-3xl sm:text-4xl font-extrabold text-slate-900 text-center">
            Questions operators ask us
          </h2>
          <p className="mt-3 text-slate-600 text-center max-w-2xl mx-auto">
            Quick answers to what buyers ask most. Full FAQ covers SMS, migration, security, and integrations in depth.
          </p>
        </Reveal>
        <HomeFaq />
      </Section>

      {/* Final CTA */}
      <section className="relative overflow-hidden bg-gradient-to-br from-indigo-700 via-primary to-blue-600 text-white">
        <div
          className="pointer-events-none absolute -left-20 -top-24 h-80 w-80 rounded-full bg-white/10 blur-3xl"
          aria-hidden
        />
        <div
          className="pointer-events-none absolute -right-24 bottom-0 h-96 w-96 rounded-full bg-amber-300/20 blur-3xl"
          aria-hidden
        />
        <div
          className="pointer-events-none absolute inset-0 opacity-30 [background-image:radial-gradient(circle_at_1px_1px,rgba(255,255,255,0.25)_1px,transparent_0)] [background-size:22px_22px]"
          aria-hidden
        />
        <div className="relative mx-auto max-w-6xl px-4 sm:px-6 lg:px-8 py-14 sm:py-20 text-center">
          <span className="inline-flex items-center rounded-full border border-white/25 bg-white/10 px-3 py-1 text-xs font-semibold uppercase tracking-[0.18em] text-white/90 backdrop-blur">
            ${PRICE_MONTHLY}/month · flat rate
          </span>
          <h2 className="font-display mt-4 text-3xl sm:text-4xl lg:text-5xl font-extrabold">
            Ready to simplify operations?
          </h2>
          <p className="mt-3 max-w-2xl mx-auto text-blue-100">
            Start your trial or book a guided demo. No onboarding fee.
          </p>
          <div className="mt-8 flex flex-wrap gap-3 justify-center">
            <Link
              href={PRIMARY_CTA_HREF}
              className="inline-flex items-center justify-center rounded-lg bg-white px-6 py-3 text-sm font-semibold text-primary shadow-lg shadow-indigo-950/20 hover:bg-blue-50 transition-colors"
            >
              {PRIMARY_CTA_LABEL}
            </Link>
            <Link
              href={SECONDARY_CTA_HREF}
              className="inline-flex items-center justify-center rounded-lg border border-white/40 bg-white/5 px-6 py-3 text-sm font-semibold text-white hover:bg-white/15 transition-colors backdrop-blur"
            >
              {SECONDARY_CTA_LABEL}
            </Link>
          </div>
          <A2pSnippet brief className="mt-6 text-sm text-blue-100" />
        </div>
      </section>
    </>
  );
}
