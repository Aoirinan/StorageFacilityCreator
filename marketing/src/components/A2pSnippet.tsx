import { A2P_COMPLIANCE_PARAGRAPH } from '@/config/site';

type Props = { brief?: boolean };

/** A2P 10DLC-compliant SMS consent text. Use brief on Home, full on FAQ/Privacy/Terms. */
export function A2pSnippet({ brief = false }: Props) {
  if (brief) {
    return (
      <p className="text-sm text-slate-600">
        SMS: opt-in required. Message frequency varies. Message &amp; data rates may apply. Reply STOP to opt out, HELP for help.
      </p>
    );
  }
  return (
    <p className="text-sm text-slate-600">
      {A2P_COMPLIANCE_PARAGRAPH}
    </p>
  );
}
