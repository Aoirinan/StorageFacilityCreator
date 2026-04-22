import { ImageResponse } from 'next/og';
import { SITE_NAME } from '@/config/site';

export const OG_SIZE = { width: 1200, height: 630 } as const;
export const OG_CONTENT_TYPE = 'image/png' as const;

export type OgAccent = 'blue' | 'emerald' | 'amber' | 'violet' | 'rose' | 'indigo';

const GRADIENTS: Record<OgAccent, { from: string; to: string; tint: string }> = {
  blue: { from: '#1e3a8a', to: '#2563eb', tint: '#93c5fd' },
  indigo: { from: '#3730a3', to: '#6366f1', tint: '#a5b4fc' },
  emerald: { from: '#065f46', to: '#10b981', tint: '#6ee7b7' },
  amber: { from: '#92400e', to: '#f59e0b', tint: '#fcd34d' },
  violet: { from: '#4c1d95', to: '#8b5cf6', tint: '#c4b5fd' },
  rose: { from: '#881337', to: '#f43f5e', tint: '#fda4af' },
};

type Options = {
  title: string;
  subtitle?: string;
  eyebrow?: string;
  accent?: OgAccent;
};

/** Renders a branded 1200x630 OG image for a marketing route. */
export function renderOgImage({ title, subtitle, eyebrow, accent = 'blue' }: Options) {
  const { from, to, tint } = GRADIENTS[accent];

  return new ImageResponse(
    (
      <div
        style={{
          width: '100%',
          height: '100%',
          display: 'flex',
          flexDirection: 'column',
          justifyContent: 'space-between',
          padding: '72px 80px',
          background: `linear-gradient(135deg, ${from} 0%, ${to} 100%)`,
          color: 'white',
          fontFamily: 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
          position: 'relative',
        }}
      >
        <div
          style={{
            position: 'absolute',
            top: -160,
            right: -100,
            width: 520,
            height: 520,
            borderRadius: '50%',
            background: `radial-gradient(circle, ${tint}55 0%, transparent 70%)`,
            filter: 'blur(20px)',
          }}
        />
        <div
          style={{
            position: 'absolute',
            bottom: -120,
            left: -80,
            width: 380,
            height: 380,
            borderRadius: '50%',
            background: 'radial-gradient(circle, rgba(255,255,255,0.18) 0%, transparent 70%)',
            filter: 'blur(20px)',
          }}
        />

        {/* Top brand row */}
        <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
          <div
            style={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              width: 56,
              height: 56,
              borderRadius: 14,
              background: 'rgba(255,255,255,0.18)',
              border: '1px solid rgba(255,255,255,0.35)',
              fontSize: 28,
              fontWeight: 800,
              letterSpacing: -1,
            }}
          >
            SFC
          </div>
          <div
            style={{
              fontSize: 22,
              fontWeight: 600,
              letterSpacing: -0.3,
              opacity: 0.95,
            }}
          >
            {SITE_NAME}
          </div>
        </div>

        {/* Headline block */}
        <div style={{ display: 'flex', flexDirection: 'column', gap: 18 }}>
          {eyebrow ? (
            <div
              style={{
                alignSelf: 'flex-start',
                padding: '8px 16px',
                borderRadius: 999,
                border: '1px solid rgba(255,255,255,0.4)',
                background: 'rgba(255,255,255,0.1)',
                fontSize: 18,
                fontWeight: 600,
                letterSpacing: 2,
                textTransform: 'uppercase',
              }}
            >
              {eyebrow}
            </div>
          ) : null}
          <div
            style={{
              fontSize: title.length > 40 ? 64 : 76,
              fontWeight: 800,
              letterSpacing: -2,
              lineHeight: 1.05,
              maxWidth: 960,
            }}
          >
            {title}
          </div>
          {subtitle ? (
            <div
              style={{
                fontSize: 28,
                fontWeight: 400,
                lineHeight: 1.35,
                maxWidth: 900,
                color: 'rgba(255,255,255,0.88)',
              }}
            >
              {subtitle}
            </div>
          ) : null}
        </div>

        {/* Footer */}
        <div
          style={{
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'space-between',
            fontSize: 20,
            fontWeight: 500,
            color: 'rgba(255,255,255,0.85)',
          }}
        >
          <div>www.storagefacilitycreator.com</div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <span style={{ opacity: 0.8 }}>Self-storage management software</span>
          </div>
        </div>
      </div>
    ),
    { ...OG_SIZE },
  );
}
