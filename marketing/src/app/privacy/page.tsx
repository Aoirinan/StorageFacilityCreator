import type { Metadata } from 'next';
import { Section } from '@/components/Section';
import { A2pSnippet } from '@/components/A2pSnippet';
import { SITE_NAME, SUPPORT_EMAIL } from '@/config/site';

export const metadata: Metadata = {
  title: 'Privacy Policy',
  description: `Privacy policy for ${SITE_NAME}: data we collect, how we use it, sharing, retention, and your rights.`,
};

const LAST_UPDATED = 'February 26, 2026';

export default function PrivacyPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Privacy Policy</h1>
        <p className="mt-2 text-slate-600">
          Last updated: {LAST_UPDATED}.{' '}
          This document does not constitute legal advice.
        </p>
      </Section>

      <Section tint>
        <div className="prose prose-slate max-w-none">

          <h2 className="text-xl font-bold text-slate-900">1. Overview</h2>
          <p className="text-slate-600 mt-2">
            {SITE_NAME} ("we," "us," or "our") is a B2B SaaS platform for storage facility operators ("Customers"). This Privacy Policy explains how we collect, use, share, and protect information when Customers use our Service, and when Customers use the Service to manage their tenants ("End Users" or "Tenants"). By using our website and Service, you agree to this policy.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">2. Information We Collect</h2>
          <ul className="list-disc pl-6 text-slate-600 space-y-2 mt-2">
            <li>
              <strong>Account data:</strong> Name, email address, phone number (if provided), business/facility name, and billing information when you register or subscribe.
            </li>
            <li>
              <strong>Facility and operational data:</strong> Information you enter about your facilities, units, rates, and settings.
            </li>
            <li>
              <strong>Tenant data entered by Customers:</strong> Information about your tenants that you input into the Service (e.g., names, contact details, unit assignments, payment history, SMS consent records). This data is Customer Data; you are responsible for its lawful collection.
            </li>
            <li>
              <strong>Demo and contact requests:</strong> Name, email, phone, and any message you submit when requesting a demo or contacting support.
            </li>
            <li>
              <strong>Technical and log data:</strong> IP address, browser/device type, pages visited, timestamps, and similar technical information collected automatically for security, debugging, and service operation.
            </li>
            <li>
              <strong>Analytics data:</strong> Aggregate usage patterns to understand how the Service is used and to improve it. We do not sell this data.
            </li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">3. How We Use Information</h2>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>To create and manage your account and deliver the Service.</li>
            <li>To process payments and manage your subscription.</li>
            <li>To respond to demo requests and support inquiries.</li>
            <li>To send account-related communications (e.g., billing notices, product updates).</li>
            <li>To send SMS or email messages to Tenants on your behalf, where Tenants have opted in.</li>
            <li>To detect, prevent, and respond to security incidents and abuse.</li>
            <li>To improve the Service, fix bugs, and develop new features.</li>
            <li>To comply with legal obligations.</li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">4. Messaging (SMS / Email)</h2>
          <p className="text-slate-600 mt-2">
            When Customers use the Service to send SMS or email messages to their Tenants, those messages are sent on the Customer's behalf. Tenants must opt in before receiving SMS. We require opt-in and support opt-out (STOP) and help (HELP) flows.
          </p>
          <div className="mt-4 p-4 bg-slate-50 rounded-lg">
            <A2pSnippet />
          </div>
          <p className="text-slate-600 mt-4">
            See our <a href="/sms-terms" className="text-primary hover:underline">SMS Terms</a> for full details on consent, opt-out, and message frequency.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">5. Sharing and Subprocessors</h2>
          <p className="text-slate-600 mt-2">
            We share data with third-party vendors and processors that help us operate the Service. We require them to protect your data and use it only for the purposes we specify. We do not sell your personal information or Customer Data to third parties.
          </p>
          <p className="text-slate-600 mt-2">
            Our current subprocessors include Google Cloud/Firebase (infrastructure), Stripe (payments), and Twilio/SendGrid (messaging). See our full <a href="/subprocessors" className="text-primary hover:underline">Subprocessor List</a> for details.
          </p>
          <p className="text-slate-600 mt-2">
            We may also disclose information if required by law, court order, or to protect the rights, property, or safety of {SITE_NAME}, our Customers, or others.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">6. Data Retention and Deletion</h2>
          <p className="text-slate-600 mt-2">
            We retain Customer Data for as long as your account is active and for a reasonable period afterward to comply with legal obligations, resolve disputes, and enforce our agreements. When you cancel your account, we will delete or anonymize your Customer Data within a reasonable timeframe, unless retention is required by law.
          </p>
          <p className="text-slate-600 mt-2">
            To request deletion of your data, contact us at{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">7. Your Rights</h2>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li><strong>SMS opt-out:</strong> Tenants may reply STOP to opt out of SMS at any time. Reply HELP for help.</li>
            <li><strong>Email unsubscribe:</strong> Use the unsubscribe link in any marketing email.</li>
            <li><strong>Access and correction:</strong> Contact us to request access to or correction of your personal data.</li>
            <li><strong>Deletion:</strong> Contact us to request deletion of your account and associated data, subject to applicable law.</li>
          </ul>
          <p className="text-slate-600 mt-2">
            Submit requests to:{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">8. Children</h2>
          <p className="text-slate-600 mt-2">
            The Service is not directed to children under 13, and we do not knowingly collect personal information from children under 13. If you believe we have inadvertently collected such information, please contact us and we will delete it promptly.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">9. Security</h2>
          <p className="text-slate-600 mt-2">
            We use reasonable technical and organizational measures to protect your data, including encryption in transit and access controls. See our <a href="/security" className="text-primary hover:underline">Security Overview</a> for more detail.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">10. Changes to This Policy</h2>
          <p className="text-slate-600 mt-2">
            We may update this policy from time to time. When we do, we will update the "Last updated" date at the top and, for material changes, notify you by email or in-app notice. Continued use of the Service after changes constitutes acceptance of the updated policy.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">11. Contact</h2>
          <p className="text-slate-600 mt-2">
            For privacy questions or requests:{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>.
          </p>
        </div>
      </Section>
    </>
  );
}
