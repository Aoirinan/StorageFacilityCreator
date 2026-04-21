type Partner = { name: string; tagline: string };

const PARTNERS: Partner[] = [
  { name: 'Stripe', tagline: 'Payments' },
  { name: 'Twilio', tagline: 'SMS' },
  { name: 'SendGrid', tagline: 'Email' },
  { name: 'QuickBooks', tagline: 'Accounting' },
  { name: 'Firebase', tagline: 'Infrastructure' },
];

/**
 * A small, tasteful "built on trusted infrastructure" logo strip.
 * Uses wordmark-style pills (not third-party brand logos) for zero trademark risk.
 */
export function IntegrationLogos() {
  return (
    <div className="mt-6">
      <p className="text-center text-xs font-semibold uppercase tracking-[0.18em] text-slate-500">
        Built on trusted infrastructure
      </p>
      <ul
        role="list"
        className="mt-5 flex flex-wrap items-center justify-center gap-3 sm:gap-4"
      >
        {PARTNERS.map(({ name, tagline }) => (
          <li
            key={name}
            className="group inline-flex items-center gap-2 rounded-full border border-slate-200 bg-white/80 px-4 py-2 shadow-xs backdrop-blur-sm transition-colors hover:border-blue-300 hover:bg-white"
          >
            <span
              className="inline-flex h-6 w-6 items-center justify-center rounded-md bg-gradient-to-br from-blue-500 to-indigo-600 text-[10px] font-bold text-white"
              aria-hidden
            >
              {name.charAt(0)}
            </span>
            <span className="text-sm font-semibold text-slate-800">{name}</span>
            <span className="hidden sm:inline text-xs text-slate-500">· {tagline}</span>
          </li>
        ))}
      </ul>
    </div>
  );
}
