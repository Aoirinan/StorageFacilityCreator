# Integrations Refactor Handoff

This file preserves the intent and safe operating constraints from the `functions-integrations` refactor.

## What Was Done

- Large multi-export files were split into focused modules.
- Existing import paths were preserved via thin barrel files where needed.
- Firebase callable export names were kept stable to avoid client breakage.
- Several large callable flows were moved to helper or `*Logic` modules while preserving behavior.

## What To Do Next (Default)

- Stop proactive splitting unless tied to a real bug fix, feature, or repeated review bottleneck.
- Prefer changes with direct product impact.
- If touching a refactored area, keep wrappers thin and preserve exported callable names.

## Validation Checklist (Required For Integrations Changes)

1. `cd functions-integrations`
2. `npm run build`
3. `npm test`
4. `cd ..`
5. `firebase deploy --only functions:integrations --dry-run`

## Commit Message Template

Use this format for integrations changes:

```
<type>(functions-integrations): <outcome-focused title>

Keep Firebase callable exports stable while updating <area>.
Preserve barrel paths and validate with build/test/functions dry-run.
```

Examples:

- `refactor(functions-integrations): split webhook and billing handlers into focused modules`
- `fix(functions-integrations): correct tenant payment checkout error handling`
- `feat(functions-integrations): add facility subscription retry handling`

## PR Description Template

```
## Summary
- <business or reliability outcome>
- <files or flows changed at high level>
- <backward-compatibility note: callable names/exports unchanged>

## Risk
- Low/Medium/High: <why>
- Main regression vectors: <list>

## Validation
- [ ] npm run build (functions-integrations)
- [ ] npm test (functions-integrations)
- [ ] firebase deploy --only functions:integrations --dry-run

## Notes
- Any follow-up work is tied to user-visible feature/bug priorities, not additional tidy-only splitting.
```
