# CLAUDE.md

Map of the repo, not a tutorial. See [README.md](README.md) for quick start/hosting, [RUNBOOK.md](RUNBOOK.md) for GCP/cost ops, [AGENTS.md](AGENTS.md) for change-safety rules.

## Layout

- `lib/` — Flutter app (operator-facing), deployed to Firebase Hosting via `./deploy.ps1`.
- `marketing/` — Next.js marketing/SEO site, deployed to Vercel. Independent of `lib/` — do not mix hosting targets (see README's "Hosting source of truth" table).
- `functions-shared/` — common Cloud Functions code (types, Stripe/Firestore helpers, etc.). Not deployed on its own; every other `functions-*` package vendors its built output.
- `functions*` (`functions`, `functions-integrations`, `functions-ai`, `functions-admin`, `functions-automation`, `functions-facility-ops`, `functions-marketing`, `functions-messaging-twilio`, `functions-outbound-email`, `functions-public-website`, `functions-tenant-lifecycle`, `functions-account-security`) — one deployable Cloud Functions codebase per domain. Each has its own `package.json`, tests, and CI job.
- `firestore-rules-src/` — source fragments for `firestore.rules`, one file per collection (see `firestore-rules-src/README.md`). `firestore.rules` at repo root is generated from these via `node scripts/build_firestore_rules.cjs` — don't hand-edit `firestore.rules` directly.
- `firestore-rules-test/` — Firestore security rules tests, run against the emulator (Java 21 required).
- `scripts/` — repo-root Node/PowerShell utilities (vendoring, parity checks, hygiene checks — see below).
- `docs/` — feature/integration reference docs. `docs/archive/` — point-in-time snapshots (deployment reports, audits, "what changed" writeups) kept for history, not current state. Don't treat anything under `docs/archive/` as describing the app today.

## functions-shared vendoring (easy to trip on)

`functions-shared` is built and copied into each `functions-*/vendor/functions-shared` directory by `node scripts/vendor-functions-shared.cjs` — this is what `file:vendor/functions-shared` deps in each package's `package.json` resolve to. `vendor/` is gitignored. If a functions package fails to build/install right after a fresh clone or a `functions-shared` change, run the vendor script from repo root first:

```
npm ci --prefix functions-shared
node scripts/vendor-functions-shared.cjs
```

## What must pass

`.github/workflows/release-readiness.yml` is the source of truth for required checks — one job per `functions-*` package (build/vendor/test), `firestore-rules` (emulator tests), `marketing` (lint/build), `flutter` (analyze + test), plus repo-hygiene checks (`scripts/check_tracked_generated_artifacts.js`, `scripts/check_email_monthly_limits_parity.js` — the latter guards Dart/Functions staying in sync on email limit values). When changing a functions package, run its `npm run build && npm test` locally before considering the change done — see `AGENTS.md` for the `functions-integrations`-specific rule about not renaming exported callable symbols.

## Documentation hygiene

Do not add new root-level status/summary files. See the "Documentation Hygiene" section in `AGENTS.md`.
