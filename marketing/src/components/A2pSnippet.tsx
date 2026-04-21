import { A2P_COMPLIANCE_PARAGRAPH } from '@/config/site';

type Props = {
  /** Brief single-line copy for the homepage footer / CTA. */
  brief?: boolean;
  /** Override the text color classes when placed on a non-light background. */
  className?: string;
};

/** A2P 10DLC-compliant SMS consent text. Use brief on Home, full on FAQ/Privacy/Terms. */
export function A2pSnippet({ brief = false, className }: Props) {
  const baseClass = className ?? 'text-sm text-slate-600';

  if (brief) {
    return (
      <p className={baseClass}>
        SMS: opt-in required. Message frequency varies. Message &amp; data rates may apply. Reply STOP to opt out, HELP for help.
      </p>
    );
  }
  return <p className={baseClass}>{A2P_COMPLIANCE_PARAGRAPH}</p>;
}
