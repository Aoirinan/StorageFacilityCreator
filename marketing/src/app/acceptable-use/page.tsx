import type { Metadata } from 'next';
import Link from 'next/link';
import { Section } from '@/components/Section';
import { LegalLinksPanel } from '@/components/LegalLinksPanel';
import { SITE_NAME, SUPPORT_EMAIL } from '@/config/site';

export const metadata: Metadata = {
  title: 'Acceptable Use Policy',
  description: `Acceptable use policy for ${SITE_NAME}: what is and is not permitted when using the Service.`,
};

const LAST_UPDATED = 'February 26, 2026';

export default function AcceptableUsePage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Acceptable Use Policy</h1>
        <p className="mt-2 text-slate-600">Last updated: {LAST_UPDATED}.</p>
        <p className="mt-1 text-slate-600">
          This policy applies to all Customers and users of the {SITE_NAME} Service. It supplements our{' '}
          <Link href="/terms" className="text-primary hover:underline">Terms of Service</Link>.
        </p>
      </Section>

      <Section tint>
        <div className="prose prose-slate max-w-4xl legal-prose leading-relaxed">

          <h2 className="text-xl font-bold text-slate-900">Permitted Use</h2>
          <p className="text-slate-600 mt-2">
            You may use the Service to manage your storage facility operations, including tenant management, billing, unit tracking, and authorized communications with your tenants who have opted in to receive messages.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Prohibited Activities</h2>
          <p className="text-slate-600 mt-2">You must not use the Service to:</p>

          <h3 className="text-lg font-semibold text-slate-800 mt-6">Illegal Activity</h3>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Engage in or facilitate any activity that violates applicable local, state, federal, or international law or regulation.</li>
            <li>Store, transmit, or process data in a way that violates privacy laws or data protection regulations.</li>
            <li>Facilitate fraud, money laundering, or other financial crimes.</li>
          </ul>

          <h3 className="text-lg font-semibold text-slate-800 mt-6">Harassment and Harmful Content</h3>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Harass, threaten, defame, or intimidate any person.</li>
            <li>Transmit content that is abusive, discriminatory, or hateful based on race, ethnicity, religion, gender, sexual orientation, disability, or other protected characteristics.</li>
            <li>Engage in or facilitate stalking or unauthorized surveillance.</li>
          </ul>

          <h3 className="text-lg font-semibold text-slate-800 mt-6">Unauthorized Access and Security</h3>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Attempt to gain unauthorized access to the Service, other accounts, or any related systems or networks.</li>
            <li>Probe, scan, or test the vulnerability of the Service without our written authorization.</li>
            <li>Circumvent, disable, or interfere with security features of the Service.</li>
            <li>Upload, transmit, or distribute malware, viruses, ransomware, spyware, or any other malicious code.</li>
          </ul>

          <h3 className="text-lg font-semibold text-slate-800 mt-6">Spam and Messaging Abuse</h3>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Send unsolicited bulk messages (spam) via SMS, email, or any other channel.</li>
            <li>Send SMS or email messages to recipients who have not opted in or who have opted out.</li>
            <li>Use the Service to send messages that are deceptive, misleading, or that impersonate another person or organization.</li>
            <li>Violate the Telephone Consumer Protection Act (TCPA), CAN-SPAM Act, or any other applicable messaging law or carrier requirement.</li>
          </ul>

          <h3 className="text-lg font-semibold text-slate-800 mt-6">Reverse Engineering and Scraping</h3>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Reverse engineer, decompile, disassemble, or attempt to derive the source code of the Service.</li>
            <li>Use automated tools to scrape, crawl, or extract data from the Service beyond normal use.</li>
            <li>Copy or reproduce any part of the Service to build a competing product.</li>
          </ul>

          <h3 className="text-lg font-semibold text-slate-800 mt-6">Other Prohibited Conduct</h3>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Resell or sublicense access to the Service without our written consent.</li>
            <li>Interfere with or disrupt the integrity or performance of the Service or other users' access.</li>
            <li>Use the Service in any way that imposes an unreasonable or disproportionately large load on our infrastructure.</li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Enforcement</h2>
          <p className="text-slate-600 mt-2">
            Violation of this policy may result in suspension or termination of your account, without refund, and may be reported to law enforcement where appropriate. We reserve the right to investigate suspected violations and to take any action we deem necessary to protect the Service, our users, and third parties.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Reporting Violations</h2>
          <p className="text-slate-600 mt-2">
            If you become aware of any violation of this policy, please report it to us at{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Changes</h2>
          <p className="text-slate-600 mt-2">
            We may update this policy from time to time. Material changes will be communicated via email or in-app notice. Continued use of the Service after changes constitutes acceptance.
          </p>
          <LegalLinksPanel />
        </div>
      </Section>
    </>
  );
}
