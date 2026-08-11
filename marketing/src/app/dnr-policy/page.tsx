import type { Metadata } from 'next';
import Link from 'next/link';
import { Section } from '@/components/Section';
import { LegalLinksPanel } from '@/components/LegalLinksPanel';
import { SITE_NAME, SUPPORT_EMAIL } from '@/config/site';

export const metadata: Metadata = {
  title: 'Do Not Rent Data Policy',
  description: `How ${SITE_NAME} governs Do Not Rent entries: submission requirements, safeguards, and the dispute and correction process.`,
  alternates: { canonical: '/dnr-policy' },
};

const LAST_UPDATED = 'July 18, 2026';

/// Exact text shown in the in-app one-time DNR participation acceptance dialog.
/// Keep aligned with lib/services/dnr_terms_service.dart (termsVersion 1.0).
const PARTICIPATION_AGREEMENT_BULLETS = [
  'Entries you submit must be factual, based on your facility\u2019s direct business experience, and supported by your internal records.',
  'Entries must not be based on race, color, religion, national origin, sex, familial status, disability, age, or any other protected characteristic, and must not be used for harassment or retaliation.',
  'You are solely responsible for your entries and must promptly correct or deactivate any entry you learn is inaccurate or unsupported.',
  'Entries from other facilities are provided "as is" and are not verified by Storage Facility Creator. This list is not a consumer report and may not be used as one, nor as the sole basis for a rental decision where the law requires more.',
  'Storage Facility Creator is a technology provider only. It does not create, verify, endorse, or adopt entries and, to the maximum extent permitted by law, is not liable for any claims, damages, or losses arising from entries submitted by operators. You agree to defend, indemnify, and hold harmless Storage Facility Creator from any claim arising from entries you or your staff submit, as set out in the Terms of Service.',
  'Storage Facility Creator may deactivate or remove any entry at any time, at its sole discretion, without notice.',
  'Disputed entries follow the dispute and correction process in the Do Not Rent Data Policy, and entries that cannot be substantiated will be removed.',
];

