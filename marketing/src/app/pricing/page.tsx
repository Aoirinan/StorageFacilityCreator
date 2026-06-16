import type { Metadata } from 'next';
import Link from 'next/link';
import { Section } from '@/components/Section';
import { CtaButton } from '@/components/CtaButton';
import {
  ONLINE_RENTALS_ADDON_MONTHLY,
  PAGE_OG_IMAGES,
  PRICE_MONTHLY,
  PRIMARY_CTA_HREF,
  SECONDARY_CTA_HREF,
  TRIAL_LINE,
} from '@/config/site';

export const metadata: Metadata = {
  title: 'Pricing',
  description: `$${PRICE_MONTHLY} per facility, per month. Unlimited users per facility, all features included, no onboarding fee, and a 30-day trial. Transparent self-storage software pricing.`,
  openGraph: { images: [PAGE_OG_IMAGES.pricing] },
  twitter: { images: [PAGE_OG_IMAGES.pricing] },
};

export default function PricingPage() {
  const trustNotes = ['Stripe payments', 'Twilio messaging', 'QuickBooks integration', 'Published legal pages'];
  const pricingFaqs = [
    ['Is there an onboarding fee?', 'No. SFC is designed for straightforward onboarding without an onboarding fee.'],
    ['Is pricing per unit or per user?', `No to both. Pricing is $${PRICE_MONTHLY} per facility, per month, with unlimited users per facility. Your bill scales with facility count, not with units or seats.`],
    ['How does pricing work if I have multiple facilities?', `Each facility is $${PRICE_MONTHLY}/month. Two facilities bill at $${PRICE_MONTHLY * 2}/month, three at $${PRICE_MONTHLY * 3}/month, and so on. All features and unlimited users are included at every site.`],
    ['Is there a contract?', 'Subscription terms are month-to-month unless otherwise agreed in writing.'],
    [
      'What is included?',
      `All core operations, billing workflows, messaging, reporting, e-sign, Stripe payments, Twilio SMS, SendGrid email, and QuickBooks integration — no feature-gated tiers. Optional: a public facility page where customers rent units online with SEO-friendly structure is +$${ONLINE_RENTALS_ADDON_MONTHLY}/month per facility when enabled.`,
    ],
    ['Does SFC support payments?', 'Yes. Stripe-backed payment workflows are supported in the product.'],
    ['Does SFC support SMS reminders?', 'Yes. Opt-in SMS messaging flows are supported with STOP/HELP handling.'],
    ['Does SFC integrate with QuickBooks?', 'Yes. QuickBooks integration paths are available for accounting sync workflows.'],
    ['Can I manage multiple facilities?', 'Yes. Multi-facility workflows are first-class. Each facility bills at the published per-facility rate.'],
    ['Is setup assistance available?', 'Yes. Use demo/contact channels to coordinate setup guidance.'],
    ['Do you offer migration help?', 'Migration support is available based on your data and timeline requirements.'],
    ['Are legal and compliance pages available?', 'Yes. SFC publishes legal, privacy, SMS, subprocessors, and DPA information.'],
    ['What happens after the free trial?', 'You can continue on the paid monthly plan if SFC fits your operation.'],
  ] as const;

  return (
    <>
      <Section className="pt-10 pb-6">
        <span className="eyebrow">Simple Pricing</span>
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Pricing</h1>
        <p className="mt-2 text-lg text-slate-600 max-w-2xl">
          Premium operations software with straightforward pricing for serious self-storage operators.
        </p>
      </Section>

      <Section tint>
        <div className="max-w-md mx-auto rounded-2xl bg-white border border-slate-200 shadow-lg p-6 sm:p-8">
          <h2 className="text-2xl font-bold text-slate-900">Per-facility pricing</h2>
          <p className="mt-4">
            <span className="text-4xl font-bold text-slate-900">${PRICE_MONTHLY}</span>
            <span className="text-slate-600">/month</span>
            <span className="block mt-1 text-sm font-medium text-slate-500">per facility</span>
          </p>
          <ul className="mt-6 space-y-3 text-slate-700" role="list">
            <li className="flex gap-2">
              <span className="text-primary" aria-hidden>✓</span>
              Unlimited users per facility
            </li>
            <li className="flex gap-2">
              <span className="text-primary" aria-hidden>✓</span>
              All core features included — no tiered modules or per-seat fees
            </li>
            <li className="flex gap-2">
              <span className="text-primary" aria-hidden>✓</span>
              No onboarding fee
            </li>
            <li className="flex gap-2">
              <span className="text-primary" aria-hidden>✓</span>
              {TRIAL_LINE}
            </li>
            <li className="flex gap-2">
              <span className="text-primary" aria-hidden>✓</span>
              Month-to-month — cancel anytime
            </li>
          </ul>
          <div className="mt-6 rounded-xl border border-emerald-200 bg-emerald-50/80 p-4 text-left">
            <p className="text-xs font-bold uppercase tracking-wide text-emerald-800">Optional add-on</p>
            <p className="mt-1 text-sm font-semibold text-emerald-950">Website rentals &amp; SEO-ready public pages</p>
            <p className="mt-2 text-sm text-emerald-900/90 leading-relaxed">
              Let tenants reserve storage units from your own branded page—structured for local search and mobile checkout. +
              <strong>${ONLINE_RENTALS_ADDON_MONTHLY}</strong>/month per facility when you turn it on.
            </p>
          </div>
          <div className="mt-6 rounded-lg bg-slate-50 border border-slate-200 p-4">
            <p className="text-xs font-semibold uppercase tracking-wider text-slate-500">Simple math</p>
            <p className="mt-2 text-sm text-slate-700">
              1 facility = <strong className="text-slate-900">${PRICE_MONTHLY}/mo</strong> · 2 facilities ={' '}
              <strong className="text-slate-900">${PRICE_MONTHLY * 2}/mo</strong> · 3 facilities ={' '}
              <strong className="text-slate-900">${PRICE_MONTHLY * 3}/mo</strong>
            </p>
            <p className="mt-2 text-xs text-slate-500">
              No per-unit fees. No per-user fees. No tiered modules.
            </p>
          </div>
          <div className="mt-8 flex flex-wrap gap-3">
            <CtaButton href={PRIMARY_CTA_HREF} />
            <CtaButton href={SECONDARY_CTA_HREF} variant="secondary" />
          </div>
          <ul className="mt-6 flex flex-wrap gap-x-4 gap-y-2 text-xs text-slate-500" role="list">
            {trustNotes.map((item) => (
              <li key={item} className="flex items-center gap-1">
                <span aria-hidden>✓</span>
                {item}
              </li>
            ))}
          </ul>
        </div>
      </Section>

      <Section>
        <h2 className="text-2xl font-bold text-slate-900">Pricing FAQ</h2>
        <div className="mt-6 grid sm:grid-cols-2 gap-4 sm:gap-5">
          {pricingFaqs.map(([q, a]) => (
            <article key={q} className="card-surface p-4 sm:p-5">
              <h3 className="font-semibold text-slate-900">{q}</h3>
              <p className="mt-2 text-sm text-slate-600">{a}</p>
            </article>
          ))}
        </div>
        <p className="mt-6 text-sm text-slate-600">
          For security details, see <Link href="/security" className="text-primary hover:underline">Security</Link>. For full feature
          coverage, see <Link href="/features" className="text-primary hover:underline">Features</Link>.
        </p>
      </Section>

      <Section tint>
        <div className="mx-auto max-w-3xl text-center">
          <h2 className="text-2xl font-bold text-slate-900">Evaluating your options?</h2>
          <p className="mt-3 text-slate-600">
            See a factual side-by-side comparison of SFC against the other major self-storage management platforms —
            pricing model, packaging, and operator fit in one place.
          </p>
          <div className="mt-5">
            <Link
              href="/compare"
              className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-5 py-2.5 text-sm font-semibold text-slate-700 hover:bg-slate-50 transition-colors"
            >
              See how SFC compares →
            </Link>
          </div>
        </div>
      </Section>
    </>
  );
}
