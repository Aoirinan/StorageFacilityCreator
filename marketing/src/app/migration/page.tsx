import type { Metadata } from 'next';
import { Section } from '@/components/Section';
import { PageCtaBand } from '@/components/PageCtaBand';
import { PAGE_OG_IMAGES } from '@/config/site';

export const metadata: Metadata = {
  title: 'Migration',
  description:
    'Plan your migration to SFC with practical setup expectations, onboarding steps, and support guidance.',
  alternates: { canonical: '/migration' },
  openGraph: { images: [PAGE_OG_IMAGES.migration] },
  twitter: { images: [PAGE_OG_IMAGES.migration] },
};

export default function MigrationPage() {
  return (
    <>
      <Section className="pt-10 pb-6">
        <span className="eyebrow">Migration Planning</span>
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Migration and onboarding</h1>
        <p className="mt-2 text-lg text-slate-600 max-w-3xl">
          Move to SFC with a clear, staged implementation plan based on your facility structure and current data.
        </p>
      </Section>

      <Section tint>
        <h2 className="text-2xl font-bold text-slate-900">Typical rollout path</h2>
        <ol className="mt-5 space-y-3.5 text-slate-700 list-decimal pl-5 leading-relaxed">
          <li>Discovery call to review current workflow and data structure.</li>
          <li>Facility setup and baseline configuration.</li>
          <li>Tenant/unit data import and validation checks.</li>
          <li>Billing and communication workflow verification.</li>
          <li>Go-live planning with operational handoff.</li>
        </ol>
      </Section>

      <Section>
        <h2 className="text-2xl font-bold text-slate-900">What to prepare</h2>
        <ul className="mt-4 space-y-2.5 text-slate-700 leading-relaxed">
          <li>• Current tenant and unit records (CSV or equivalent export)</li>
          <li>• Rate and charge structure details</li>
          <li>• Team access roles and permission expectations</li>
          <li>• Existing communication templates and notice preferences</li>
        </ul>
        <div className="mt-8 grid sm:grid-cols-2 gap-4">
          <article className="card-surface p-4">
            <h3 className="font-semibold text-slate-900">Best fit for</h3>
            <p className="mt-2 text-sm text-slate-600">
              Independent and multi-facility operators moving from spreadsheets or legacy systems who want practical rollout support.
            </p>
          </article>
          <article className="card-surface p-4">
            <h3 className="font-semibold text-slate-900">What success looks like</h3>
            <p className="mt-2 text-sm text-slate-600">
              Staff can execute billing, reminders, delinquency actions, and reporting in a repeatable daily workflow.
            </p>
          </article>
        </div>
      </Section>

      <Section tint>
        <PageCtaBand title="Plan your migration with confidence" subtitle="Share your current setup and we will map a practical rollout path." />
      </Section>
    </>
  );
}
