import type { Metadata } from 'next';
import Link from 'next/link';
import { Section } from '@/components/Section';
import { PageCtaBand } from '@/components/PageCtaBand';
import { PAGE_OG_IMAGES } from '@/config/site';

export const metadata: Metadata = {
  title: 'Why SFC',
  description:
    'See why storage operators choose SFC for published per-facility pricing, unlimited users, practical workflows, compliance transparency, and real-world integrations.',
  openGraph: { images: [PAGE_OG_IMAGES['why-sfc']] },
  twitter: { images: [PAGE_OG_IMAGES['why-sfc']] },
};

const rows = [
  ['Pricing model', '$75/facility/month, published', 'Often quote-based with tiered modules'],
  ['User seats', 'Unlimited users per facility', 'Often per-seat or plan-limited'],
  ['Feature packaging', 'All features in the base rate', 'Often distributed across add-on modules'],
  ['Compliance transparency', 'Published legal and compliance pages', 'Varies by vendor'],
  ['Operational focus', 'Built for practical storage workflows', 'May include broader, less focused suites'],
  ['Onboarding complexity', 'No onboarding fee, lightweight setup', 'Can involve heavier implementation overhead'],
  ['Practical integrations', 'Stripe, Twilio, SendGrid, QuickBooks', 'Varies by vendor and plan'],
];

export default function WhySfcPage() {
  return (
    <>
      <Section className="pt-10 pb-6">
        <span className="eyebrow">Positioning</span>
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Why operators choose SFC</h1>
        <p className="mt-2 text-lg text-slate-600 max-w-3xl">
          SFC is built for teams that want modern, focused operations software — not an enterprise suite with more modules than they need.
        </p>
      </Section>

      <Section tint>
        <h2 className="text-2xl font-bold text-slate-900">Positioning overview</h2>
        <ul className="mt-5 space-y-2.5 text-slate-700 leading-relaxed">
          <li>• Published per-facility pricing for predictable budgeting as you add sites</li>
          <li>• Unlimited users per facility — no per-seat scaling costs</li>
          <li>• All features included in the base rate — no add-on modules</li>
          <li>• Operational workflows designed for real storage teams</li>
          <li>• Clear legal/compliance documentation for buyer trust</li>
          <li>• Practical integrations for billing and communications</li>
        </ul>
        <p className="mt-4 text-sm text-slate-600">
          For implementation depth, review <Link href="/product-tour" className="text-primary hover:underline">Product Tour</Link>{' '}
          and <Link href="/integrations" className="text-primary hover:underline">Integrations</Link>.
        </p>
      </Section>

      <Section>
        <h2 className="text-2xl font-bold text-slate-900">Neutral comparison lens</h2>
        <p className="mt-2 text-slate-600">
          This table uses broad criteria for evaluation and does not make unsupported claims about individual competitors.
        </p>
        <div className="mt-5 overflow-x-auto rounded-xl border border-slate-200">
          <table className="w-full min-w-[680px] text-sm">
            <thead className="bg-slate-50 text-slate-700">
              <tr>
                <th className="text-left p-3">Evaluation area</th>
                <th className="text-left p-3">SFC approach</th>
                <th className="text-left p-3">Typical legacy pattern</th>
              </tr>
            </thead>
            <tbody>
              {rows.map(([area, sfc, legacy]) => (
                <tr key={area} className="border-t border-slate-200">
                  <td className="p-3 font-medium text-slate-900">{area}</td>
                  <td className="p-3 text-slate-700">{sfc}</td>
                  <td className="p-3 text-slate-600">{legacy}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      </Section>

      <Section tint>
        <div className="mx-auto max-w-3xl text-center">
          <h2 className="text-2xl font-bold text-slate-900">Comparing to another platform?</h2>
          <p className="mt-3 text-slate-600">
            We keep a factual side-by-side view of how SFC stacks up against the other major self-storage
            management platforms — no spin, no attack language.
          </p>
          <div className="mt-5">
            <Link
              href="/compare"
              className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-5 py-2.5 text-sm font-semibold text-slate-700 hover:bg-slate-50 transition-colors"
            >
              See the comparison →
            </Link>
          </div>
        </div>
      </Section>

      <Section>
        <PageCtaBand title="Compare with your current stack" subtitle="Use a live demo to evaluate fit against your existing workflows and priorities." />
      </Section>
    </>
  );
}
