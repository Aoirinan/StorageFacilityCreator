import type { Metadata } from 'next';
import Link from 'next/link';
import Script from 'next/script';
import { Section } from '@/components/Section';
import { CtaButton } from '@/components/CtaButton';
import { Reveal } from '@/components/Reveal';
import {
  ONLINE_RENTALS_ADDON_MONTHLY,
  PAGE_OG_IMAGES,
  PRIMARY_CTA_HREF,
  PRIMARY_CTA_LABEL,
  SECONDARY_CTA_HREF,
  SECONDARY_CTA_LABEL,
  PRICE_MONTHLY,
  TRIAL_LINE,
  SITE_NAME,
} from '@/config/site';

export const metadata: Metadata = {
  title: 'Compare self-storage management software options',
  description:
    'A neutral side-by-side look at how Storage Facility Creator compares on pricing model, deployment, feature packaging, and operator fit — without naming or ranking other vendors.',
  alternates: { canonical: '/compare' },
  openGraph: {
    title: 'Compare self-storage management software options',
    description:
      'How Storage Facility Creator compares on published pricing, deployment, and operator fit using broad industry criteria.',
    images: [PAGE_OG_IMAGES.compare],
  },
  twitter: { images: [PAGE_OG_IMAGES.compare] },
};

type Row = {
  area: string;
  sfc: string;
  typical: string;
};

const COMPARE_ROWS: Row[] = [
  {
    area: 'Pricing model',
    sfc: `$${PRICE_MONTHLY}/facility/month — published rate`,
    typical: 'Often per-facility and quote-based with tiered modules',
  },
  {
    area: 'Users per facility',
    sfc: 'Unlimited',
    typical: 'Often varies by plan or per-seat',
  },
  {
    area: 'Feature packaging',
    sfc: `Core product in the base rate; optional website rentals (+$${ONLINE_RENTALS_ADDON_MONTHLY}/mo)`,
    typical: 'Often distributed across add-on modules or tiered plans',
  },
  {
    area: 'Onboarding fee',
    sfc: 'None',
    typical: 'Often includes setup or implementation fees',
  },
  {
    area: 'Trial',
    sfc: '30-day trial + first month free',
    typical: 'Often demo-first or limited trial',
  },
  {
    area: 'Deployment',
    sfc: 'Cloud web app',
    typical: 'Often cloud SaaS; some vendors retain legacy desktop lineage',
  },
  {
    area: 'Payments',
    sfc: 'Stripe (tokenized, PCI-offloaded)',
    typical: 'Often integrated processor options',
  },
  {
    area: 'Messaging',
    sfc: 'Twilio SMS + SendGrid email, consent-aware',
    typical: 'Often available as built-in or add-on modules',
  },
  {
    area: 'Accounting integration',
    sfc: 'QuickBooks',
    typical: 'Often QuickBooks plus additional accounting partners',
  },
  {
    area: 'Global Do Not Rent network',
    sfc: 'Built-in operator network',
    typical: 'Varies by vendor — confirm during evaluation',
  },
  {
    area: 'Gate / kiosk ecosystem',
    sfc: 'Core integrations shipping; partner ecosystem expanding',
    typical: 'Often broader partner libraries on established platforms',
  },
  {
    area: 'Typical buyer fit',
    sfc: 'Operators wanting transparent per-facility pricing with core features included',
    typical: 'Often mid-to-large portfolios needing deep legacy ecosystems',
  },
];

const EVALUATION_CATEGORIES = [
  {
    title: 'Pricing and packaging',
    points: [
      'Is the per-facility rate published or quote-based?',
      'Are users unlimited or priced per seat?',
      'Which modules are included in the base plan vs. add-ons?',
    ],
  },
  {
    title: 'Operations and workflows',
    points: [
      'Does the product cover tenants, units, billing, delinquency, and messaging in one place?',
      'How much setup is required before day-to-day use?',
      'Can your team run the product on mobile while on site?',
    ],
  },
  {
    title: 'Integrations and ecosystem',
    points: [
      'Which payment, messaging, and accounting integrations are included?',
      'Do you depend on gate, kiosk, or call-center partners that must be supported?',
      'How will data migration work from your current platform?',
    ],
  },
];

