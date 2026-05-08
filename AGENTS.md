# Agent Guardrails

## Functions Integrations Safety

- Primary codebase for payment/integration changes is `functions-integrations`.
- Do not rename exported Firebase function symbols without updating all re-export barrels and `functions-integrations/src/index.ts`.
- Prefer thin callable wrappers with logic in helper modules when changing behavior.
- Before considering a change done in `functions-integrations`, run:
  - `npm run build` in `functions-integrations`
  - `npm test` in `functions-integrations`
  - `firebase deploy --only functions:integrations --dry-run` from repo root
- Preserve existing callable names for backward compatibility with clients.

## Refactor Policy

- Do not do pure tidy refactors unless they support an active bug fix or feature.
- Prioritize user-visible outcomes and regression safety over additional file splitting.