export default function DnrPolicyPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Do Not Rent Data Policy</h1>
        <p className="mt-2 text-slate-600">
          Last updated: {LAST_UPDATED}.{' '}
          This document does not constitute legal advice.
        </p>
        <p className="mt-3 text-sm text-slate-600 max-w-3xl">
          This policy governs the "Do Not Rent" (DNR) features of the Service: who can create entries, what
          entries must contain, the safeguards applied before an entry is shared, and how individuals and
          facilities can dispute or correct an entry.
        </p>
      </Section>

      <Section tint>
        <div className="prose prose-slate max-w-4xl legal-prose leading-relaxed">

          <h2 className="text-xl font-bold text-slate-900">1. What the DNR Features Are (and Are Not)</h2>
          <p className="text-slate-600 mt-2">
            The DNR features let storage facility operators ("Customers") document individuals with whom their
            facility has had a direct, adverse business experience (for example, property damage, non-payment
            with abandonment, or threats to staff), and optionally share those entries with other participating
            facilities on the platform.
          </p>
          <p className="text-slate-600 mt-2">
            {SITE_NAME} is a technology provider hosting Customer-generated business records. {SITE_NAME} is not
            a consumer reporting agency, DNR entries are not consumer reports under the Fair Credit Reporting
            Act (FCRA), and the DNR features may not be used as a substitute for a background check or consumer
            report. Customers that obtain or use consumer reports in rental decisions are solely responsible for
            FCRA and analogous state-law compliance.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">2. Who Can Create Entries</h2>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Only authenticated facility owners and managers on active paid subscriptions can create entries; the restriction is enforced server-side.</li>
            <li>Facility-level entries additionally require a verification code sent to the facility's registered email address before saving.</li>
            <li>Every entry permanently records the identity of the submitting user and facility, and the date of submission.</li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">3. Entry Requirements and Prohibited Content</h2>
          <p className="text-slate-600 mt-2">Every entry must:</p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Be factual, based on the submitting facility's direct business experience, and supported by the facility's internal records (which supporting evidence can be attached to document).</li>
            <li>Include a documented, business-related reason.</li>
            <li>Be affirmed through a mandatory accuracy attestation at submission, confirming the entry is factual, supported by records, and not based on any protected characteristic. The attestation is stored with the entry.</li>
          </ul>
          <p className="text-slate-600 mt-2">Entries must not:</p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Be based on race, color, religion, national origin, sex, familial status, disability, age, or any other characteristic protected by applicable law.</li>
            <li>Contain protected-class information, speculation, rumor, or content submitted for harassment or retaliation.</li>
            <li>Include information the submitting facility is not authorized to share.</li>
          </ul>
          <p className="text-slate-600 mt-2">
            Entries that violate these requirements may be deactivated or removed by {SITE_NAME} at any time,
            and repeated violations may result in suspension under our{' '}
            <Link href="/acceptable-use" className="text-primary hover:underline">Acceptable Use Policy</Link> and{' '}
            <Link href="/terms" className="text-primary hover:underline">Terms of Service</Link>.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">4. How Entries Are Used by Other Facilities</h2>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Shared entries are visible only to participating operators — authenticated accounts with an active paid subscription that have accepted these terms — never to the public. Both conditions are enforced server-side on every access, and lapsed accounts lose access automatically.</li>
            <li>Entries created by other Customers are provided "as is"; {SITE_NAME} does not verify, endorse, or adopt them.</li>
            <li>A match against a DNR entry is a flag for the operator's own review, not an automated decision. Operators reviewing an in-app match may override it after their own evaluation, and overrides are logged.</li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">5. Disputes, Corrections, and Removal</h2>
          <p className="text-slate-600 mt-2">
            An individual who believes an entry about them is inaccurate, unsupported, or unlawful — or a
            facility acting on their behalf — may dispute the entry by emailing{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>{' '}
            with the subject line "DNR Dispute" and enough information to identify the entry (name, and the
            email or phone number associated with it). The process is:
          </p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li><strong>Acknowledgment:</strong> we acknowledge disputes within 5 business days.</li>
            <li><strong>Review:</strong> we flag the disputed entry and route the dispute to the submitting facility, which must substantiate the entry with its internal records or correct/deactivate it.</li>
            <li><strong>Resolution:</strong> entries that the submitting facility cannot substantiate, or that violate this policy, are deactivated or removed. We aim to resolve disputes within 30 days.</li>
          </ul>
          <p className="text-slate-600 mt-2">
            Submitting facilities can correct, deactivate, set an expiration date on, or delete their own
            entries at any time, and are required by our Terms to do so promptly when they learn an entry is
            inaccurate or unsupported. Changes to entries are recorded in an audit log.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">6. Participation Agreement</h2>
          <p className="text-slate-600 mt-2">
            Before an operator can view or contribute to the shared DNR list, they must record a one-time
            acceptance of the following terms in the application (version 1.0). The acceptance is stored with
            the operator's identity, account, and timestamp. This is the exact text presented:
          </p>
          <div className="mt-4 rounded-xl border border-slate-200 bg-slate-50 p-5">
            <p className="text-sm font-semibold text-slate-900">Do Not Rent Terms</p>
            <p className="text-sm text-slate-700 mt-2">
              The Do Not Rent (DNR) list is shared between participating Storage Facility Creator operators.
              By participating you agree that:
            </p>
            <ul className="list-disc pl-6 text-sm text-slate-700 space-y-2 mt-3">
              {PARTICIPATION_AGREEMENT_BULLETS.map((bullet) => (
                <li key={bullet.slice(0, 40)}>{bullet}</li>
              ))}
            </ul>
          </div>

          <h2 className="text-xl font-bold text-slate-900 mt-8">7. Responsibility and Liability</h2>
          <p className="text-slate-600 mt-2">
            The submitting Customer is solely responsible for the accuracy, legality, and non-discriminatory
            nature of its entries, and agrees to defend, indemnify, and hold harmless {SITE_NAME} from any
            claims arising from them, as set out in Sections 9 and 13 of our{' '}
            <Link href="/terms" className="text-primary hover:underline">Terms of Service</Link>.
          </p>
          <p className="text-slate-600 mt-2">
            {SITE_NAME} is a technology provider only. It does not create, verify, endorse, or adopt
            Customer-submitted entries and, to the maximum extent permitted by applicable law, disclaims all
            liability for claims, damages, or losses arising from them. {SITE_NAME} reserves the right to
            deactivate or permanently remove any entry at any time, at its sole discretion, without notice.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">8. Contact</h2>
          <p className="text-slate-600 mt-2">
            Questions about this policy or the dispute process:{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>.
          </p>
          <LegalLinksPanel />
        </div>
      </Section>
    </>
  );
}
