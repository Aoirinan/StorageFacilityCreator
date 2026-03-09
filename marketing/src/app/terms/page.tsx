import type { Metadata } from 'next';
import { Section } from '@/components/Section';
import { A2pSnippet } from '@/components/A2pSnippet';
import { SITE_NAME, SUPPORT_EMAIL, PRICE_MONTHLY, TRIAL_LINE } from '@/config/site';

export const metadata: Metadata = {
  title: 'Terms of Service',
  description: `Terms of service for ${SITE_NAME}: subscription, acceptable use, messaging terms, and customer responsibilities.`,
};

const LAST_UPDATED = 'February 26, 2026';

export default function TermsPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Terms of Service</h1>
        <p className="mt-2 text-slate-600">
          Last updated: {LAST_UPDATED}.{' '}
          This document does not constitute legal advice.
        </p>
      </Section>

      <Section tint>
        <div className="prose prose-slate max-w-none">

          <h2 className="text-xl font-bold text-slate-900">1. Definitions</h2>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li><strong>"Service"</strong> means the Storage Facility Creator software platform, including all web and mobile interfaces, APIs, and related features.</li>
            <li><strong>"Customer"</strong> means the storage facility operator or business entity that subscribes to and uses the Service.</li>
            <li><strong>"End User" or "Tenant"</strong> means an individual whose data is entered into the Service by the Customer (e.g., a storage unit renter). End Users are customers of the Customer, not of {SITE_NAME}.</li>
            <li><strong>"Customer Data"</strong> means all data, content, and information submitted to the Service by or on behalf of the Customer, including Tenant data.</li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">2. Agreement</h2>
          <p className="text-slate-600 mt-2">
            By accessing or using the Service, you (the Customer) agree to these Terms of Service ("Terms"). If you are using the Service on behalf of an organization, you represent that you have authority to bind that organization to these Terms.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">3. License Grant and Restrictions</h2>
          <p className="text-slate-600 mt-2">
            Subject to your compliance with these Terms and timely payment of fees, {SITE_NAME} grants you a limited, non-exclusive, non-transferable, revocable license to access and use the Service for your internal business operations during the subscription term.
          </p>
          <p className="text-slate-600 mt-2">You may not:</p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Sublicense, resell, or transfer access to the Service to any third party.</li>
            <li>Reverse engineer, decompile, or attempt to extract the source code of the Service.</li>
            <li>Use the Service to build a competing product or service.</li>
            <li>Remove or obscure any proprietary notices in the Service.</li>
            <li>Use automated means to scrape, crawl, or extract data from the Service beyond normal use.</li>
          </ul>
          <p className="text-slate-600 mt-2">
            The Service is licensed, not sold. {SITE_NAME} retains all ownership and intellectual property rights in the Service.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">4. Subscription and Billing</h2>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li><strong>Pricing:</strong> Subscription is billed at ${PRICE_MONTHLY}/month per account, as described on our Pricing page. There is no onboarding fee.</li>
            <li><strong>Trial:</strong> We may offer a trial period (e.g. {TRIAL_LINE}). Trial terms will be stated at signup.</li>
            <li><strong>Payment:</strong> You agree to pay fees when due. Failure to pay may result in suspension or termination of access.</li>
            <li><strong>Renewal:</strong> Subscriptions renew automatically on a monthly basis unless cancelled before the renewal date.</li>
            <li><strong>Cancellation and Refunds:</strong> You may cancel at any time. Cancellation takes effect at the end of the current billing period. We do not provide refunds for partial periods unless required by applicable law or agreed to in writing. See our <a href="/billing" className="text-primary hover:underline">Billing &amp; Refund Policy</a> for details.</li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">5. Customer Responsibilities</h2>
          <p className="text-slate-600 mt-2">As a Customer, you are responsible for:</p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li><strong>Lawful use:</strong> Using the Service only for lawful purposes and in compliance with all applicable laws and regulations, including privacy and communications laws.</li>
            <li><strong>Tenant consent for messaging:</strong> Obtaining all legally required consents from your Tenants before sending them SMS or email communications through the Service. You must not send messages to Tenants who have not opted in or who have opted out.</li>
            <li><strong>Accuracy of data:</strong> Ensuring that Customer Data you enter is accurate, lawfully obtained, and does not infringe any third-party rights.</li>
            <li><strong>Account security:</strong> Maintaining the confidentiality of your account credentials and notifying us promptly of any unauthorized access.</li>
            <li><strong>Compliance:</strong> Complying with our <a href="/acceptable-use" className="text-primary hover:underline">Acceptable Use Policy</a> and all applicable carrier requirements for messaging.</li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">6. Customer Data</h2>
          <p className="text-slate-600 mt-2">
            You retain ownership of your Customer Data. By using the Service, you grant {SITE_NAME} a limited license to store, process, and use Customer Data solely to provide and improve the Service, as described in our <a href="/privacy" className="text-primary hover:underline">Privacy Policy</a>. We do not sell Customer Data to third parties.
          </p>
          <p className="text-slate-600 mt-2">
            You are responsible for ensuring that your collection and use of Tenant data complies with applicable privacy laws. {SITE_NAME} processes Tenant data on your behalf as a data processor.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">7. Third-Party Services</h2>
          <p className="text-slate-600 mt-2">
            The Service relies on third-party providers to deliver certain functionality. These include:
          </p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li><strong>Google Cloud / Firebase</strong> — cloud infrastructure, authentication, and database.</li>
            <li><strong>Stripe</strong> — payment processing and billing.</li>
            <li><strong>Twilio</strong> — SMS messaging delivery.</li>
            <li><strong>SendGrid (Twilio)</strong> — email delivery (where used).</li>
          </ul>
          <p className="text-slate-600 mt-2">
            Your use of the Service is subject to these providers' terms and policies. See our <a href="/subprocessors" className="text-primary hover:underline">Subprocessor List</a> for more detail.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">8. Messaging Terms (SMS / Email)</h2>
          <p className="text-slate-600 mt-2">
            Where the Service sends SMS or email to your Tenants on your behalf:
          </p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Tenants must opt in before receiving SMS. Message frequency varies. Message &amp; data rates may apply.</li>
            <li>Tenants may reply STOP to opt out at any time; opt-outs are processed promptly.</li>
            <li>Tenants may reply HELP for assistance.</li>
            <li>You (the Customer) are responsible for ensuring that your use of messaging — including Tenant contact data and consent — complies with applicable law and carrier requirements.</li>
            <li>{SITE_NAME} sends messages on your behalf; you remain the responsible party for lawful consent.</li>
          </ul>
          <div className="mt-4 p-4 bg-slate-50 rounded-lg">
            <A2pSnippet />
          </div>
          <p className="text-slate-600 mt-4">
            See our <a href="/sms-terms" className="text-primary hover:underline">SMS Terms</a> for the full SMS consent and opt-out policy.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">9. Availability and Maintenance</h2>
          <p className="text-slate-600 mt-2">
            We strive to maintain high availability but do not guarantee uninterrupted or error-free operation. We may perform scheduled or emergency maintenance that temporarily affects availability. We will make reasonable efforts to notify Customers of planned downtime.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">10. Disclaimers</h2>
          <p className="text-slate-600 mt-2">
            The Service is provided "as is" and "as available." We disclaim all warranties, express or implied, including warranties of merchantability, fitness for a particular purpose, and non-infringement, to the maximum extent permitted by applicable law.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">11. Limitation of Liability</h2>
          <p className="text-slate-600 mt-2">
            To the maximum extent permitted by applicable law, {SITE_NAME} is not liable for any indirect, incidental, special, consequential, or punitive damages, including loss of profits, data, or business opportunities, arising from or related to your use of the Service. Our total aggregate liability for any claim arising from the Service is limited to the amount you paid us in the twelve (12) months preceding the claim. Some jurisdictions do not allow these limitations; in such cases, our liability is limited to the maximum extent permitted.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">12. Indemnification</h2>
          <p className="text-slate-600 mt-2">
            You agree to indemnify and hold harmless {SITE_NAME} and its officers, employees, and agents from any claims, damages, losses, or expenses (including reasonable attorneys' fees) arising from: (a) your use of the Service in violation of these Terms; (b) your violation of applicable law; (c) your Customer Data; or (d) your messaging activities, including any failure to obtain required consents.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">13. Termination and Suspension</h2>
          <p className="text-slate-600 mt-2">
            We may suspend or terminate your access to the Service if you materially breach these Terms, fail to pay fees, or engage in activity that poses a risk to the Service or other users. You may terminate your subscription at any time by cancelling through your account. Upon termination, your access to the Service will end at the close of the current billing period, and we will handle your Customer Data as described in our Privacy Policy.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">14. Changes to Terms</h2>
          <p className="text-slate-600 mt-2">
            We may update these Terms from time to time. We will notify you of material changes by email or in-app notice at least 14 days before the changes take effect. Continued use of the Service after the effective date constitutes acceptance of the updated Terms. If you do not agree to the changes, you must stop using the Service and may cancel your subscription.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">15. Governing Law</h2>
          <p className="text-slate-600 mt-2">
            These Terms are governed by the laws of the State of Texas, without regard to conflict-of-law principles. Any disputes shall be resolved in the courts of Texas, and you consent to personal jurisdiction in that venue.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">16. Contact</h2>
          <p className="text-slate-600 mt-2">
            Questions about these Terms:{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>.
          </p>
        </div>
      </Section>
    </>
  );
}
