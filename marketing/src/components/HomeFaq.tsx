'use client';

import Link from 'next/link';
import { useState } from 'react';
import { ONLINE_RENTALS_ADDON_MONTHLY, PRICE_MONTHLY, TRIAL_LINE } from '@/config/site';

type Item = { q: string; a: string };

const ITEMS: Item[] = [
  {
    q: 'What does SFC cost?',
    a: `$${PRICE_MONTHLY} per facility, per month. Each facility is a flat $${PRICE_MONTHLY}/month with unlimited users per facility and all core features included — no tiered modules, no per-seat pricing, no onboarding fee. Optional public website rentals (SEO-friendly online move-ins) add $${ONLINE_RENTALS_ADDON_MONTHLY}/month per facility when enabled. A ${TRIAL_LINE} is available so you can evaluate with real data before committing.`,
  },
  {
    q: 'Can we migrate from our current software or from spreadsheets?',
    a: 'Yes. Migration support is available based on your existing data and workflow complexity. Most operators can import units, tenants, and balances in a guided flow.',
  },
  {
    q: 'How does SFC handle payments and autopay?',
    a: 'Payments are processed by Stripe. We never see or store full card numbers or CVV codes — only tokenized payment method IDs and safe display info (last 4, brand, expiration). Autopay uses Stripe SetupIntent.',
  },
  {
    q: 'Does this replace my gate system?',
    a: 'No. SFC integrates with existing access controls; operators keep their hardware. We provide the software layer for managing access, billing, delinquency, messaging, and reporting.',
  },
  {
    q: 'How do teams sign in and get access?',
    a: 'Role-based access with MFA-ready auth. Invite teammates directly from the app. Each user only sees facilities they are assigned to, with audit logging for changes.',
  },
];

export function HomeFaq() {
  const [open, setOpen] = useState<number | null>(0);

  return (
    <ul role="list" className="mt-8 mx-auto max-w-3xl space-y-3">
      {ITEMS.map((item, i) => {
        const isOpen = open === i;
        return (
          <li key={item.q} className="overflow-hidden rounded-xl border border-slate-200 bg-white shadow-xs">
            <button
              type="button"
              aria-expanded={isOpen}
              onClick={() => setOpen(isOpen ? null : i)}
              className="flex w-full items-center justify-between gap-4 px-5 py-4 text-left font-semibold text-slate-900 transition-colors hover:bg-slate-50"
            >
              <span>{item.q}</span>
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth={2}
                className={`h-5 w-5 shrink-0 text-slate-400 transition-transform ${isOpen ? 'rotate-180' : ''}`}
                aria-hidden
              >
                <path strokeLinecap="round" strokeLinejoin="round" d="M6 9l6 6 6-6" />
              </svg>
            </button>
            <div
              className={`grid transition-all duration-300 ${
                isOpen ? 'grid-rows-[1fr] opacity-100' : 'grid-rows-[0fr] opacity-0'
              }`}
            >
              <div className="overflow-hidden">
                <p className="px-5 pb-5 text-slate-600 leading-relaxed">{item.a}</p>
              </div>
            </div>
          </li>
        );
      })}
      <li className="pt-2 text-center text-sm text-slate-600">
        More questions? Read the{' '}
        <Link href="/faq" className="text-primary font-medium hover:underline">
          full FAQ →
        </Link>
      </li>
    </ul>
  );
}
