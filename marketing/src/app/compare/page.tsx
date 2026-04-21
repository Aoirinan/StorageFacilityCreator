import type { Metadata } from 'next';
import Link from 'next/link';
import Script from 'next/script';
import { Section } from '@/components/Section';
import { CtaButton } from '@/components/CtaButton';
import { Reveal } from '@/components/Reveal';
import {
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
  title: 'SFC vs. SiteLink, storEDGE, and Easy Storage Solutions',
  description:
    'A factual side-by-side comparison of Storage Facility Creator with SiteLink, storEDGE, and Easy Storage Solutions. Pricing model, deployment, feature breadth, and operator fit — no spin.',
  alternates: { canonical: '/compare' },
  openGraph: {
    title: 'Compare SFC vs. SiteLink, storEDGE, and Easy Storage Solutions',
    description:
      'How Storage Facility Creator compares to SiteLink, storEDGE, and Easy Storage Solutions on pricing model, deployment, and operator fit.',
    images: [PAGE_OG_IMAGES.compare],
  },
  twitter: { images: [PAGE_OG_IMAGES.compare] },
};

type Row = {
  area: string;
  sfc: string;
  sitelink: string;
  storedge: string;
  ess: string;
};

const COMPARE_ROWS: Row[] = [
  {
    area: 'Pricing model',
    sfc: `Flat $${PRICE_MONTHLY}/month`,
    sitelink: 'Per-facility, quote-based',
    storedge: 'Per-facility, quote-based',
    ess: 'Per-facility, tiered',
  },
  {
    area: 'Facilities included',
    sfc: 'Unlimited',
    sitelink: 'Priced per facility',
    storedge: 'Priced per facility',
    ess: 'Priced per facility',
  },
  {
    area: 'Users included',
    sfc: 'Unlimited',
    sitelink: 'Varies by plan',
    storedge: 'Varies by plan',
    ess: 'Varies by plan',
  },
  {
    area: 'Onboarding fee',
    sfc: 'None',
    sitelink: 'Typical setup cost',
    storedge: 'Typical setup cost',
    ess: 'Varies',
  },
  {
    area: 'Trial',
    sfc: '30-day trial + first month free',
    sitelink: 'Demo-first typically',
    storedge: 'Demo-first typically',
    ess: 'Demo / limited trial',
  },
  {
    area: 'Deployment',
    sfc: 'Cloud web app',
    sitelink: 'Cloud (myHub) + long desktop lineage',
    storedge: 'Cloud-native SaaS',
    ess: 'Cloud-native SaaS',
  },
  {
    area: 'Payments',
    sfc: 'Stripe (tokenized, PCI-offloaded)',
    sitelink: 'Integrated processor options',
    storedge: 'Integrated processor options',
    ess: 'Integrated processor options',
  },
  {
    area: 'Messaging',
    sfc: 'Twilio SMS + SendGrid email, consent-aware',
    sitelink: 'Messaging modules available',
    storedge: 'Messaging built-in',
    ess: 'Messaging built-in',
  },
  {
    area: 'Accounting integration',
    sfc: 'QuickBooks',
    sitelink: 'Multiple integrations via ecosystem',
    storedge: 'Multiple integrations',
    ess: 'Integrations available',
  },
  {
    area: 'Global Do Not Rent network',
    sfc: 'Built-in operator network',
    sitelink: 'Not included',
    storedge: 'Not included',
    ess: 'Not included',
  },
  {
    area: 'Gate / kiosk ecosystem',
    sfc: 'Core integrations shipping; partner ecosystem expanding',
    sitelink: 'Extensive partner ecosystem accrued over decades',
    storedge: 'Broad partner library',
    ess: 'Established partner set',
  },
  {
    area: 'Typical buyer fit',
    sfc: 'Independents & multi-site operators wanting flat pricing',
    sitelink: 'Mid-to-large operators needing deep ecosystem',
    storedge: 'Operators wanting a modern UI within a large-vendor portfolio',
    ess: 'Smaller independents wanting simplicity',
  },
];

type Profile = {
  id: string;
  name: string;
  pitch: string;
  shines: string[];
  sfcFit: string[];
  pick: { them: string; sfc: string };
};

