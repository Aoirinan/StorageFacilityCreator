import type { Metadata } from 'next';
import { Section } from '@/components/Section';
import { CtaButton } from '@/components/CtaButton';
import { A2pSnippet } from '@/components/A2pSnippet';

export const metadata: Metadata = {
  title: 'Security',
  description: 'Security and privacy: access controls, activity logs, data protection, and responsible messaging practices.',
};

export default function SecurityPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Security & Privacy</h1>
        <p className="mt-2 text-lg text-slate-600 max-w-2xl">
          We take security and privacy seriously. Here’s how we approach it.
        </p>
      </Section>

      <Section tint>
        <h2 className="text-xl font-bold text-slate-900">Security & Privacy by Design</h2>
        <p className="mt-3 text-slate-600">
          We build access controls, logging, and data handling into the product from the start. We use reputable cloud infrastructure and follow common security practices.
        </p>
      </Section>

      <Section>
        <h2 className="text-xl font-bold text-slate-900">Access Controls</h2>
        <p className="mt-3 text-slate-600">
          Role-based access lets you control who can see and change what. We follow least-privilege principles so users only have the access they need.
        </p>
      </Section>

      <Section tint>
        <h2 className="text-xl font-bold text-slate-900">Activity Logs</h2>
        <p className="mt-3 text-slate-600">
          Key actions are logged for accountability. You can review who did what and when, which helps with auditing and compliance.
        </p>
      </Section>

      <Section>
        <h2 className="text-xl font-bold text-slate-900">Data Protection</h2>
        <p className="mt-3 text-slate-600">
          Data is encrypted in transit. We use established cloud providers and keep infrastructure and dependencies updated. We do not make unverifiable compliance claims; we focus on practical safeguards.
        </p>
      </Section>

      <Section tint>
        <h2 className="text-xl font-bold text-slate-900">Responsible Messaging Practices</h2>
        <p className="mt-3 text-slate-600">
          For SMS and email, we require opt-in and support clear opt-out (e.g. STOP) and help (HELP) flows. We do not claim carrier approval; we describe our process clearly so you and your tenants know what to expect.
        </p>
        <div className="mt-4">
          <A2pSnippet />
        </div>
      </Section>

      <Section>
        <div className="text-center">
          <CtaButton>Schedule a Demo</CtaButton>
        </div>
      </Section>
    </>
  );
}
