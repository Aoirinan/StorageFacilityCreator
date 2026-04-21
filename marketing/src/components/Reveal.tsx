'use client';

import { useEffect, useRef, type ReactNode } from 'react';

type Props = {
  children: ReactNode;
  /** Optional tailwind classes applied alongside reveal. */
  className?: string;
  /** Optional ms delay for staggered reveals. */
  delay?: number;
  /** Render as a specific element. Defaults to div. */
  as?: 'div' | 'section' | 'article' | 'li' | 'span';
};

/**
 * Fades content in with a small translate on first viewport intersection.
 * Respects prefers-reduced-motion via CSS.
 */
export function Reveal({ children, className = '', delay, as = 'div' }: Props) {
  const ref = useRef<HTMLElement | null>(null);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;

    if (typeof IntersectionObserver === 'undefined') {
      el.classList.add('is-visible');
      return;
    }

    const observer = new IntersectionObserver(
      (entries) => {
        entries.forEach((entry) => {
          if (entry.isIntersecting) {
            const target = entry.target as HTMLElement;
            if (delay) {
              target.style.transitionDelay = `${delay}ms`;
            }
            target.classList.add('is-visible');
            observer.unobserve(target);
          }
        });
      },
      { threshold: 0.12, rootMargin: '0px 0px -40px 0px' },
    );

    observer.observe(el);
    return () => observer.disconnect();
  }, [delay]);

  const Tag = as as 'div';
  return (
    <Tag
      ref={ref as React.RefObject<HTMLDivElement>}
      className={`reveal ${className}`.trim()}
    >
      {children}
    </Tag>
  );
}
