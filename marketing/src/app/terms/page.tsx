import type { Metadata } from 'next';
import { Section } from '@/components/Section';
import { A2pSnippet } from '@/components/A2pSnippet';
import { SITE_NAME, SUPPORT_EMAIL, PRICE_MONTHLY, TRIAL_LINE } from '@/config/site';

export const metadata: Metadata = {
  title: 'Terms of Service',
  description: `Terms of service for ${SITE_NAME}: subscription, acceptable use, and messaging terms.`,
};

export default function TermsPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Terms of Service</h1>
        <p className="mt-2 text-slate-600">
          Last updated: {new Date().toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' })}.
          This is a baseline document and does not constitute legal advice.
        </p>
      </Section>

      <Section tint>
        <div className="prose prose-slate max-w-none">
          <h2 className="text-xl font-bold text-slate-900">Agreement</h2>
          <p className="text-slate-600 mt-2">
            By using {SITE_NAME} (“Service”), you agree to these Terms. If you are using the Service on behalf of an organization, you represent that you have authority to bind that organization.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Subscription</h2>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li><strong>Pricing:</strong> Subscription is billed at a flat rate of ${PRICE_MONTHLY}/month per account, as described on our Pricing page. There is no onboarding fee.</li>
            <li><strong>Trial:</strong> We may offer a trial (e.g. {TRIAL_LINE}). Trial terms will be stated at signup.</li>
            <li><strong>Payment:</strong> You agree to pay fees when due. Failure to pay may result in suspension or termination of access.</li>
            <li><strong>Cancellation:</strong> You may cancel in accordance with the subscription terms presented at signup or in your account. We do not provide refunds for partial periods unless required by law or stated in writing.</li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Acceptable use</h2>
          <p className="text-slate-600 mt-2">
            You agree to use the Service only for lawful purposes and in compliance with applicable laws. You may not: (a) misuse or attempt to gain unauthorized access to the Service or others’ data; (b) use the Service to send spam or unsolicited messages in violation of law; (c) transmit malware or interfere with the Service; or (d) use the Service in a way that harms us or third parties.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Messaging terms (SMS / email)</h2>
          <p className="text-slate-600 mt-2">
            Where the Service sends SMS or email to your tenants or contacts:
          </p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Recipients must opt in before receiving SMS. Message frequency varies. Message &amp; data rates may apply.</li>
            <li>Recipients may reply STOP to opt out at any time; we will process opt-outs promptly.</li>
            <li>Recipients may reply HELP for assistance; we provide clear support contact information.</li>
            <li>You are responsible for ensuring that your use of messaging (including tenant contact data and consent) complies with applicable law and carrier requirements. We do not represent that any particular campaign is “approved by carriers”; we describe our process and support opt-in/opt-out/help as stated.</li>
          </ul>
          <div className="mt-4 p-4 bg-slate-50 rounded-lg">
            <A2pSnippet />
          </div>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Data and privacy</h2>
          <p className="text-slate-600 mt-2">
            Our Privacy Policy describes how we collect, use, and protect data. By using the Service, you agree to that policy. You are responsible for the data you input and for complying with privacy laws applicable to your business.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Disclaimers</h2>
          <p className="text-slate-600 mt-2">
            The Service is provided “as is.” We disclaim all warranties, express or implied, to the extent permitted by law. We do not guarantee uninterrupted or error-free operation.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Limitation of liability</h2>
          <p className="text-slate-600 mt-2">
            To the maximum extent permitted by law, we are not liable for any indirect, incidental, special, consequential, or punitive damages, or for loss of profits, data, or business. Our total liability for any claim arising from the Service is limited to the amount you paid us in the twelve (12) months before the claim. Some jurisdictions do not allow these limitations; in such cases, our liability is limited to the maximum permitted.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Changes</h2>
          <p className="text-slate-600 mt-2">
            We may update these Terms. We will notify you of material changes (e.g. by email or in-app notice). Continued use after the effective date of changes constitutes acceptance. If you do not agree, you must stop using the Service and may cancel your subscription.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Contact</h2>
          <p className="text-slate-600 mt-2">
            Questions about these Terms: <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>.
          </p>
        </div>
      </Section>
    </>
  );
}
