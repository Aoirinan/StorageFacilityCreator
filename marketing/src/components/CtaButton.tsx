import Link from 'next/link';

type Props = {
  href?: string;
  children: React.ReactNode;
  primary?: boolean;
  className?: string;
};

export function CtaButton({ href = '/contact', children, primary = true, className = '' }: Props) {
  const base =
    'inline-flex items-center justify-center rounded-lg font-medium transition-colors px-5 py-2.5 text-sm ';
  const styles = primary
    ? 'bg-primary text-white hover:bg-primary-dark'
    : 'border border-slate-300 bg-white text-slate-700 hover:bg-slate-50';

  return (
    <Link href={href} className={base + styles + ' ' + className}>
      {children}
    </Link>
  );
}
