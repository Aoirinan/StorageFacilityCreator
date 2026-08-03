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

## Documentation Hygiene

- Do not create new root-level status/summary files (e.g. `*_SUMMARY.md`, `*_STATUS.md`, `*_COMPLETE.md`, `*_REPORT.md`) as a side effect of a task. Put findings in the PR description or commit message instead — they don't need a permanently tracked file.
- Only `README.md`, `CHANGELOG.md`, `AGENTS.md`, and `RUNBOOK.md` belong at repo root. Reference docs that describe a specific feature or integration go in `docs/`. Point-in-time snapshots (deployment reports, audit results, "what changed" writeups) go in `docs/archive/` if they must be kept at all.
- If a doc in `docs/` describes something not yet built, title it clearly as planned/proposed and keep it out of root.
