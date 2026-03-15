import type { Metadata } from 'next';
import Link from 'next/link';
import { Section } from '@/components/Section';
import { CtaButton } from '@/components/CtaButton';
import { PAGE_OG_IMAGES, PRICE_MONTHLY, PRIMARY_CTA_HREF, SECONDARY_CTA_HREF, TRIAL_LINE } from '@/config/site';

export const metadata: Metadata = {
  title: 'Pricing',
  description: `Flat-rate $${PRICE_MONTHLY}/month self-storage software pricing. No onboarding fee, 30-day trial, and practical operator-focused workflows.`,
  openGraph: { images: [PAGE_OG_IMAGES.pricing] },
  twitter: { images: [PAGE_OG_IMAGES.pricing] },
};

export default function PricingPage() {
  const trustNotes = ['Stripe payments', 'Twilio messaging', 'QuickBooks integration', 'Published legal pages'];
  const pricingFaqs = [
    ['Is there an onboarding fee?', 'No. SFC is designed for straightforward onboarding without an onboarding fee.'],
    ['Is pricing per unit?', 'No. Pricing is flat monthly pricing, not per-unit pricing.'],
    ['Is there a contract?', 'Subscription terms are month-to-month unless otherwise agreed in writing.'],
    ['What is included?', 'Core operations, billing workflows, messaging support, reporting, and integrations in one platform.'],
    ['Does SFC support payments?', 'Yes. Stripe-backed payment workflows are supported in the product.'],
    ['Does SFC support SMS reminders?', 'Yes. Opt-in SMS messaging flows are supported with STOP/HELP handling.'],
    ['Does SFC integrate with QuickBooks?', 'Yes. QuickBooks integration paths are available for accounting sync workflows.'],
    ['Can I manage multiple facilities?', 'Yes. SFC supports multi-facility operational workflows.'],
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
          <h2 className="text-2xl font-bold text-slate-900">Flat rate</h2>
          <p className="mt-4">
            <span className="text-4xl font-bold text-slate-900">${PRICE_MONTHLY}</span>
            <span className="text-slate-600">/month</span>
          </p>
          <ul className="mt-6 space-y-3 text-slate-700" role="list">
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
              All features included
            </li>
            <li className="flex gap-2">
              <span className="text-primary" aria-hidden>✓</span>
              Built for self-storage operators
            </li>
          </ul>
          <p className="mt-6 text-sm text-slate-600">
            Unlike per-unit pricing models, this pricing model stays predictable as you grow.
          </p>
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
    </>
  );
}
