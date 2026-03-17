# Leads Operations Hardening Checklist

Use this checklist to keep lead capture, rep accountability, and commission reporting secure and reliable.

## Monthly

- Review Superadmin access list in:
  - `lib/services/superadmin_service.dart`
  - `functions/src/index.ts`
  - `firestore.rules`
- Confirm only current staff have access.
- Remove former staff immediately.

## Quarterly

- Rotate `MARKETING_LEAD_CAPTURE_KEY`.
- Update the key in:
  - Firebase Functions secret (`MARKETING_LEAD_CAPTURE_KEY`)
  - Vercel env var (`MARKETING_LEAD_CAPTURE_KEY`)
- Verify `MARKETING_LEAD_CAPTURE_URL` still points to the current function endpoint.
- Submit one test lead and verify:
  - contact email notification is delivered
  - lead appears in Superadmin Leads tab
  - lead appears in Commission reporting for date range

## Release Validation

- Confirm funnel metrics render in Commission tab.
- Confirm payout CSV exports include:
  - period start/end
  - rep
  - won count
  - commissionable won count
  - sales totals
  - commission amount
- Confirm lead activity history records actor and summary for:
  - assignment
  - call logs
  - notes
  - won/lost updates

## Incident Response

- If suspicious lead-capture traffic is detected:
  - rotate `MARKETING_LEAD_CAPTURE_KEY` immediately
  - verify CORS and endpoint auth behavior
  - review recent `marketing_leads` entries for anomalies
  - review function logs for unauthorized attempts
