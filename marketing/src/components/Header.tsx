'use client';

import Link from 'next/link';
import Image from 'next/image';
import { useState } from 'react';
import { usePathname } from 'next/navigation';
import {
  APP_LOGIN_URL,
  LOGO_PATH,
  NAV_LINKS,
  PRIMARY_CTA_HREF,
  PRIMARY_CTA_LABEL,
  SECONDARY_CTA_HREF,
  SECONDARY_CTA_LABEL,
  SITE_NAME,
} from '@/config/site';

export function Header() {
  const [menuOpen, setMenuOpen] = useState(false);
  const pathname = usePathname();

  return (
    <header className="sticky top-0 z-50 bg-white/95 backdrop-blur-sm border-b border-slate-200/80">
      <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8">
        <div className="flex h-16 items-center justify-between">
          <Link href="/" className="flex items-center gap-2 shrink-0" aria-label={`${SITE_NAME} home`}>
            <Image
              src={LOGO_PATH}
              alt={`${SITE_NAME} logo`}
              width={40}
              height={40}
              className="h-9 w-auto object-contain"
            />
            <span className="font-semibold text-slate-800 hidden sm:inline">{SITE_NAME}</span>
          </Link>

          <nav className="hidden md:flex items-center gap-8" aria-label="Main navigation">
            {NAV_LINKS.map(({ href, label }) => (
              <Link
                key={href}
                href={href}
                aria-current={pathname === href ? 'page' : undefined}
                className={`tap-target text-sm font-medium transition-colors ${
                  pathname === href ? 'text-slate-900' : 'text-slate-600 hover:text-slate-900'
                }`}
              >
                {label}
              </Link>
            ))}
          </nav>

          <div className="flex items-center gap-3">
            <Link
              href={PRIMARY_CTA_HREF}
              className="hidden sm:inline-flex items-center justify-center rounded-lg bg-primary px-4 py-2 text-sm font-medium text-white hover:bg-primary-dark transition-colors"
            >
              {PRIMARY_CTA_LABEL}
            </Link>
            <Link
              href={SECONDARY_CTA_HREF}
              className="hidden sm:inline-flex items-center justify-center rounded-lg border border-slate-300 bg-white px-4 py-2 text-sm font-medium text-slate-700 hover:bg-slate-50 transition-colors"
            >
              {SECONDARY_CTA_LABEL}
            </Link>
            <a href={APP_LOGIN_URL} className="hidden sm:inline-flex tap-target text-sm text-slate-600 hover:text-slate-900">
              Login
            </a>
            <button
              type="button"
              className="md:hidden p-2 rounded-lg text-slate-600 hover:bg-slate-100"
              aria-expanded={menuOpen}
              aria-label="Toggle menu"
              onClick={() => setMenuOpen((o) => !o)}
            >
              <svg className="h-6 w-6" fill="none" viewBox="0 0 24 24" stroke="currentColor" aria-hidden>
                {menuOpen ? (
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M6 18L18 6M6 6l12 12" />
                ) : (
                  <path strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} d="M4 6h16M4 12h16M4 18h16" />
                )}
              </svg>
            </button>
          </div>
        </div>

        {menuOpen && (
          <nav className="md:hidden py-4 border-t border-slate-200" aria-label="Mobile navigation">
            <ul className="flex flex-col gap-2">
              {NAV_LINKS.map(({ href, label }) => (
                <li key={href}>
                  <Link
                    href={href}
                    aria-current={pathname === href ? 'page' : undefined}
                    className={`block py-2 font-medium tap-target ${
                      pathname === href ? 'text-slate-900' : 'text-slate-600 hover:text-slate-900'
                    }`}
                    onClick={() => setMenuOpen(false)}
                  >
                    {label}
                  </Link>
                </li>
              ))}
              <li>
                <Link
                  href={PRIMARY_CTA_HREF}
                  className="block py-2 text-slate-600 hover:text-slate-900 font-medium"
                  onClick={() => setMenuOpen(false)}
                >
                  {PRIMARY_CTA_LABEL}
                </Link>
              </li>
              <li>
                <Link
                  href={SECONDARY_CTA_HREF}
                  className="block py-2 text-slate-600 hover:text-slate-900 font-medium"
                  onClick={() => setMenuOpen(false)}
                >
                  {SECONDARY_CTA_LABEL}
                </Link>
              </li>
              <li>
                <a
                  href={APP_LOGIN_URL}
                  className="block py-2 text-slate-600 hover:text-slate-900 font-medium"
                >
                  Login
                </a>
              </li>
            </ul>
          </nav>
        )}
      </div>
    </header>
  );
}
