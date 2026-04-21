'use client';

import Image from 'next/image';
import { useEffect, useState } from 'react';

type Slide = { src: string; alt: string; caption: string };

const SLIDES: Slide[] = [
  {
    src: '/sfc_dashboard_hero_clean.png',
    alt: 'Storage Facility Creator dashboard overview',
    caption: 'Dashboard overview',
  },
  {
    src: '/how-it-works-tenants.png',
    alt: 'Storage Facility Creator tenants list',
    caption: 'Tenants & balances',
  },
  {
    src: '/how-it-works-autopay.png',
    alt: 'Storage Facility Creator autopay controls',
    caption: 'Autopay controls',
  },
  {
    src: '/how-it-works-delinquency.png',
    alt: 'Storage Facility Creator delinquency workflows',
    caption: 'Delinquency workflows',
  },
];

const INTERVAL_MS = 3600;

/**
 * Hero dashboard frame that crossfades between product screenshots.
 * Pauses on hover/focus and respects prefers-reduced-motion.
 */
export function HeroShowcase() {
  const [index, setIndex] = useState(0);
  const [paused, setPaused] = useState(false);

  useEffect(() => {
    if (paused) return;
    if (typeof window !== 'undefined') {
      const mq = window.matchMedia('(prefers-reduced-motion: reduce)');
      if (mq.matches) return;
    }
    const id = window.setInterval(() => {
      setIndex((i) => (i + 1) % SLIDES.length);
    }, INTERVAL_MS);
    return () => window.clearInterval(id);
  }, [paused]);

  return (
    <div
      className="relative rounded-xl overflow-hidden shadow-xl border border-slate-200/80 bg-white"
      onMouseEnter={() => setPaused(true)}
      onMouseLeave={() => setPaused(false)}
      onFocus={() => setPaused(true)}
      onBlur={() => setPaused(false)}
    >
      <div className="flex items-center gap-2 px-4 py-3 border-b border-slate-200 bg-slate-50/80">
        <span className="w-3 h-3 rounded-full bg-slate-300" aria-hidden />
        <span className="w-3 h-3 rounded-full bg-slate-300" aria-hidden />
        <span className="w-3 h-3 rounded-full bg-slate-300" aria-hidden />
        <span className="ml-auto text-xs font-medium text-slate-500" aria-live="polite">
          {SLIDES[index].caption}
        </span>
      </div>

      <div className="relative aspect-4/3 sm:aspect-video bg-slate-100">
        {SLIDES.map((s, i) => (
          <div
            key={s.src}
            className="hero-slide absolute inset-0"
            data-active={i === index}
            aria-hidden={i !== index}
          >
            <Image
              src={s.src}
              alt={s.alt}
              fill
              className="object-contain"
              sizes="(max-width: 768px) 100vw, 50vw"
              priority={i === 0}
            />
          </div>
        ))}
      </div>

      <div className="flex items-center justify-center gap-2 border-t border-slate-200 bg-slate-50/80 py-2">
        {SLIDES.map((s, i) => (
          <button
            key={s.src}
            type="button"
            aria-label={`Show ${s.caption}`}
            aria-current={i === index ? 'true' : undefined}
            onClick={() => setIndex(i)}
            className={`h-1.5 rounded-full transition-all ${
              i === index ? 'w-6 bg-primary' : 'w-2 bg-slate-300 hover:bg-slate-400'
            }`}
          />
        ))}
      </div>
    </div>
  );
}
