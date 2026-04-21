'use client';

import Link from 'next/link';
import { useEffect, useState } from 'react';
import { PRIMARY_CTA_HREF, PRIMARY_CTA_LABEL, SECONDARY_CTA_HREF, SECONDARY_CTA_LABEL } from '@/config/site';

const DISMISS_KEY = 'sfc.sticky-cta.dismissed.v1';

/**
 * Thin fixed bar on mobile only. Offers primary + secondary CTA.
 * Dismissible for the session via localStorage.
 */
export function StickyMobileCta() {
  const [visible, setVisible] = useState(false);

  useEffect(() => {
    if (typeof window === 'undefined') return;
    const dismissed = window.localStorage.getItem(DISMISS_KEY) === '1';
    if (dismissed) return;

    // Reveal after a short scroll so it doesn't cover the hero on load.
    const onScroll = () => {
      if (window.scrollY > 320) {
        setVisible(true);
        window.removeEventListener('scroll', onScroll);
      }
    };
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => window.removeEventListener('scroll', onScroll);
  }, []);

  useEffect(() => {
    if (typeof document === 'undefined') return;
    document.body.classList.toggle('has-sticky-cta', visible);
    return () => {
      document.body.classList.remove('has-sticky-cta');
    };
  }, [visible]);

  if (!visible) return null;

  return (
    <div
      className="fixed inset-x-0 bottom-0 z-40 sm:hidden border-t border-slate-200 bg-white/95 backdrop-blur-md shadow-[0_-4px_16px_-8px_rgba(15,23,42,0.15)]"
      role="region"
      aria-label="Quick actions"
    >
      <div className="mx-auto flex max-w-6xl items-center gap-2 px-3 py-2.5">
        <Link
          href={PRIMARY_CTA_HREF}
          className="flex-1 inline-flex items-center justify-center rounded-lg bg-primary px-4 py-2.5 text-sm font-semibold text-white shadow-sm active:bg-primary-dark"
        >
          {PRIMARY_CTA_LABEL}
        </Link>
        <Link
          href={SECONDARY_CTA_HREF}
          className="inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-4 py-2.5 text-sm font-semibold text-slate-700 active:bg-slate-50"
        >
          {SECONDARY_CTA_LABEL}
        </Link>
        <button
          type="button"
          onClick={() => {
            if (typeof window !== 'undefined') {
              window.localStorage.setItem(DISMISS_KEY, '1');
            }
            setVisible(false);
          }}
          className="inline-flex h-10 w-10 items-center justify-center rounded-lg text-slate-500 hover:bg-slate-100"
          aria-label="Dismiss"
        >
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={2} className="h-5 w-5" aria-hidden>
            <path strokeLinecap="round" strokeLinejoin="round" d="M6 18L18 6M6 6l12 12" />
          </svg>
        </button>
      </div>
    </div>
  );
}
