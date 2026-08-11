import type { Metadata } from 'next';
import Link from 'next/link';
import { Section } from '@/components/Section';

export const metadata: Metadata = {
  robots: { index: false, follow: true },
};

type ThanksPageProps = {
  searchParams?: Promise<Record<string, string | string[] | undefined>>;
};

export default async function ContactThanksPage({ searchParams }: ThanksPageProps) {
  const params = (await searchParams) ?? {};
  const intent = String(params.intent ?? 'demo').toLowerCase() === 'trial' ? 'trial' : 'demo';
  const source = typeof params.utm_source === 'string' ? params.utm_source : '';
  const campaign = typeof params.utm_campaign === 'string' ? params.utm_campaign : '';

  return (
    <Section className="py-14 bg-gradient-to-b from-blue-50 via-white to-indigo-50/40">
      <div className="max-w-2xl mx-auto card-surface p-8 sm:p-10 text-center">
        <span className="eyebrow">Request Received</span>
        <h1 className="mt-2 text-3xl sm:text-4xl font-bold text-slate-900">
          {intent === 'trial' ? 'Your trial request is in' : 'Your demo request is in'}
        </h1>
        <p className="mt-3 text-slate-600">
          We have your submission and will follow up shortly. In the meantime, you can review product flow and pricing.
        </p>
        {(source || campaign) && (
          <p className="mt-3 text-xs text-slate-500">
            Attribution saved {source ? `• source: ${source}` : ''}{campaign ? ` • campaign: ${campaign}` : ''}
          </p>
        )}
        <div className="mt-7 flex flex-wrap justify-center gap-3">
          <Link href="/product-tour" className="rounded-lg bg-primary px-4 py-2 text-sm font-semibold text-white">
            View Product Tour
          </Link>
          <Link href="/pricing" className="rounded-lg border border-slate-300 px-4 py-2 text-sm font-semibold text-slate-700">
            Review Pricing
          </Link>
          <Link href="/contact" className="rounded-lg border border-slate-300 px-4 py-2 text-sm font-semibold text-slate-700">
            Submit Another Request
          </Link>
        </div>
      </div>
    </Section>
  );
}
