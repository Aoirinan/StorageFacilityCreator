import { CtaButton } from '@/components/CtaButton';
import { PRIMARY_CTA_HREF, SECONDARY_CTA_HREF } from '@/config/site';

type Props = {
  title?: string;
  subtitle?: string;
};

export function PageCtaBand({
  title = 'Ready to see if SFC is a fit?',
  subtitle = 'Start a free trial conversation or book a guided demo.',
}: Props) {
  return (
    <div className="rounded-2xl border border-slate-200 bg-gradient-to-b from-white to-slate-50 p-5 sm:p-8 text-center">
      <span className="eyebrow">Get Started</span>
      <h2 className="text-xl sm:text-2xl font-bold text-slate-900">{title}</h2>
      <p className="mt-2 text-slate-600 max-w-2xl mx-auto">{subtitle}</p>
      <div className="mt-6 flex flex-wrap justify-center gap-3">
        <CtaButton href={PRIMARY_CTA_HREF} />
        <CtaButton href={SECONDARY_CTA_HREF} variant="secondary" />
      </div>
      <p className="mt-4 text-xs text-slate-500">No onboarding fee. Flat monthly pricing. Built for self-storage operators.</p>
    </div>
  );
}
