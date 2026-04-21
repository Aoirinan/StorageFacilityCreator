import Link from 'next/link';
import { Section } from '@/components/Section';
import { PRIMARY_CTA_HREF, PRIMARY_CTA_LABEL } from '@/config/site';

export const metadata = {
  title: 'Page not found',
  robots: { index: false, follow: false },
};

export default function NotFound() {
  return (
    <Section className="bg-gradient-to-b from-blue-50 via-white to-indigo-50/60 py-16 sm:py-24">
      <div className="mx-auto max-w-2xl text-center">
        <p className="font-display text-7xl sm:text-8xl font-extrabold bg-gradient-to-br from-primary to-indigo-500 bg-clip-text text-transparent">
          404
        </p>
        <h1 className="font-display mt-4 text-3xl sm:text-4xl font-extrabold text-slate-900">
          We couldn&apos;t find that page.
        </h1>
        <p className="mt-3 text-slate-600">
          The link may be out of date, or the page may have been moved. Try one of these instead:
        </p>
        <ul
          role="list"
          className="mt-8 grid grid-cols-2 sm:grid-cols-3 gap-3 text-sm font-medium"
        >
          {[
            { href: '/', label: 'Home' },
            { href: '/features', label: 'Features' },
            { href: '/pricing', label: 'Pricing' },
            { href: '/security', label: 'Security' },
            { href: '/faq', label: 'FAQ' },
            { href: '/contact', label: 'Contact' },
          ].map(({ href, label }) => (
            <li key={href}>
              <Link
                href={href}
                className="block rounded-lg border border-slate-200 bg-white px-4 py-3 text-slate-700 shadow-xs transition-all hover:-translate-y-0.5 hover:border-primary hover:text-primary hover:shadow-sm"
              >
                {label}
              </Link>
            </li>
          ))}
        </ul>
        <div className="mt-10">
          <Link
            href={PRIMARY_CTA_HREF}
            className="inline-flex items-center justify-center rounded-lg bg-primary px-6 py-3 text-sm font-semibold text-white shadow-sm hover:bg-primary-dark transition-colors"
          >
            {PRIMARY_CTA_LABEL}
          </Link>
        </div>
      </div>
    </Section>
  );
}