const FAQS: { q: string; a: string }[] = [
  {
    q: 'How is Storage Facility Creator different from other storage management platforms?',
    a: `The biggest structural differences are pricing transparency, feature packaging, and user licensing. SFC publishes a flat $${PRICE_MONTHLY} per facility, per month — the same rate for everyone, visible on the pricing page, with core features and unlimited users included. Many platforms also price per facility, but often via quotes that vary by plan, with feature tiers or add-on modules layered on top. SFC also includes a built-in Global Do Not Rent network. Always confirm specifics with any vendor you evaluate.`,
  },
  {
    q: 'Is SFC cheaper than legacy storage software?',
    a: `Sometimes, and sometimes not — but it is predictable. SFC is $${PRICE_MONTHLY} per facility per month with core features included. Other vendors often vary pricing by plan, modules, processing volume, and negotiation, which makes raw dollar comparisons difficult without a full quote. The honest framing: SFC trades quote-based flexibility for a published, predictable rate. Get an itemized quote from any vendor you are considering (including every module you actually need) and compare line-by-line.`,
  },
  {
    q: 'Do I pay more per facility as I add sites?',
    a: `No. The per-facility rate is the same at your first site and your twentieth — $${PRICE_MONTHLY}/month each. Two facilities bill at $${PRICE_MONTHLY * 2}/month, three at $${PRICE_MONTHLY * 3}/month, and so on. There are no volume surcharges and no tier jumps as you grow. Core features and unlimited users come with every facility.`,
  },
  {
    q: 'Should I switch from my current software to SFC?',
    a: 'If you are satisfied with your current platform, there is no urgent reason to switch. The case for SFC gets stronger if you want core features included without tier gating, unlimited users per facility instead of per-seat pricing, or the built-in Global Do Not Rent network. Run a side-by-side demo with your actual workflows before deciding.',
  },
  {
    q: 'Can I migrate data from my current software?',
    a: 'Yes. Migration support is available for tenants, units, balances, and payment methods based on the export formats your current platform provides. Complexity varies by platform and by how custom your setup is. See the Migration page for scope and timelines.',
  },
  {
    q: 'Does SFC have feature parity with legacy storage management software?',
    a: 'SFC covers the operational core: tenants, units, billing, ledgers, autopay, delinquency workflows, messaging, reporting, e-sign, and integrations with Stripe, Twilio, SendGrid, and QuickBooks. Established platforms have often accrued broader partner ecosystems around gate systems, kiosks, and call centers over many years — that breadth is a real strength of incumbents. If your operation depends on a specific niche integration that SFC does not yet support, tell us during your evaluation so fit can be confirmed up front.',
  },
  {
    q: 'What should I look for when comparing vendors?',
    a: 'Focus on published vs. quote-based pricing, per-seat vs. unlimited users, which modules are included in the base rate, migration support, integration breadth for your specific hardware partners, and how transparent the vendor is about compliance documentation. Bring your current quote to a demo and walk real workflows — not just a feature checklist.',
  },
];

