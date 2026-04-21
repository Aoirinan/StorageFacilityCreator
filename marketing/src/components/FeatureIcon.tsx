import type { ReactNode } from 'react';

export type FeatureIconKey =
  | 'tenants'
  | 'units'
  | 'billing'
  | 'payments'
  | 'delinquency'
  | 'messaging'
  | 'dashboard'
  | 'map'
  | 'contracts'
  | 'integrations'
  | 'reporting';

type Tone =
  | 'blue'
  | 'indigo'
  | 'emerald'
  | 'amber'
  | 'rose'
  | 'violet'
  | 'sky'
  | 'teal';

type IconTheme = {
  tone: Tone;
  /** Tailwind bg-* class for the icon chip background */
  bg: string;
  /** Tailwind text-* class for the icon stroke */
  fg: string;
  /** Tailwind bg class for large screenshot placeholder panel */
  panel: string;
  /** Tailwind border class that complements the tone */
  border: string;
};

const THEME: Record<Tone, IconTheme> = {
  blue: {
    tone: 'blue',
    bg: 'bg-blue-100',
    fg: 'text-blue-700',
    panel: 'bg-gradient-to-br from-blue-50 to-blue-100/70',
    border: 'border-blue-200',
  },
  indigo: {
    tone: 'indigo',
    bg: 'bg-indigo-100',
    fg: 'text-indigo-700',
    panel: 'bg-gradient-to-br from-indigo-50 to-indigo-100/70',
    border: 'border-indigo-200',
  },
  emerald: {
    tone: 'emerald',
    bg: 'bg-emerald-100',
    fg: 'text-emerald-700',
    panel: 'bg-gradient-to-br from-emerald-50 to-emerald-100/70',
    border: 'border-emerald-200',
  },
  amber: {
    tone: 'amber',
    bg: 'bg-amber-100',
    fg: 'text-amber-700',
    panel: 'bg-gradient-to-br from-amber-50 to-amber-100/70',
    border: 'border-amber-200',
  },
  rose: {
    tone: 'rose',
    bg: 'bg-rose-100',
    fg: 'text-rose-700',
    panel: 'bg-gradient-to-br from-rose-50 to-rose-100/70',
    border: 'border-rose-200',
  },
  violet: {
    tone: 'violet',
    bg: 'bg-violet-100',
    fg: 'text-violet-700',
    panel: 'bg-gradient-to-br from-violet-50 to-violet-100/70',
    border: 'border-violet-200',
  },
  sky: {
    tone: 'sky',
    bg: 'bg-sky-100',
    fg: 'text-sky-700',
    panel: 'bg-gradient-to-br from-sky-50 to-sky-100/70',
    border: 'border-sky-200',
  },
  teal: {
    tone: 'teal',
    bg: 'bg-teal-100',
    fg: 'text-teal-700',
    panel: 'bg-gradient-to-br from-teal-50 to-teal-100/70',
    border: 'border-teal-200',
  },
};

const KEY_TO_TONE: Record<FeatureIconKey, Tone> = {
  tenants: 'blue',
  units: 'indigo',
  billing: 'emerald',
  payments: 'amber',
  delinquency: 'rose',
  messaging: 'violet',
  dashboard: 'sky',
  map: 'indigo',
  contracts: 'teal',
  integrations: 'violet',
  reporting: 'emerald',
};

export function getFeatureTheme(key: FeatureIconKey): IconTheme {
  return THEME[KEY_TO_TONE[key]];
}

const SVG_PROPS = {
  viewBox: '0 0 24 24',
  fill: 'none',
  stroke: 'currentColor',
  strokeWidth: 1.75,
  strokeLinecap: 'round' as const,
  strokeLinejoin: 'round' as const,
  'aria-hidden': true,
};

