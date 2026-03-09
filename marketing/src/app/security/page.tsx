import type { Metadata } from 'next';
import { Section } from '@/components/Section';
import { CtaButton } from '@/components/CtaButton';
import { A2pSnippet } from '@/components/A2pSnippet';
import { SITE_NAME } from '@/config/site';

export const metadata: Metadata = {
  title: 'Security',
  description: 'Security overview: access controls, activity logs, data protection, and responsible messaging practices.',
};

export default function SecurityPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Security &amp; Privacy</h1>
        <p className="mt-2 text-lg text-slate-600 max-w-2xl">
          We take security and privacy seriously. Here&apos;s how we approach it.
        </p>
      </Section>

      <Section tint>
        <h2 className="text-xl font-bold text-slate-900">Security by Design</h2>
        <p className="mt-3 text-slate-600">
          We build access controls, logging, and data handling into the product from the start. {SITE_NAME} runs on Google Cloud / Firebase, a reputable enterprise-grade cloud infrastructure. We follow common security practices including least-privilege access, encryption in transit, and dependency management.
        </p>
      </Section>

      <Section>
        <h2 className="text-xl font-bold text-slate-900">Access Controls</h2>
        <p className="mt-3 text-slate-600">
          Role-based access lets facility operators control who can see and change what within their account. We follow least-privilege principles so users only have the access they need. Authentication is handled by Firebase Authentication, which supports email/password and two-factor authentication (2FA).
        </p>
      </Section>

      <Section tint>
        <h2 className="text-xl font-bold text-slate-900">Activity Logs</h2>
        <p className="mt-3 text-slate-600">
          Key actions are logged for accountability. Facility operators can review who did what and when, which supports internal auditing and compliance. Logs are retained for a reasonable period to support investigations and dispute resolution.
        </p>
      </Section>

      <Section>
        <h2 className="text-xl font-bold text-slate-900">Data Protection</h2>
        <p className="mt-3 text-slate-600">
          Data is encrypted in transit using TLS. We use established cloud providers and keep infrastructure and dependencies updated. We do not make unverifiable compliance certifications; we focus on practical, documented safeguards.
        </p>
        <p className="mt-3 text-slate-600">
          <strong>Shared responsibility:</strong> While we maintain strong platform-level security, Customers are responsible for protecting their account credentials, managing user access within their account, and ensuring that data they enter into the Service is handled lawfully.
        </p>
        <p className="mt-3 text-slate-600">
          See our{' '}
          <a href="/subprocessors" className="text-primary hover:underline">Subprocessor List</a>{' '}
          for the third-party providers we rely on and their security postures.
        </p>
      </Section>

      <Section tint>
        <h2 className="text-xl font-bold text-slate-900">Responsible Messaging Practices</h2>
        <p className="mt-3 text-slate-600">
          For SMS and email, we require opt-in and support clear opt-out (STOP) and help (HELP) flows. We do not claim carrier approval; we describe our process clearly so you and your tenants know what to expect. See our{' '}
          <a href="/sms-terms" className="text-primary hover:underline">SMS Terms</a>{' '}
          for full details.
        </p>
        <div className="mt-4">
          <A2pSnippet />
        </div>
      </Section>

      <Section>
        <h2 className="text-xl font-bold text-slate-900">Backups and Availability</h2>
        <p className="mt-3 text-slate-600">
          Our infrastructure provider (Google Cloud / Firebase) maintains redundant storage and automatic backups at the platform level. We strive for high availability but do not guarantee 100% uptime. We recommend that Customers export critical data periodically as an additional safeguard.
        </p>
      </Section>

      <Section tint>
        <h2 className="text-xl font-bold text-slate-900">Related Policies</h2>
        <ul className="mt-3 space-y-2 text-slate-600">
          <li><a href="/privacy" className="text-primary hover:underline">Privacy Policy</a> — data collection, use, and retention</li>
          <li><a href="/subprocessors" className="text-primary hover:underline">Subprocessor List</a> — third-party providers</li>
          <li><a href="/dpa" className="text-primary hover:underline">Data Processing Agreement</a> — available upon request</li>
          <li><a href="/sms-terms" className="text-primary hover:underline">SMS Terms</a> — messaging consent and opt-out</li>
        </ul>
      </Section>

      <Section>
        <div className="text-center">
          <CtaButton>Schedule a Demo</CtaButton>
        </div>
      </Section>
    </>
  );
}
