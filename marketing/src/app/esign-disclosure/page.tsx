import type { Metadata } from 'next';
import Link from 'next/link';
import { Section } from '@/components/Section';
import { LegalLinksPanel } from '@/components/LegalLinksPanel';
import { SITE_NAME, SUPPORT_EMAIL } from '@/config/site';

export const metadata: Metadata = {
  title: 'Electronic Signature Disclosure',
  description: `Electronic signature disclosure and consent agreement for ${SITE_NAME}. Understand your rights before signing documents electronically.`,
};

const LAST_UPDATED = 'March 1, 2026';

export default function EsignDisclosurePage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">
          Electronic Signature Disclosure
        </h1>
        <p className="mt-2 text-slate-600">Last updated: {LAST_UPDATED}.</p>
        <p className="mt-1 text-slate-600">
          This document does not constitute legal advice.
        </p>
      </Section>

      <Section tint>
        <div className="prose prose-slate max-w-4xl legal-prose leading-relaxed">

          <h2 className="text-xl font-bold text-slate-900">Overview</h2>
          <p className="text-slate-600 mt-2">
            This Electronic Signature Disclosure and Consent Agreement (the "Agreement") contains
            important information about your rights when consenting to receive electronic records or
            provide electronic signatures through the {SITE_NAME} platform. Please read it carefully
            before proceeding.
          </p>
          <p className="text-slate-600 mt-2">
            {SITE_NAME} is a storage facility management platform used by storage facility operators
            ("Customers") to manage tenant agreements, rental contracts, and related documents.
            When a Customer uses our platform to present you with a document for electronic
            signature, this Agreement governs that process.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">
            1. Electronic Records and Signatures
          </h2>
          <p className="text-slate-600 mt-2">
            By agreeing to use electronic signatures, you consent to:
          </p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>
              Receiving all required notices, disclosures, authorizations, acknowledgments, and
              related documents in electronic format rather than paper.
            </li>
            <li>
              Signing documents electronically, which carries the same legal effect as a
              handwritten signature under applicable law, including the Electronic Signatures in
              Global and National Commerce Act (E-SIGN) and the Uniform Electronic Transactions
              Act (UETA).
            </li>
            <li>
              Your electronic signature being legally binding on any document you sign through the
              platform.
            </li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">
            2. System Requirements
          </h2>
          <p className="text-slate-600 mt-2">
            To access, sign, and retain electronic records, you will need:
          </p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>A personal computer, tablet, or smartphone with internet access</li>
            <li>A current, supported web browser (Chrome, Firefox, Safari, or Edge)</li>
            <li>A valid, active email address</li>
            <li>Software capable of opening PDF files (e.g., Adobe Acrobat Reader or equivalent)</li>
            <li>Sufficient storage on your device to save electronic documents</li>
          </ul>
          <p className="text-slate-600 mt-2">
            System requirements may change over time. If you are unable to access a document
            electronically, please contact the storage facility operator or reach us at{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">
              {SUPPORT_EMAIL}
            </a>.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">
            3. Scope of Consent
          </h2>
          <p className="text-slate-600 mt-2">
            Your consent applies to all documents presented to you electronically through the
            {SITE_NAME} platform in connection with your storage unit rental, including but not
            limited to:
          </p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Rental agreements and lease contracts</li>
            <li>Move-in and move-out documentation</li>
            <li>Rate change notices</li>
            <li>Lien notices and related legal notices required under applicable state law</li>
            <li>Autopay and payment authorization forms</li>
            <li>Any amendments or addenda to the above</li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">
            4. Withdrawing Your Consent
          </h2>
          <p className="text-slate-600 mt-2">
            You may withdraw your consent to receive records electronically at any time by
            contacting the storage facility operator directly, or by emailing us at{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">
              {SUPPORT_EMAIL}
            </a>{' '}
            with the subject line <strong>"Withdraw E-Sign Consent"</strong>. Include your full
            name, email address, mailing address, and phone number in the body of your message.
          </p>
          <p className="text-slate-600 mt-2">
            Please be aware that withdrawing consent may delay the completion of certain steps in
            your rental transaction, as you will need to receive and review documents in physical
            form before proceeding. The storage facility operator may also require in-person
            signing in that case.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">
            5. Requesting Paper Copies
          </h2>
          <p className="text-slate-600 mt-2">
            You may request a paper copy of any document that has been provided to you
            electronically. To do so, contact the storage facility operator directly, or email us
            at{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">
              {SUPPORT_EMAIL}
            </a>. Your request must include your full name, email address, mailing address, and
            phone number. A nominal per-page fee may apply for paper copies.
          </p>
          <p className="text-slate-600 mt-2">
            You may also download and print any document immediately after signing through the
            platform.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">
            6. Updating Your Email Address
          </h2>
          <p className="text-slate-600 mt-2">
            You are responsible for keeping your email address current so that electronic notices
            and documents can be delivered to you. To update your email address, contact the
            storage facility operator, or email us at{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">
              {SUPPORT_EMAIL}
            </a>{' '}
            with both your previous and new email address.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">
            7. Record Retention
          </h2>
          <p className="text-slate-600 mt-2">
            We recommend that you download and save or print a copy of any document you sign
            electronically for your own records. Signed documents are stored securely on the
            platform and may be accessed through your tenant portal or by contacting the storage
            facility operator.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">
            8. Consent and Agreement
          </h2>
          <p className="text-slate-600 mt-2">
            By selecting "I Agree," checking the consent checkbox, or otherwise indicating your
            acceptance within the signing interface, you certify that:
          </p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>You have read and understand this Agreement.</li>
            <li>You can print or save this Agreement for future reference.</li>
            <li>
              You consent to receiving notices and disclosures exclusively in electronic format as
              described herein.
            </li>
            <li>You have provided a working email address.</li>
            <li>
              You consent to signing documents electronically, and understand that your electronic
              signature is legally binding.
            </li>
            <li>
              Until or unless you notify us otherwise, you consent to receive all information from
              us exclusively through electronic means.
            </li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">
            9. Related Documents
          </h2>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>
              <Link href="/terms" className="text-primary hover:underline">Terms of Service</Link> —
              governs your use of the {SITE_NAME} platform
            </li>
            <li>
              <Link href="/privacy" className="text-primary hover:underline">Privacy Policy</Link> —
              how we collect, use, and protect your data
            </li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">10. Contact</h2>
          <p className="text-slate-600 mt-2">
            For questions about this Agreement, to withdraw consent, or to request paper copies,
            contact us at{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">
              {SUPPORT_EMAIL}
            </a>.
          </p>
          <LegalLinksPanel />

        </div>
      </Section>
    </>
  );
}
