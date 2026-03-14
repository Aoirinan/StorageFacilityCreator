import type { Metadata } from 'next';
import { Section } from '@/components/Section';
import { LegalLinksPanel } from '@/components/LegalLinksPanel';
import { SITE_NAME, SUPPORT_EMAIL, PRICE_MONTHLY, TRIAL_LINE } from '@/config/site';

export const metadata: Metadata = {
  title: 'Billing & Refund Policy',
  description: `Billing and refund policy for ${SITE_NAME}: subscription renewal, cancellation, refunds, and chargebacks.`,
};

const LAST_UPDATED = 'February 26, 2026';

export default function BillingPage() {
  return (
    <>
      <Section className="pt-12 pb-8">
        <h1 className="text-3xl sm:text-4xl font-bold text-slate-900">Billing &amp; Refund Policy</h1>
        <p className="mt-2 text-slate-600">Last updated: {LAST_UPDATED}.</p>
      </Section>

      <Section tint>
        <div className="prose prose-slate max-w-4xl legal-prose leading-relaxed">

          <h2 className="text-xl font-bold text-slate-900">Subscription Pricing</h2>
          <p className="text-slate-600 mt-2">
            {SITE_NAME} is billed at a flat rate of <strong>${PRICE_MONTHLY}/month</strong> per account. There are no per-unit fees, onboarding fees, or hidden charges. Pricing is displayed on our{' '}
            <a href="/pricing" className="text-primary hover:underline">Pricing page</a> and confirmed at signup.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Trial Period</h2>
          <p className="text-slate-600 mt-2">
            We may offer a trial period (e.g., {TRIAL_LINE}). Trial terms, including duration and any conditions, will be clearly stated at signup. No payment method is required during the trial unless stated otherwise.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Billing Cycle and Renewal</h2>
          <p className="text-slate-600 mt-2">
            Subscriptions are billed monthly, in advance, on the anniversary of your subscription start date. Your subscription renews automatically each month unless you cancel before the renewal date. You will receive a receipt by email for each charge.
          </p>
          <p className="text-slate-600 mt-2">
            Payment is processed through Stripe, our third-party payment processor. By subscribing, you authorize us to charge your payment method on a recurring basis.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Cancellation</h2>
          <p className="text-slate-600 mt-2">
            You may cancel your subscription at any time through your account settings or by contacting support. Cancellation takes effect at the end of the current billing period — you will retain access to the Service through the end of the period you have already paid for.
          </p>
          <p className="text-slate-600 mt-2">
            After cancellation, your account data will be retained for a reasonable period before deletion, as described in our{' '}
            <a href="/privacy" className="text-primary hover:underline">Privacy Policy</a>.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Refund Policy</h2>
          <p className="text-slate-600 mt-2">
            <strong>We do not provide refunds for partial billing periods.</strong> If you cancel mid-month, you will not receive a prorated refund for unused days; your access continues until the end of the period.
          </p>
          <p className="text-slate-600 mt-2">
            Exceptions may be made at our sole discretion in cases of billing errors or extraordinary circumstances. To request a refund consideration, contact us at{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>{' '}
            within 30 days of the charge in question.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Failed Payments</h2>
          <p className="text-slate-600 mt-2">
            If a payment fails, we will attempt to notify you by email. We may retry the charge. If payment is not received within a reasonable period, your account may be suspended or downgraded until payment is resolved. Continued non-payment may result in account termination.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Chargebacks</h2>
          <p className="text-slate-600 mt-2">
            If you initiate a chargeback with your bank or card issuer for a charge you believe was unauthorized, please contact us first at{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>{' '}
            — we can often resolve billing disputes faster than the chargeback process. Initiating a chargeback without first contacting us may result in immediate suspension of your account.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Taxes</h2>
          <p className="text-slate-600 mt-2">
            Subscription fees are exclusive of taxes. Where applicable law requires us to collect sales tax, VAT, or similar taxes, those amounts will be added to your invoice. You are responsible for any taxes applicable to your purchase under the laws of your jurisdiction.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Price Changes</h2>
          <p className="text-slate-600 mt-2">
            We reserve the right to change subscription pricing. We will provide at least 30 days' advance notice of any price increase by email. Continued use of the Service after the effective date of a price change constitutes your acceptance of the new pricing.
          </p>

          <h2 className="text-xl font-bold text-slate-900 mt-8">Contact</h2>
          <p className="text-slate-600 mt-2">
            Billing questions or disputes:{' '}
            <a href={`mailto:${SUPPORT_EMAIL}`} className="text-primary hover:underline">{SUPPORT_EMAIL}</a>.
          </p>
          <LegalLinksPanel />
        </div>
      </Section>
    </>
  );
}
