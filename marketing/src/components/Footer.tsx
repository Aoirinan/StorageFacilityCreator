import Link from 'next/link';
import Image from 'next/image';
import { LOGO_PATH, SITE_NAME, SITE_VERSION, SUPPORT_EMAIL, SUPPORT_PHONE } from '@/config/site';

const FOOTER_LINKS = [
  { href: '/privacy', label: 'Privacy Policy' },
  { href: '/terms', label: 'Terms of Service' },
  { href: '/contact', label: 'Contact' },
];

export function Footer() {
  return (
    <footer className="bg-slate-900 text-slate-300">
      <div className="mx-auto max-w-6xl px-4 sm:px-6 lg:px-8 py-12">
        <div className="flex flex-col md:flex-row md:items-center md:justify-between gap-8">
          <div className="flex items-center gap-2">
            <Image src={LOGO_PATH} alt="" width={32} height={32} className="h-8 w-auto object-contain opacity-90" />
            <span className="font-semibold text-white">{SITE_NAME}</span>
          </div>
          <nav className="flex flex-wrap gap-6" aria-label="Footer navigation">
            {FOOTER_LINKS.map(({ href, label }) => (
              <Link
                key={href}
                href={href}
                className="text-slate-400 hover:text-white text-sm font-medium transition-colors"
              >
                {label}
              </Link>
            ))}
          </nav>
        </div>
        <div className="mt-8 pt-8 border-t border-slate-700 text-sm flex flex-wrap items-center justify-between gap-4">
          <p className="text-slate-500">
            Support: <a href={`mailto:${SUPPORT_EMAIL}`} className="text-slate-400 hover:text-white">{SUPPORT_EMAIL}</a>
            {SUPPORT_PHONE && (
              <> · <a href={`tel:${SUPPORT_PHONE.replace(/\D/g, '')}`} className="text-slate-400 hover:text-white">{SUPPORT_PHONE}</a></>
            )}
          </p>
          <p className="text-slate-500" aria-label="Site version">
            v{SITE_VERSION}
          </p>
        </div>
      </div>
    </footer>
  );
}