export default function ComparePage() {
  const faqSchema = {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    mainEntity: FAQS.map((item) => ({
      '@type': 'Question',
      name: item.q,
      acceptedAnswer: { '@type': 'Answer', text: item.a },
    })),
  };

  return (
    <>
      <Script
        id="compare-faq-jsonld"
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(faqSchema) }}
      />

      {/* Hero */}
      <Section className="pt-10 sm:pt-14 pb-8 bg-gradient-to-b from-blue-50 via-white to-indigo-50/40">
        <Reveal>
          <span className="eyebrow">Compare</span>
          <h1 className="font-display mt-3 text-3xl sm:text-4xl lg:text-5xl font-extrabold text-slate-900 leading-tight text-balance max-w-4xl">
            Compare self-storage management software options
          </h1>
          <p className="mt-4 text-lg text-slate-600 max-w-3xl">
            A neutral side-by-side look at how {SITE_NAME} compares using broad industry criteria. We
            don&rsquo;t rank or attack other vendors — this page is meant to help you evaluate pricing
            model, deployment, and feature packaging for your operation.
          </p>
          <div className="mt-6 flex flex-wrap gap-3">
            <CtaButton href={PRIMARY_CTA_HREF}>{PRIMARY_CTA_LABEL}</CtaButton>
            <CtaButton href={SECONDARY_CTA_HREF} variant="secondary">
              {SECONDARY_CTA_LABEL}
            </CtaButton>
          </div>
          <p className="mt-4 text-sm text-slate-500">
            Last reviewed {new Date().toLocaleString('en-US', { month: 'long', year: 'numeric' })}.
            Criteria below describe common industry patterns — always confirm specifics with any vendor
            before signing.
          </p>
        </Reveal>
      </Section>

      {/* At a glance table */}
      <Section tint className="bg-white">
        <Reveal>
          <h2 className="font-display text-2xl sm:text-3xl font-extrabold text-slate-900">At a glance</h2>
          <p className="mt-2 text-slate-600 max-w-3xl">
            The quickest way to orient — pricing model, deployment, and included features. The
            &ldquo;typical legacy pattern&rdquo; column describes common industry approaches without
            naming individual products.
          </p>
        </Reveal>
        {/* Desktop: comparison table */}
        <div className="mt-6 hidden md:block overflow-x-auto rounded-xl border border-slate-200 shadow-xs">
          <table className="w-full min-w-[640px] text-sm">
            <thead className="bg-slate-50 text-slate-700">
              <tr>
                <th scope="col" className="text-left p-3 font-semibold">
                  Area
                </th>
                <th scope="col" className="text-left p-3 font-semibold text-primary">
                  SFC
                </th>
                <th scope="col" className="text-left p-3 font-semibold">
                  Typical legacy pattern
                </th>
              </tr>
            </thead>
            <tbody>
              {COMPARE_ROWS.map((row) => (
                <tr key={row.area} className="border-t border-slate-200 align-top">
                  <th scope="row" className="p-3 font-medium text-slate-900 text-left">
                    {row.area}
                  </th>
                  <td className="p-3 text-slate-800 bg-blue-50/40 font-medium">{row.sfc}</td>
                  <td className="p-3 text-slate-600">{row.typical}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>

        {/* Mobile: stacked cards per row */}
        <ul role="list" className="mt-6 md:hidden space-y-4">
          {COMPARE_ROWS.map((row) => (
            <li
              key={row.area}
              className="rounded-xl border border-slate-200 bg-white shadow-xs overflow-hidden"
            >
              <div className="bg-slate-50 px-4 py-3 border-b border-slate-200">
                <p className="text-xs font-semibold uppercase tracking-wider text-slate-500">
                  Area
                </p>
                <h3 className="mt-0.5 text-sm font-semibold text-slate-900">{row.area}</h3>
              </div>
              <dl className="divide-y divide-slate-100">
                <div className="px-4 py-3 bg-blue-50/40">
                  <dt className="text-xs font-semibold uppercase tracking-wider text-primary">
                    SFC
                  </dt>
                  <dd className="mt-1 text-sm font-medium text-slate-900">{row.sfc}</dd>
                </div>
                <div className="px-4 py-3">
                  <dt className="text-xs font-semibold uppercase tracking-wider text-slate-500">
                    Typical legacy pattern
                  </dt>
                  <dd className="mt-1 text-sm text-slate-700">{row.typical}</dd>
                </div>
              </dl>
            </li>
          ))}
        </ul>
        <p className="mt-4 text-xs text-slate-500">
          This table uses broad criteria for evaluation and does not make unsupported claims about
          individual vendors. Product names mentioned elsewhere in the industry are trademarks of their
          respective owners. {SITE_NAME} is not affiliated with, endorsed by, or sponsored by any other
          storage management software vendor.
        </p>
      </Section>

      {/* Evaluation checklist */}
      <Section className="bg-slate-50">
        <Reveal>
          <h2 className="font-display text-2xl sm:text-3xl font-extrabold text-slate-900">
            What to evaluate during a vendor comparison
          </h2>
          <p className="mt-3 text-slate-600 max-w-3xl">
            Use these questions during demos and quote reviews. They apply regardless of which platforms
            you are considering.
          </p>
        </Reveal>
        <div className="mt-8 grid md:grid-cols-3 gap-6">
          {EVALUATION_CATEGORIES.map((category) => (
            <Reveal key={category.title}>
              <article className="h-full rounded-2xl border border-slate-200 bg-white p-6 shadow-xs">
                <h3 className="font-semibold text-slate-900">{category.title}</h3>
                <ul role="list" className="mt-3 space-y-2 text-sm text-slate-700">
                  {category.points.map((point) => (
                    <li key={point} className="flex gap-2">
                      <span aria-hidden className="text-primary">
                        →
                      </span>
                      <span>{point}</span>
                    </li>
                  ))}
                </ul>
              </article>
            </Reveal>
          ))}
        </div>
        <Reveal delay={80}>
          <p className="mt-6 text-sm text-slate-600 max-w-3xl">
            For a deeper look at {SITE_NAME}&rsquo;s positioning without vendor-by-vendor claims, see{' '}
            <Link href="/why-sfc" className="text-primary hover:underline">
              Why SFC
            </Link>
            .
          </p>
        </Reveal>
      </Section>

      {/* FAQ */}
      <Section tint className="bg-gradient-to-b from-slate-50 to-white">
        <Reveal>
          <h2 className="font-display text-2xl sm:text-3xl font-extrabold text-slate-900">
            Comparison questions operators ask us
          </h2>
          <p className="mt-3 text-slate-600 max-w-3xl">
            Straight answers to the questions that come up during vendor evaluations.
          </p>
        </Reveal>
        <ul role="list" className="mt-8 max-w-3xl space-y-4">
          {FAQS.map((item) => (
            <li
              key={item.q}
              className="rounded-xl border border-slate-200 bg-white p-5 shadow-xs"
            >
              <h3 className="font-semibold text-slate-900">{item.q}</h3>
              <p className="mt-2 text-sm text-slate-600 leading-relaxed">{item.a}</p>
            </li>
          ))}
        </ul>
      </Section>

      {/* Final CTA */}
      <Section className="bg-gradient-to-br from-indigo-700 via-primary to-blue-600 text-white text-center">
        <Reveal>
          <h2 className="font-display text-2xl sm:text-3xl lg:text-4xl font-extrabold">
            Ready to run a real side-by-side?
          </h2>
          <p className="mt-3 max-w-2xl mx-auto text-blue-100">
            Book a demo and bring your current vendor&rsquo;s quote. We&rsquo;ll walk your actual workflows
            through SFC so you can compare honestly. {TRIAL_LINE}.
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
        </Reveal>
      </Section>
    </>
  );
}
