import Link from 'next/link';

const LINKS = [
  { href: '/terms', label: 'Terms' },
  { href: '/privacy', label: 'Privacy' },
  { href: '/cookies', label: 'Cookies' },
  { href: '/acceptable-use', label: 'Acceptable Use' },
  { href: '/billing', label: 'Billing and Refunds' },
  { href: '/sms-terms', label: 'SMS Terms' },
  { href: '/esign-disclosure', label: 'E-Sign Disclosure' },
  { href: '/subprocessors', label: 'Subprocessors' },
  { href: '/dpa', label: 'DPA' },
];

export function LegalLinksPanel() {
  return (
    <div className="mt-8 rounded-xl border border-slate-200 bg-slate-50 p-4">
      <p className="text-xs font-semibold uppercase tracking-wide text-slate-500">Related legal and compliance pages</p>
      <ul className="mt-3 flex flex-wrap gap-x-4 gap-y-2 text-sm">
        {LINKS.map((item) => (
          <li key={item.href}>
            <Link href={item.href} className="text-primary hover:underline">
              {item.label}
            </Link>
          </li>
        ))}
      </ul>
    </div>
  );
}
