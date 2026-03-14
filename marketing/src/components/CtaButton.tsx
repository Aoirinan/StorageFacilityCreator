import Link from 'next/link';
import {
  PRIMARY_CTA_HREF,
  PRIMARY_CTA_LABEL,
  SECONDARY_CTA_HREF,
  SECONDARY_CTA_LABEL,
  TERTIARY_CTA_HREF,
  TERTIARY_CTA_LABEL,
} from '@/config/site';

type Props = {
  href?: string;
  children?: React.ReactNode;
  variant?: 'primary' | 'secondary' | 'tertiary';
  className?: string;
};

export function CtaButton({ href, children, variant = 'primary', className = '' }: Props) {
  const base =
    'inline-flex items-center justify-center rounded-lg font-medium transition-colors px-5 py-2.5 text-sm whitespace-nowrap tap-target';
  const styles =
    variant === 'primary'
      ? 'bg-primary text-white hover:bg-primary-dark shadow-sm'
      : variant === 'secondary'
        ? 'border border-slate-300 bg-white text-slate-700 hover:bg-slate-50'
        : 'text-primary hover:text-primary-dark underline underline-offset-2';

  const defaultHref =
    variant === 'primary' ? PRIMARY_CTA_HREF : variant === 'secondary' ? SECONDARY_CTA_HREF : TERTIARY_CTA_HREF;
  const defaultLabel =
    variant === 'primary' ? PRIMARY_CTA_LABEL : variant === 'secondary' ? SECONDARY_CTA_LABEL : TERTIARY_CTA_LABEL;

  return (
    <Link href={href ?? defaultHref} className={`${base} ${styles} ${className}`.trim()}>
      {children ?? defaultLabel}
    </Link>
  );
}
