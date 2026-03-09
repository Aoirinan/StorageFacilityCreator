import type { Metadata } from 'next';
import { Section } from '@/components/Section';
import { A2pSnippet } from '@/components/A2pSnippet';
import { SITE_NAME, SUPPORT_EMAIL } from '@/config/site';

export const metadata: Metadata = {
  title: 'SMS Terms',
  description: `SMS terms for ${SITE_NAME}: consent, opt-out, message frequency, and carrier disclosures.`,
};

const LAST_UPDATED = 'February 26, 2026';
const CONSENT_TEXT_VERSION = '2026-02-26-v1';

export default function SmsTermsPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">SMS Terms</h1>
        <p className="mt-2 text-slate-600">Last updated: {LAST_UPDATED}.</p>
        <p className="mt-1 text-slate-500 text-sm">Consent text version: {CONSENT_TEXT_VERSION}</p>
      </Section>

      <Section tint>
        <div className="prose prose-slate max-w-none">

          <h2 className="text-xl font-bold text-slate-900">Who Sends Messages</h2>
          <p className="text-slate-600 mt-2">
            {SITE_NAME} is a B2B software platform used by storage facility operators ("Customers"). When a Customer uses the Service to send SMS messages to their tenants ("End Users"), those messages are sent by {SITE_NAME} on the Customer's behalf using Twilio as the SMS delivery provider. The Customer is the responsible party for obtaining lawful consent from their tenants.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Consent Requirement</h2>
          <p className="text-slate-600 mt-2">
            Before any End User receives an SMS message through the Service, they must provide express written consent. Consent is obtained via an unchecked checkbox presented to the Customer during tenant creation or onboarding. The consent checkbox text reads:
          </p>
          <blockquote className="mt-4 p-4 bg-slate-50 border-l-4 border-primary rounded-r-lg text-slate-700 italic">
            "I consent to receive SMS notifications regarding my storage account. Message frequency varies. Reply STOP to opt out."
          </blockquote>
          <p className="text-slate-600 mt-4">
            The checkbox is unchecked by default and must be actively checked by the Customer (on behalf of the tenant, with the tenant's knowledge) or by the tenant directly. Consent is not a condition of service.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Consent Logging</h2>
          <p className="text-slate-600 mt-2">
            When consent is recorded, the Service logs:
          </p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>The tenant's phone number</li>
            <li>The timestamp of consent</li>
            <li>The version of the consent text presented (consent text version identifier)</li>
            <li>The IP address of the session where available</li>
          </ul>
          <p className="text-slate-600 mt-2">
            These records are maintained to demonstrate compliance with applicable messaging laws.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Types of Messages</h2>
          <p className="text-slate-600 mt-2">
            SMS messages sent through the Service may include:
          </p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Payment reminders and billing notifications</li>
            <li>Past-due and delinquency notices</li>
            <li>Account updates and important notices</li>
            <li>Access code information</li>
            <li>Move-in and move-out confirmations</li>
            <li>Responses to tenant inquiries</li>
          </ul>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Message Frequency</h2>
          <p className="text-slate-600 mt-2">
            Message frequency varies based on account activity and the communications configured by the facility operator. There is no fixed number of messages per month. Frequency depends on billing cycles, payment status, and facility communication preferences.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Message and Data Rates</h2>
          <p className="text-slate-600 mt-2">
            Message and data rates may apply. Standard rates charged by the recipient's mobile carrier apply to SMS messages sent and received. {SITE_NAME} and the facility operator are not responsible for carrier charges.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">How to Opt Out</h2>
          <p className="text-slate-600 mt-2">
            End Users may opt out of SMS messages at any time by replying <strong>STOP</strong> to any message. After sending STOP, a confirmation message will be sent and no further SMS messages will be sent unless the End User opts back in. Opt-outs are processed promptly.
          </p>
          <p className="text-slate-600 mt-2">
            To opt back in, the End User should contact the facility directly or update preferences through the facility's tenant portal.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">How to Get Help</h2>
          <p className="text-slate-600 mt-2">
            End Users may reply <strong>HELP</strong> to any message for assistance. They may also contact the facility directly or reach {SITE_NAME} support at{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Customer Responsibility</h2>
          <p className="text-slate-600 mt-2">
            Customers (facility operators) are responsible for:
          </p>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-2">
            <li>Obtaining lawful consent from tenants before enabling SMS messaging.</li>
            <li>Ensuring that tenant phone numbers are accurate and belong to the tenant.</li>
            <li>Complying with the Telephone Consumer Protection Act (TCPA), CAN-SPAM Act, and all applicable messaging laws and carrier requirements.</li>
            <li>Honoring opt-out requests promptly.</li>
          </ul>
          <p className="text-slate-600 mt-2">
            {SITE_NAME} provides the technical infrastructure for messaging but does not independently verify that each Customer has obtained proper consent. Customers indemnify {SITE_NAME} for any claims arising from their messaging activities. See our{' '}
            <a href="/terms" className="text-primary hover:underline">Terms of Service</a> for the full indemnification clause.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">A2P 10DLC Compliance</h2>
          <div className="mt-4 p-4 bg-slate-50 rounded-lg">
            <A2pSnippet />
          </div>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Privacy</h2>
          <p className="text-slate-600 mt-2">
            Phone numbers and SMS consent records are handled in accordance with our{' '}
            <a href="/privacy" className="text-primary hover:underline">Privacy Policy</a>. Phone numbers are shared with Twilio solely for the purpose of SMS delivery. See our{' '}
            <a href="/subprocessors" className="text-primary hover:underline">Subprocessor List</a> for details.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Contact</h2>
          <p className="text-slate-600 mt-2">
            Questions about SMS:{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>.
          </p>
        </div>
      </Section>
    </>
  );
}
