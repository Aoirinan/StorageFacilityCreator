import type { Metadata } from 'next';
import { Section } from '@/components/Section';
import { LegalLinksPanel } from '@/components/LegalLinksPanel';
import { SITE_NAME, SUPPORT_EMAIL } from '@/config/site';

export const metadata: Metadata = {
  title: 'Cookie Policy',
  description: `Cookie policy for ${SITE_NAME}: what cookies we use and how to control them.`,
  alternates: { canonical: '/cookies' },
};

const LAST_UPDATED = 'February 26, 2026';

export default function CookiesPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Cookie Policy</h1>
        <p className="mt-2 text-slate-600">Last updated: {LAST_UPDATED}.</p>
        <p className="mt-3 text-sm text-slate-600 max-w-3xl">
          This page describes the essential and preference-level cookie/storage behaviors used by SFC and how browser
          controls can be applied.
        </p>
      </Section>

      <Section tint>
        <div className="prose prose-slate max-w-4xl legal-prose leading-relaxed">

          <h2 className="text-xl font-bold text-slate-900">What Are Cookies?</h2>
          <p className="text-slate-600 mt-2">
            Cookies are small text files placed on your device by a website. They help the site remember information about your visit, such as your login session or preferences. We may also use similar technologies such as local storage and session storage.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Cookies We Use</h2>

          <h3 className="text-lg font-semibold text-slate-800 mt-6">Essential Cookies</h3>
          <p className="text-slate-600 mt-2">
            These cookies are required for the Service to function. They include session management, authentication tokens, and security tokens. Without these cookies, you cannot log in or use the application. You cannot opt out of essential cookies while using the Service.
          </p>
          <div className="mt-4 overflow-x-auto rounded-lg border border-slate-200">
            <table className="w-full min-w-[680px] text-sm text-slate-600 border-collapse">
              <thead>
                <tr className="bg-slate-100">
                  <th className="text-left p-3 border border-slate-200 font-semibold">Cookie / Storage Key</th>
                  <th className="text-left p-3 border border-slate-200 font-semibold">Purpose</th>
                  <th className="text-left p-3 border border-slate-200 font-semibold">Duration</th>
                </tr>
              </thead>
              <tbody>
                <tr>
                  <td className="p-3 border border-slate-200">Firebase Auth token</td>
                  <td className="p-3 border border-slate-200">Keeps you signed in to the application</td>
                  <td className="p-3 border border-slate-200">Session / until sign-out</td>
                </tr>
                <tr className="bg-slate-50">
                  <td className="p-3 border border-slate-200">Session / CSRF tokens</td>
                  <td className="p-3 border border-slate-200">Security and request integrity</td>
                  <td className="p-3 border border-slate-200">Session</td>
                </tr>
              </tbody>
            </table>
          </div>

          <h3 className="text-lg font-semibold text-slate-800 mt-6">Functional / Preference Cookies</h3>
          <p className="text-slate-600 mt-2">
            We may store user preferences (such as theme or display settings) in local storage to improve your experience. These are not shared with third parties.
          </p>

          <h3 className="text-lg font-semibold text-slate-800 mt-6">Analytics Cookies</h3>
          <p className="text-slate-600 mt-2">
            We may use aggregate, anonymized analytics to understand how the marketing site is used (e.g., page views, referral sources). If we add third-party analytics tools in the future, we will update this policy and provide opt-out guidance. Currently, we do not deploy third-party analytics trackers on this site.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">How to Control Cookies</h2>
          <p className="text-slate-600 mt-2">
            You can control cookies through your browser settings. Most browsers allow you to block or delete cookies. Note that blocking essential cookies will prevent you from logging in and using the Service. Browser-level controls vary; consult your browser's help documentation for instructions.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Changes to This Policy</h2>
          <p className="text-slate-600 mt-2">
            We may update this Cookie Policy as the Service evolves. Material changes will be reflected in the "Last updated" date above.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Contact</h2>
          <p className="text-slate-600 mt-2">
            Questions about cookies:{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>.
          </p>
          <LegalLinksPanel />
        </div>
      </Section>
    </>
  );
}