const PROFILES: Profile[] = [
  {
    id: 'sitelink',
    name: 'SiteLink',
    pitch:
      'SiteLink is one of the most established names in self-storage management software, part of the Storable portfolio. It has a long desktop lineage and a modern cloud product (myHub), with a broad partner ecosystem around gate systems, kiosks, call centers, and revenue management that has been built up over many years.',
    shines: [
      'Deep partner ecosystem for gate systems, kiosks, and ancillary services',
      'Widely used by mid-to-large and enterprise operators',
      'Mature reporting depth and industry integrations',
      'Large installed base means plenty of third-party consultants and trainers',
    ],
    sfcFit: [
      'Flat monthly pricing instead of per-facility billing — especially relevant if you manage multiple sites',
      'Single modern cloud codebase without a legacy desktop lineage to carry',
      'Unlimited users included so manager turnover and multi-site teams do not trigger add-on costs',
      'Built-in Global Do Not Rent network for cross-facility operator risk-sharing',
    ],
    pick: {
      them:
        'Pick SiteLink if you need deep integrations with specific gate, kiosk, or call-center partners today, or if you are running a large portfolio already deeply tied into the Storable ecosystem.',
      sfc:
        'Pick SFC if you want predictable flat pricing, a modern interface, and the Global DNR network — and you are comfortable trading some legacy ecosystem breadth for a tighter, newer platform.',
    },
  },
  {
    id: 'storedge',
    name: 'storEDGE',
    pitch:
      'storEDGE is also part of the Storable portfolio and is positioned as a modern cloud-native storage management platform with a clean interface, strong tenant website / online rental flows, and an integrated product suite.',
    shines: [
      'Polished modern UI compared to legacy desktop-era products',
      'Strong tenant website and online rental workflows',
      'Integrated suite within the Storable portfolio (payments, websites, insurance, marketing)',
      'Established across many independent and mid-size portfolios',
    ],
    sfcFit: [
      'Flat monthly pricing instead of per-facility cost stacking',
      'Independent vendor — not a bundled entry point into a larger portfolio of add-on products',
      'All core features included rather than distributed across tiered packages and add-ons',
      'Global Do Not Rent network built into the core product, not a separate upsell',
    ],
    pick: {
      them:
        'Pick storEDGE if you want a polished cloud platform and you are interested in buying into the broader Storable portfolio of adjacent products (marketing, websites, insurance, etc.).',
      sfc:
        'Pick SFC if you want a modern cloud platform without the portfolio-upsell dynamic, and you prefer predictable flat pricing over per-facility billing.',
    },
  },
  {
    id: 'easy-storage-solutions',
    name: 'Easy Storage Solutions',
    pitch:
      'Easy Storage Solutions (ESS) is a cloud-native storage management platform that has built a loyal base of smaller independent operators. It emphasizes simplicity, tenant website building, online rentals, and responsive customer service.',
    shines: [
      'Well-known focus on independent and smaller operators',
      'Included tenant website builder and online rental flows',
      'Reputation for responsive customer support',
      'Straightforward product for single-site operators',
    ],
    sfcFit: [
      'Flat pricing across unlimited facilities scales better as you add sites',
      'Unlimited users included rather than user-based pricing',
      'Built-in Global Do Not Rent network for cross-facility risk visibility',
      'Published legal and compliance pages (SMS terms, e-sign, DPA, subprocessors) in one place for buyer review',
    ],
    pick: {
      them:
        'Pick Easy Storage Solutions if you are a single-site operator who values their established customer-service reputation and prefers a product explicitly shaped around smaller independents.',
      sfc:
        'Pick SFC if you expect to add facilities and want pricing that does not scale with site count, or if the Global DNR network and flat-rate model matter to how you plan to grow.',
    },
  },
];

