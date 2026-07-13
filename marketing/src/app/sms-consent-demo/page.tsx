import type { Metadata } from 'next';
import Link from 'next/link';
import { Section } from '@/components/Section';
import { SITE_NAME, SUPPORT_EMAIL, SMS_CONSENT_CHECKBOX_TEXT } from '@/config/site';

export const metadata: Metadata = {
  title: 'SMS Opt-In Consent Demo',
  description: `Public demonstration of the tenant SMS opt-in consent step used by ${SITE_NAME} for A2P 10DLC carrier review.`,
  robots: { index: false, follow: true },
};

const LAST_UPDATED = 'July 13, 2026';

export default function SmsConsentDemoPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">
          SMS Opt-In Consent — Public Demonstration
        </h1>
        <p className="mt-2 text-slate-600">Last updated: {LAST_UPDATED}.</p>
        <p className="mt-3 text-slate-600 max-w-3xl">
          This page is a publicly accessible, exact reproduction of the SMS consent step that
          storage facility tenants see during tenant onboarding and move-in. The live form appears
          inside the operator&apos;s tenant management portal and on tenant-specific move-in links,
          which require authentication. This page exists so that carriers and messaging compliance
          reviewers can verify the opt-in flow without a login.
        </p>
      </Section>

      <Section tint>
        <div className="max-w-2xl">
          <h2 className="text-xl font-bold text-slate-900">How tenants opt in</h2>
          <ol className="list-decimal pl-6 text-slate-600 space-y-2 mt-3">
            <li>
              During move-in or account creation, the tenant (or facility staff, with the
              tenant present) enters the tenant&apos;s contact information.
            </li>
            <li>
              The form presents the SMS consent checkbox shown below. It is{' '}
              <strong>unchecked by default</strong> and must be actively checked to opt in.
            </li>
            <li>
              Consent is <strong>not</strong> a condition of renting a unit or of any purchase.
              Tenants who leave the box unchecked still complete move-in normally and are contacted
              by email or phone instead.
            </li>
            <li>
              When consent is given, the platform records the phone number, timestamp, consent text
              version, and session IP address. Replying STOP at any time opts the tenant out.
            </li>
          </ol>

          <h2 className="text-xl font-bold text-slate-900 mt-10">
            The consent step, exactly as tenants see it
          </h2>
          <p className="text-slate-600 mt-2 text-sm">
            The mock form below reproduces the relevant portion of the tenant onboarding form,
            including the exact consent language.
          </p>

          <div className="mt-4 rounded-xl border border-slate-200 bg-white p-6 shadow-sm">
            <p className="text-xs font-semibold uppercase tracking-wide text-slate-400">
              Tenant contact information (example)
            </p>

            <div className="mt-3 grid gap-4 sm:grid-cols-2">
              <label className="block text-sm">
                <span className="font-medium text-slate-700">Full name</span>
                <input
                  type="text"
                  readOnly
                  value="Jane Example"
                  className="mt-1 w-full rounded-lg border border-slate-300 bg-slate-50 px-3 py-2 text-slate-500"
                />
              </label>
              <label className="block text-sm">
                <span className="font-medium text-slate-700">Mobile phone</span>
                <input
                  type="text"
                  readOnly
                  value="(555) 555-0123"
                  className="mt-1 w-full rounded-lg border border-slate-300 bg-slate-50 px-3 py-2 text-slate-500"
                />
              </label>
            </div>

            <div className="mt-5 rounded-lg border border-slate-300 bg-slate-50 p-4">
              <label className="flex items-start gap-3 cursor-pointer">
                <input
                  type="checkbox"
                  defaultChecked={false}
                  className="mt-0.5 h-5 w-5 shrink-0 rounded border-slate-400 accent-blue-600"
                  aria-describedby="sms-consent-help"
                />
                <span className="text-sm leading-relaxed text-slate-700">
                  {SMS_CONSENT_CHECKBOX_TEXT}
                </span>
              </label>
              <p id="sms-consent-help" className="mt-3 pl-8 text-xs text-slate-500">
                Optional — leave unchecked to skip text messages. Consent is not a condition of
                renting a unit. See the{' '}
                <Link href="/sms-terms" className="text-primary hover:underline">
                  SMS Terms
                </Link>{' '}
                and{' '}
                <Link href="/privacy" className="text-primary hover:underline">
                  Privacy Policy
                </Link>
                .
              </p>
            </div>
          </div>

          <h2 className="text-xl font-bold text-slate-900 mt-10">Program disclosures</h2>
          <ul className="list-disc pl-6 text-slate-600 space-y-1 mt-3">
            <li>
              <strong>Message types:</strong> account notifications only — payment reminders,
              past-due notices, gate/access code information, move-in and move-out confirmations,
              and operational notices from the tenant&apos;s storage facility.
            </li>
            <li>
              <strong>Message frequency:</strong> varies with account activity.
            </li>
            <li>
              <strong>Cost:</strong> message and data rates may apply.
            </li>
            <li>
              <strong>Opt out:</strong> reply <strong>STOP</strong> to any message. Reply{' '}
              <strong>HELP</strong> for help.
            </li>
            <li>
              <strong>Privacy:</strong> mobile numbers and consent records are never sold or shared
              with third parties for their marketing. See the{' '}
              <Link href="/privacy" className="text-primary hover:underline">
                Privacy Policy
              </Link>
              .
            </li>
          </ul>

          <p className="text-slate-600 mt-8 text-sm">
            Questions about this flow? Contact{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">
              {SUPPORT_EMAIL}
            </a>
            . Full program terms:{' '}
            <Link href="/sms-terms" className="text-primary hover:underline">
              SMS Terms
            </Link>
            .
          </p>
        </div>
      </Section>
    </>
  );
}