function Glyph({ k }: { k: FeatureIconKey }): ReactNode {
  switch (k) {
    case 'tenants':
      return (
        <svg {...SVG_PROPS}>
          <circle cx="9" cy="8" r="3.25" />
          <path d="M3.5 19c.6-3.1 3-5 5.5-5s4.9 1.9 5.5 5" />
          <circle cx="17" cy="9.5" r="2.5" />
          <path d="M15 19c.4-2.2 2-3.5 4-3.5 1 0 1.9.3 2.5.9" />
        </svg>
      );
    case 'units':
      return (
        <svg {...SVG_PROPS}>
          <rect x="3.5" y="4" width="7" height="7" rx="1.25" />
          <rect x="13.5" y="4" width="7" height="7" rx="1.25" />
          <rect x="3.5" y="13" width="7" height="7" rx="1.25" />
          <rect x="13.5" y="13" width="7" height="7" rx="1.25" />
        </svg>
      );
    case 'billing':
      return (
        <svg {...SVG_PROPS}>
          <path d="M5.5 3.5h10l3 3v14l-2-1.2-2 1.2-2-1.2-2 1.2-2-1.2-2 1.2-1-.6V3.5Z" />
          <path d="M8.5 9h7M8.5 13h7M8.5 16.5h4.5" />
        </svg>
      );
    case 'payments':
      return (
        <svg {...SVG_PROPS}>
          <rect x="2.75" y="6" width="18.5" height="12" rx="2" />
          <path d="M2.75 10h18.5" />
          <path d="M6 14.5h3M12 14.5h2" />
        </svg>
      );
    case 'delinquency':
      return (
        <svg {...SVG_PROPS}>
          <path d="M12 3.5 2.75 20h18.5L12 3.5Z" />
          <path d="M12 10v4.5" />
          <circle cx="12" cy="17.25" r="0.9" fill="currentColor" stroke="none" />
        </svg>
      );
    case 'messaging':
      return (
        <svg {...SVG_PROPS}>
          <path d="M4 5.5h12.5c1.1 0 2 .9 2 2v6c0 1.1-.9 2-2 2H11L7.5 19v-3.5H4c-1.1 0-2-.9-2-2v-6c0-1.1.9-2 2-2Z" />
          <path d="M6.5 9.5h8M6.5 12h6" />
        </svg>
      );
    case 'dashboard':
      return (
        <svg {...SVG_PROPS}>
          <rect x="3" y="3.5" width="7" height="9" rx="1.25" />
          <rect x="3" y="14.5" width="7" height="6" rx="1.25" />
          <rect x="13" y="3.5" width="8" height="6" rx="1.25" />
          <rect x="13" y="11.5" width="8" height="9" rx="1.25" />
        </svg>
      );
    case 'map':
      return (
        <svg {...SVG_PROPS}>
          <path d="M9 4 3.5 5.8v14L9 18l6 1.8 5.5-1.8v-14L15 5.8 9 4Z" />
          <path d="M9 4v14M15 5.8v14" />
        </svg>
      );
    case 'contracts':
      return (
        <svg {...SVG_PROPS}>
          <path d="M6 3.5h8l4 4v13H6V3.5Z" />
          <path d="M14 3.5v4h4" />
          <path d="M9 12h6M9 15.5h6M9 19h4" />
        </svg>
      );
    case 'integrations':
      return (
        <svg {...SVG_PROPS}>
          <circle cx="6.5" cy="6.5" r="2.5" />
          <circle cx="17.5" cy="6.5" r="2.5" />
          <circle cx="6.5" cy="17.5" r="2.5" />
          <circle cx="17.5" cy="17.5" r="2.5" />
          <path d="M9 6.5h6M6.5 9v6M17.5 9v6M9 17.5h6" />
        </svg>
      );
    case 'reporting':
      return (
        <svg {...SVG_PROPS}>
          <path d="M3.5 20h17" />
          <rect x="5" y="12" width="3" height="7" rx="0.5" />
          <rect x="10.5" y="8" width="3" height="11" rx="0.5" />
          <rect x="16" y="4.5" width="3" height="14.5" rx="0.5" />
        </svg>
      );
  }
}

type Size = 'sm' | 'md' | 'lg';

const SIZE_CLASSES: Record<Size, { box: string; icon: string }> = {
  sm: { box: 'h-9 w-9 rounded-lg', icon: 'h-5 w-5' },
  md: { box: 'h-11 w-11 rounded-xl', icon: 'h-6 w-6' },
  lg: { box: 'h-14 w-14 rounded-2xl', icon: 'h-8 w-8' },
};

type FeatureIconProps = {
  featureKey: FeatureIconKey;
  size?: Size;
  className?: string;
};

export function FeatureIcon({ featureKey, size = 'md', className = '' }: FeatureIconProps) {
  const theme = getFeatureTheme(featureKey);
  const sz = SIZE_CLASSES[size];
  return (
    <span
      className={`inline-flex items-center justify-center ${sz.box} ${theme.bg} ${theme.fg} ${className}`.trim()}
      aria-hidden
    >
      <span className={sz.icon}>
        <Glyph k={featureKey} />
      </span>
    </span>
  );
}

type FeatureVisualProps = {
  featureKey: FeatureIconKey;
  className?: string;
  /** Aspect helpers */
  aspect?: string;
};

/** Large decorative tile used where a screenshot would go. */
export function FeatureVisual({
  featureKey,
  className = '',
  aspect = 'aspect-4/3',
}: FeatureVisualProps) {
  const theme = getFeatureTheme(featureKey);
  return (
    <div
      className={`relative ${aspect} w-full overflow-hidden rounded-xl border ${theme.border} ${theme.panel} ${className}`.trim()}
      aria-hidden
    >
      <div className="absolute inset-0 opacity-60 [background-image:radial-gradient(circle_at_1px_1px,rgba(15,23,42,0.08)_1px,transparent_0)] [background-size:16px_16px]" />
      <div className="absolute inset-0 flex items-center justify-center">
        <FeatureIcon featureKey={featureKey} size="lg" className="shadow-sm ring-1 ring-white/60" />
      </div>
    </div>
  );
}