const FAQS: { q: string; a: string }[] = [
  {
    q: 'How is Storage Facility Creator different from SiteLink, storEDGE, and Easy Storage Solutions?',
    a: `The biggest structural differences are pricing model and feature packaging. SFC is a flat $${PRICE_MONTHLY}/month for unlimited facilities and unlimited users, with all core features included and no onboarding fee. SiteLink, storEDGE, and Easy Storage Solutions each price per facility and typically layer add-on modules or tiers. SFC also includes a built-in Global Do Not Rent network, which is not a feature of those products.`,
  },
  {
    q: 'Is SFC cheaper than SiteLink or storEDGE?',
    a: 'It depends on facility count. Because SFC is a single flat monthly rate regardless of facility count, the multi-site math tends to favor SFC as you add locations. For a single-site operator, per-facility pricing from SiteLink or storEDGE may land close to or below SFC depending on plan and add-ons. The honest answer: compare apples-to-apples by requesting a quote that includes all modules you actually use.',
  },
  {
    q: 'Should I switch from Easy Storage Solutions to SFC?',
    a: 'If you are a single-site operator satisfied with Easy Storage Solutions, there is no urgent reason to switch. The case for SFC gets stronger if you are planning to add facilities (flat pricing scales better), want a built-in Global Do Not Rent network, or want unlimited users included rather than priced per seat.',
  },
  {
    q: 'Can I migrate data from SiteLink, storEDGE, or Easy Storage Solutions?',
    a: 'Yes. Migration support is available for tenants, units, balances, and payment methods based on the export formats your current platform provides. Complexity varies by platform and by how custom your setup is. See the Migration page for scope and timelines.',
  },
  {
    q: 'Does SFC have feature parity with legacy storage management software?',
    a: 'SFC covers the operational core: tenants, units, billing, ledgers, autopay, delinquency workflows, messaging, reporting, e-sign, and integrations with Stripe, Twilio, SendGrid, and QuickBooks. Legacy platforms have accrued broader partner ecosystems around gate systems, kiosks, and call centers over many years — that breadth is a real strength of the incumbents. If your operation depends on a specific niche integration that SFC does not yet support, tell us during your evaluation so fit can be confirmed up front.',
  },
  {
    q: 'What does SFC include that SiteLink, storEDGE, and Easy Storage Solutions do not?',
    a: 'The most distinctive SFC-only items are the built-in Global Do Not Rent operator network, flat pricing with unlimited facilities and users, and all core features included without module upsells. Everything else is table stakes overlap — the real comparison is pricing structure, packaging, and operator fit.',
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
            {SITE_NAME} vs. SiteLink, storEDGE, and Easy Storage Solutions
          </h1>
          <p className="mt-4 text-lg text-slate-600 max-w-3xl">
            A fair side-by-side look at four self-storage management platforms. We don&rsquo;t talk down any
            of them — each has real strengths. This page is meant to help you pick the right fit for your
            operation based on pricing model, deployment, and feature packaging.
          </p>
          <div className="mt-6 flex flex-wrap gap-3">
            <CtaButton href={PRIMARY_CTA_HREF}>{PRIMARY_CTA_LABEL}</CtaButton>
            <CtaButton href={SECONDARY_CTA_HREF} variant="secondary">
              {SECONDARY_CTA_LABEL}
            </CtaButton>
          </div>
          <p className="mt-4 text-sm text-slate-500">
            Last reviewed {new Date().toLocaleString('en-US', { month: 'long', year: 'numeric' })}. Vendor
            facts are drawn from publicly available product and pricing information. If you spot something
            inaccurate, email us and we&rsquo;ll update this page.
          </p>
        </Reveal>
      </Section>

      {/* At a glance table */}
      <Section tint className="bg-white">
        <Reveal>
          <h2 className="font-display text-2xl sm:text-3xl font-extrabold text-slate-900">At a glance</h2>
          <p className="mt-2 text-slate-600 max-w-3xl">
            The quickest way to orient — pricing model, deployment, and included features. Specifics for
            SiteLink, storEDGE, and Easy Storage Solutions depend on plan, add-ons, and current vendor
            quotes; always confirm with the vendor before signing.
          </p>
        </Reveal>
        <div className="mt-6 overflow-x-auto rounded-xl border border-slate-200 shadow-xs">
          <table className="w-full min-w-[820px] text-sm">
            <thead className="bg-slate-50 text-slate-700">
              <tr>
                <th scope="col" className="text-left p-3 font-semibold">
                  Area
                </th>
                <th scope="col" className="text-left p-3 font-semibold text-primary">
                  SFC
                </th>
                <th scope="col" className="text-left p-3 font-semibold">
                  SiteLink
                </th>
                <th scope="col" className="text-left p-3 font-semibold">
                  storEDGE
                </th>
                <th scope="col" className="text-left p-3 font-semibold">
                  Easy Storage Solutions
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
                  <td className="p-3 text-slate-600">{row.sitelink}</td>
                  <td className="p-3 text-slate-600">{row.storedge}</td>
                  <td className="p-3 text-slate-600">{row.ess}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
        <p className="mt-4 text-xs text-slate-500">
          Product names are trademarks of their respective owners and are used here only for factual
          comparison purposes. {SITE_NAME} is not affiliated with, endorsed by, or sponsored by SiteLink,
          storEDGE / Storable, or Easy Storage Solutions.
        </p>
      </Section>

      {/* Per-competitor deep dives */}
      {PROFILES.map((p, index) => (
        <Section
          key={p.id}
          id={p.id}
          tint={index % 2 === 1}
          className={index % 2 === 1 ? 'bg-slate-50' : 'bg-white'}
        >
          <Reveal>
            <span className="eyebrow">SFC vs. {p.name}</span>
            <h2 className="font-display mt-3 text-2xl sm:text-3xl font-extrabold text-slate-900">
              How {SITE_NAME} compares to {p.name}
            </h2>
            <p className="mt-3 text-slate-600 leading-relaxed max-w-3xl">{p.pitch}</p>
          </Reveal>

          <div className="mt-8 grid md:grid-cols-2 gap-6">
            <Reveal>
              <article className="h-full rounded-2xl border border-emerald-200 bg-white p-6 shadow-xs">
                <h3 className="font-semibold text-slate-900">Where {p.name} shines</h3>
                <ul role="list" className="mt-3 space-y-2 text-sm text-slate-700">
                  {p.shines.map((s) => (
                    <li key={s} className="flex gap-2">
                      <span aria-hidden className="text-emerald-500">
                        ✓
                      </span>
                      <span>{s}</span>
                    </li>
                  ))}
                </ul>
              </article>
            </Reveal>

            <Reveal delay={80}>
              <article className="h-full rounded-2xl border border-blue-200 bg-white p-6 shadow-xs">
                <h3 className="font-semibold text-slate-900">Where {SITE_NAME} fits differently</h3>
                <ul role="list" className="mt-3 space-y-2 text-sm text-slate-700">
                  {p.sfcFit.map((s) => (
                    <li key={s} className="flex gap-2">
                      <span aria-hidden className="text-primary">
                        →
                      </span>
                      <span>{s}</span>
                    </li>
                  ))}
                </ul>
              </article>
            </Reveal>
          </div>

          <Reveal delay={120}>
            <div className="mt-6 grid md:grid-cols-2 gap-4">
              <div className="rounded-xl border border-slate-200 bg-slate-900 text-slate-100 p-5">
                <p className="text-xs font-semibold uppercase tracking-wider text-slate-400">
                  Pick {p.name} if…
                </p>
                <p className="mt-2 text-sm leading-relaxed">{p.pick.them}</p>
              </div>
              <div className="rounded-xl border border-primary/30 bg-gradient-to-br from-primary to-blue-600 text-white p-5">
                <p className="text-xs font-semibold uppercase tracking-wider text-blue-100">
                  Pick {SITE_NAME} if…
                </p>
                <p className="mt-2 text-sm leading-relaxed">{p.pick.sfc}</p>
              </div>
            </div>
          </Reveal>
        </Section>
      ))}

      {/* FAQ */}
      <Section tint className="bg-gradient-to-b from-slate-50 to-white">
        <Reveal>
          <h2 className="font-display text-2xl sm:text-3xl font-extrabold text-slate-900">
            Comparison questions operators ask us
          </h2>
          <p className="mt-3 text-slate-600 max-w-3xl">
            Straight answers to the questions that come up during vendor evaluations. No spin on either
            side.
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
