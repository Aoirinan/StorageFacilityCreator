import type { Metadata } from 'next';
import { Section } from '@/components/Section';
import { CtaButton } from '@/components/CtaButton';
import { PRICE_MONTHLY, TRIAL_LINE } from '@/config/site';

export const metadata: Metadata = {
  title: 'Pricing',
  description: `Flat-rate $${PRICE_MONTHLY}/month. No onboarding fee. ${TRIAL_LINE}.`,
};

export default function PricingPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Pricing</h1>
        <p className="mt-2 text-lg text-slate-600 max-w-2xl">
          One flat rate. No per-unit fees. No surprise onboarding costs.
        </p>
      </Section>

      <Section tint>
        <div className="max-w-md mx-auto rounded-2xl bg-white border border-slate-200 shadow-lg p-8">
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
          </ul>
          <p className="mt-6 text-sm text-slate-600">
            Unlike per-unit pricing models, our flat rate stays simple as you grow.
          </p>
          <div className="mt-8">
            <CtaButton>Schedule a Demo</CtaButton>
          </div>
        </div>
      </Section>
    </>
  );
}
