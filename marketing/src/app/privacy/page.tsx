import type { Metadata } from 'next';
import { Section } from '@/components/Section';
import { A2pSnippet } from '@/components/A2pSnippet';
import { SITE_NAME, SUPPORT_EMAIL } from '@/config/site';

export const metadata: Metadata = {
  title: 'Privacy Policy',
  description: `Privacy policy for ${SITE_NAME}: data we collect, how we use it, and your rights.`,
};

export default function PrivacyPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Privacy Policy</h1>
        <p className="mt-2 text-slate-600">
          Last updated: {new Date().toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' })}.
          This is a baseline document and does not constitute legal advice.
        </p>
      </Section>

      <Section tint>
        <div className="prose prose-slate max-w-none">
          <h2 className="text-xl font-bold text-slate-900">Overview</h2>
          <p className="text-slate-600 mt-2">
            {SITE_NAME} (“we”) collects and uses information as described below. By using our website and services, you agree to this policy.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Information we collect</h2>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li><strong>Account and demo requests:</strong> Name, email, phone (if provided), facility name, and any message you submit when requesting a demo or contacting us.</li>
            <li><strong>Product usage:</strong> When you use our application, we collect data necessary to provide the service (e.g. tenant and facility data you enter, account and usage information).</li>
            <li><strong>Technical data:</strong> Logs, IP address, and similar technical information for security and operation.</li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">How we use it</h2>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>To create and manage your account and provide the product.</li>
            <li>To respond to demo requests and support inquiries.</li>
            <li>To send account-related communications and, where you opt in, SMS or email reminders and notices (see Messaging below).</li>
            <li>To improve our services, security, and compliance.</li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Messaging (SMS / email) and phone usage</h2>
          <p className="text-slate-600 mt-2">
            If you or your tenants provide a phone number and opt in, we may send account-related SMS messages (e.g. payment reminders, important updates). We require opt-in and support opt-out and help flows as described in our Terms and on the FAQ page.
          </p>
          <div className="mt-4 p-4 bg-slate-50 rounded-lg">
            <A2pSnippet />
          </div>
          <p className="text-slate-600 mt-4">
            For privacy requests related to messaging or personal data, contact us at{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Data sharing</h2>
          <p className="text-slate-600 mt-2">
            We may share data with vendors and processors that help us operate the service (e.g. hosting, email, SMS). We require them to protect your data and use it only for the purposes we specify. We do not sell your personal information.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Opt-out and your rights</h2>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li><strong>SMS:</strong> Reply STOP to opt out of SMS at any time. Reply HELP for help.</li>
            <li><strong>Email:</strong> You can unsubscribe from marketing emails using the link in the email.</li>
            <li><strong>Access and deletion:</strong> Contact us at <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a> to request access, correction, or deletion of your data, subject to applicable law.
            </li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Security</h2>
          <p className="text-slate-600 mt-2">
            We use reasonable measures to protect your data, including encryption in transit and access controls. See our Security page for more.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Changes</h2>
          <p className="text-slate-600 mt-2">
            We may update this policy from time to time. The “Last updated” date at the top will change. Continued use after changes constitutes acceptance.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Contact</h2>
          <p className="text-slate-600 mt-2">
            For privacy questions or requests: <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>.
          </p>
        </div>
      </Section>
    </>
  );
}
