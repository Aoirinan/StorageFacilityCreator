import type { Metadata } from 'next';
import Link from 'next/link';
import { Section } from '@/components/Section';
import { CtaButton } from '@/components/CtaButton';
import { A2pSnippet } from '@/components/A2pSnippet';
import { PAGE_OG_IMAGES, PRIMARY_CTA_HREF, SECONDARY_CTA_HREF, SITE_NAME } from '@/config/site';

export const metadata: Metadata = {
  title: 'Security',
  description:
    'Security and trust overview for SFC: infrastructure, data protection, access controls, provider integrations, and legal transparency.',
  openGraph: { images: [PAGE_OG_IMAGES.security] },
  twitter: { images: [PAGE_OG_IMAGES.security] },
};

export default function SecurityPage() {
  const securityPillars = [
    { title: 'Cloud-hosted infrastructure', body: 'Built on Google Cloud/Firebase service foundations.' },
    { title: 'Transport security', body: 'Data in transit is protected with TLS.' },
    { title: 'Role-based access', body: 'Permission controls support operational access boundaries.' },
    { title: 'Operational accountability', body: 'Activity logs support review and troubleshooting workflows.' },
  ];
  const trustLinks = [
    { href: '/privacy', label: 'Privacy Policy' },
    { href: '/terms', label: 'Terms of Service' },
    { href: '/subprocessors', label: 'Subprocessors' },
    { href: '/dpa', label: 'DPA' },
    { href: '/sms-terms', label: 'SMS Terms' },
    { href: '/esign-disclosure', label: 'E-Sign Disclosure' },
  ];

  return (
    <>
      <Section className="pt-10 pb-6">
        <span className="eyebrow">Trust & Security</span>
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Security &amp; Privacy</h1>
        <p className="mt-2 text-lg text-slate-600 max-w-2xl">
          Practical security controls and transparent policy documentation for self-storage operations.
        </p>
        <div className="mt-8 grid sm:grid-cols-2 lg:grid-cols-4 gap-3">
          {securityPillars.map((item) => (
            <article key={item.title} className="card-surface p-3">
              <h2 className="text-sm font-semibold text-slate-900">{item.title}</h2>
              <p className="mt-1 text-xs text-slate-600">{item.body}</p>
            </article>
          ))}
        </div>
      </Section>

      <Section tint>
        <h2 className="text-xl font-bold text-slate-900">Infrastructure and hosting</h2>
        <p className="mt-3 text-slate-600">
          {SITE_NAME} runs on cloud infrastructure provided through Google Cloud/Firebase services. Security controls include
          encryption in transit, dependency management, and platform-level operational hardening.
        </p>
      </Section>

      <Section>
        <h2 className="text-xl font-bold text-slate-900">Data protection</h2>
        <p className="mt-3 text-slate-600">
          Data is protected in transit with TLS. We use established service providers and avoid unverified certification claims.
          Security posture is communicated through practical controls and transparent legal documents.
        </p>
      </Section>

      <Section tint>
        <h2 className="text-xl font-bold text-slate-900">Access controls</h2>
        <p className="mt-3 text-slate-600">
          Role-based access allows facility operators to manage permissions per user and workflow. Authentication is handled
          through secure identity services and supports modern login protections.
        </p>
      </Section>

      <Section>
        <h2 className="text-xl font-bold text-slate-900">Operational security</h2>
        <p className="mt-3 text-slate-600">
          Activity logs support accountability and investigation workflows. Team-level access controls and operational tracking
          help reduce accidental changes and improve auditability.
        </p>
      </Section>

      <Section tint>
        <h2 className="text-xl font-bold text-slate-900">Payments and messaging providers</h2>
        <p className="mt-3 text-slate-600">
          SFC integrates with Stripe for payment processing and Twilio/SendGrid services for messaging delivery where configured.
          Provider choices support practical, production-oriented operations without overstating compliance guarantees.
        </p>
        <p className="mt-3 text-slate-600">
          <strong>Shared responsibility:</strong> SFC secures platform infrastructure and service delivery; customers are responsible
          for account credential hygiene, local access management, and lawful use of tenant data.
        </p>
        <p className="mt-3 text-slate-600">
          Review subprocessors and data-processing references in our published policy pages.
        </p>
      </Section>

      <Section>
        <h2 className="text-xl font-bold text-slate-900">Responsible messaging practices</h2>
        <p className="mt-3 text-slate-600">
          For SMS and email, we require opt-in and support clear opt-out (STOP) and help (HELP) flows. We do not claim carrier approval; we describe our process clearly so you and your tenants know what to expect. See our{' '}
          <Link href="/sms-terms" className="text-primary hover:underline">SMS Terms</Link>{' '}
          for full details.
        </p>
        <div className="mt-4">
          <A2pSnippet />
        </div>
      </Section>

      <Section tint>
        <h2 className="text-xl font-bold text-slate-900">Integrations and connected services</h2>
        <p className="mt-3 text-slate-600">
          Integration support includes operational workflows for Stripe, Twilio, SendGrid, and QuickBooks where enabled.
          Connected-service behavior depends on provider availability and account configuration.
        </p>
      </Section>

      <Section>
        <h2 className="text-xl font-bold text-slate-900">Legal and privacy transparency</h2>
        <ul className="mt-4 grid sm:grid-cols-2 lg:grid-cols-3 gap-3 text-slate-700">
          {trustLinks.map((item) => (
            <li key={item.href} className="rounded-lg border border-slate-200 p-3">
              <Link href={item.href} className="hover:text-primary tap-target">
                {item.label}
              </Link>
            </li>
          ))}
        </ul>
      </Section>

      <Section tint>
        <div className="text-center flex flex-wrap justify-center gap-3">
          <CtaButton href={PRIMARY_CTA_HREF} />
          <CtaButton href={SECONDARY_CTA_HREF} variant="secondary" />
        </div>
        <p className="mt-4 text-center text-sm text-slate-600">
          Looking for integration specifics? Visit <Link href="/integrations" className="text-primary hover:underline">Integrations</Link>.
        </p>
      </Section>
    </>
  );
}
