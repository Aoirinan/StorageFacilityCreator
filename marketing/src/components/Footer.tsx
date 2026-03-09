import Link from 'next/link';
import Image from 'next/image';
import { LOGO_PATH, SITE_NAME, SITE_VERSION, SUPPORT_EMAIL, SUPPORT_PHONE } from '@/config/site';

const PRODUCT_LINKS = [
  { href: '/features', label: 'Features' },
  { href: '/pricing', label: 'Pricing' },
  { href: '/faq', label: 'FAQ' },
  { href: '/contact', label: 'Schedule a Demo' },
];

const LEGAL_LINKS = [
  { href: '/terms', label: 'Terms of Service' },
  { href: '/privacy', label: 'Privacy Policy' },
  { href: '/cookies', label: 'Cookie Policy' },
  { href: '/acceptable-use', label: 'Acceptable Use' },
  { href: '/billing', label: 'Billing & Refunds' },
  { href: '/sms-terms', label: 'SMS Terms' },
  { href: '/esign-disclosure', label: 'E-Sign Disclosure' },
];

const TRUST_LINKS = [
  { href: '/security', label: 'Security' },
  { href: '/subprocessors', label: 'Subprocessors' },
  { href: '/dpa', label: 'DPA' },
];

const CURRENT_YEAR = new Date().getFullYear();

export function Footer() {
  return (
    <footer className="bg-slate-900 text-slate-300">
      <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8 pt-14 pb-10">

        {/* Top grid */}
        <div className="grid grid-cols-2 md:grid-cols-4 gap-10 mb-12">

          {/* Brand — spans full width on mobile, 1 col on md */}
          <div className="col-span-2 md:col-span-1 flex flex-col gap-4">
            <Link href="/" className="flex items-center gap-2 w-fit">
              <Image
                src={LOGO_PATH}
                alt={SITE_NAME}
                width={36}
                height={36}
                className="h-9 w-auto object-contain opacity-90"
              />
              <span className="font-bold text-white text-base leading-tight">{SITE_NAME}</span>
            </Link>
            <p className="text-slate-400 text-sm leading-relaxed max-w-xs">
              Flat-rate management software built for independent storage facility operators. Tenants, billing, SMS reminders — one place.
            </p>
            {SUPPORT_EMAIL && (
              <a
                href={`mailto:${SUPPORT_EMAIL}`}
                className="text-slate-400 hover:text-white text-sm transition-colors"
              >
                {SUPPORT_EMAIL}
              </a>
            )}
            {SUPPORT_PHONE && (
              <a
                href={`tel:${SUPPORT_PHONE.replace(/\D/g, '')}`}
                className="text-slate-400 hover:text-white text-sm transition-colors"
              >
                {SUPPORT_PHONE}
              </a>
            )}
          </div>

          {/* Product */}
          <div>
            <p className="text-xs font-semibold uppercase tracking-wider text-slate-500 mb-4">Product</p>
            <nav className="flex flex-col gap-2.5" aria-label="Product links">
              {PRODUCT_LINKS.map(({ href, label }) => (
                <Link
                  key={href}
                  href={href}
                  className="text-slate-400 hover:text-white text-sm transition-colors"
                >
                  {label}
                </Link>
              ))}
            </nav>
          </div>

          {/* Legal */}
          <div>
            <p className="text-xs font-semibold uppercase tracking-wider text-slate-500 mb-4">Legal</p>
            <nav className="flex flex-col gap-2.5" aria-label="Legal links">
              {LEGAL_LINKS.map(({ href, label }) => (
                <Link
                  key={href}
                  href={href}
                  className="text-slate-400 hover:text-white text-sm transition-colors"
                >
                  {label}
                </Link>
              ))}
            </nav>
          </div>

          {/* Trust & Security */}
          <div>
            <p className="text-xs font-semibold uppercase tracking-wider text-slate-500 mb-4">Trust</p>
            <nav className="flex flex-col gap-2.5" aria-label="Trust links">
              {TRUST_LINKS.map(({ href, label }) => (
                <Link
                  key={href}
                  href={href}
                  className="text-slate-400 hover:text-white text-sm transition-colors"
                >
                  {label}
                </Link>
              ))}
            </nav>
          </div>
        </div>

        {/* Bottom bar */}
        <div className="pt-8 border-t border-slate-700/60 flex flex-wrap items-center justify-between gap-3 text-xs text-slate-500">
          <p>© {CURRENT_YEAR} {SITE_NAME}. All rights reserved.</p>
          <p aria-label="Site version">v{SITE_VERSION}</p>
        </div>

      </div>
    </footer>
  );
}
