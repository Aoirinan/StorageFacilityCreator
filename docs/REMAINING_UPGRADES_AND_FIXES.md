# What’s Left to Upgrade & What Would Need Fixing

After the recommended safe upgrades, these are the remaining “incompatible” upgrades and what would need to be done if you upgrade them.

**Last batch (done):** Functions upgraded to Sentry 10, @types/node 25, typescript-eslint 8; marketing upgraded to @types/node 25. Flutter Riverpod was not upgraded (version solve fails with current SDK: riverpod_generator 4.0.2+ / riverpod_lint 3.1.1+ pull in analyzer ^9 which conflicts with flutter_test).

---

## 1. Remaining upgrades (not yet done)

### Firebase Functions (`functions/`)

| Package | Current | Latest | Type |
|--------|---------|--------|------|
| @sentry/node | 9.47.1 | 10.41.0 | Major |
| @types/node | 22.19.13 | 25.3.3 | Major |
| @typescript-eslint/eslint-plugin | 7.18.0 | 8.56.1 | Major |
| @typescript-eslint/parser | 6.21.0 | 8.56.1 | Major |

### Marketing (`marketing/`)

| Package | Current | Latest | Type |
|--------|---------|--------|------|
| @types/node | 20.19.35 | 25.3.3 | Major |

### Flutter app (root)

**Direct dependencies**

| Package | Current | Latest | Type |
|--------|---------|--------|------|
| flutter_riverpod | 3.1.0 | 3.2.1 | Minor |
| riverpod_annotation | 4.0.0 | 4.0.2 | Patch |

**Dev dependencies**

| Package | Current | Latest | Type |
|--------|---------|--------|------|
| riverpod_generator | 4.0.0+1 | 4.0.3 | Patch |
| riverpod_lint | 3.1.0 | 3.1.3 | Patch |

**Transitive (locked by SDK / other deps)**  
These only move if you upgrade Flutter/Dart SDK or relax constraints; not required for “recommended” scope.

- _fe_analyzer_shared, analyzer, characters, extension, image, jni, matcher, material_color_utilities, meta, riverpod, test, test_api, test_core, win32  
- analysis_server_plugin, analyzer_buffer, analyzer_plugin, build_config, dart_style, riverpod_analyzer_utils  

---

## 2. What would need to be fixed if you upgrade

### 2.1 @sentry/node 9 → 10 (functions)

**Current usage in this repo**

- `functions/src/index.ts`: `Sentry.init({ dsn, environment, tracesSampleRate, beforeSend })` and `Sentry.captureException(error, { tags, extra })`.

**Likely changes**

- **Init:** You are not using `_experiments` or the removed APIs. If you add options later, any `_experiments.enableLogs` / `beforeSendLog` would move to top-level. No change needed for current config.
- **OpenTelemetry:** v10 uses OpenTelemetry v2. Only matters if you use custom OpenTelemetry; with plain Firebase Functions, no code change.
- **Types:** After `npm i @sentry/node@10`, run `npm run build`. If `beforeSend` or `event.request` / `event.extra` get type errors, adjust to the new Sentry v10 event types (usually small tweaks in `index.ts`).
- **captureException:** The call `Sentry.captureException(error, { tags, extra })` is unchanged in v10; no rewrite expected.

**Effort:** Low – bump version, fix any new type errors in `beforeSend`/event typing.

---

### 2.2 @typescript-eslint 7/6 → 8 (functions)

**Current setup**

- `functions/eslint.config.js`: flat config, `@typescript-eslint/eslint-plugin`, `@typescript-eslint/parser`, and rules: `no-unused-vars`, `no-explicit-any`, `explicit-function-return-type`, `no-require-imports`, etc.

**Likely changes**

- **Config:** v8 may expect `parserOptions` (e.g. `projectService: true` or `project`) for full typed linting. You might add something like `parserOptions: { projectService: true }` (or `project: './tsconfig.json'`) in the `languageOptions` block if you want typed rules.
- **Rule renames:** You already use `no-require-imports` (v8 name). If you ever add these rules, renames are: `prefer-ts-expect-error` → `ban-ts-comment`, `no-throw-literal` → `only-throw-error`, and `ban-types` split into other rules. Your current rule set doesn’t require renames.
- **New violations:** v8 is stricter. You may get:
  - `@typescript-eslint/only-throw-error`: throw `Error` (or subclasses) instead of literals.
  - Object/function types: avoid `{}`, bare `Function`; use `object`, `Record<>,` or specific function types where needed.
- **Install:** Align plugin and parser to the same major, e.g. `@typescript-eslint/eslint-plugin@8` and `@typescript-eslint/parser@8`.

**Effort:** Low–medium – update packages, adjust `eslint.config.js` if needed, then fix new lint errors across `functions/src`.

---

### 2.3 @types/node 22/20 → 25 (functions + marketing)

**What it is**

- Type definitions only for Node.js globals and built-in modules. No runtime behavior change.

**Likely changes**

- New or stricter types for `process`, `Buffer`, `fs`, `path`, etc. Some `any` or loose types might start failing.
- Fix: run `npm run build` (functions) and your marketing build; fix any new TypeScript errors (usually argument types, optional props, or stricter `process.env` typing).

**Effort:** Low – fix type errors until build and lint pass.

---

### 2.4 Flutter: Riverpod 3.1 → 3.2 + annotations/generator/lint

**Current usage**

- App uses Riverpod widely (providers, `ref.watch`/`ref.read`, ConsumerWidget, etc.). No `family.overrideWith` (or similar) in the codebase.

**Likely changes**

- **Deprecation:** Riverpod 3.2 deprecates `family.overrideWith` in favor of `family.overrideWith2`. You don’t use it, so nothing to change.
- **Regression risk:** 3.2.0 had a known issue with `ProviderScope` + `PageView`/`LayoutBuilder` (e.g. “setState() called after dispose()”). If you use those together, test those flows after upgrading; if issues appear, you may need to wait for a patch or pin to 3.2.1+ if a fix exists.
- **Code gen:** After bumping `riverpod_annotation` and `riverpod_generator`, run `dart run build_runner build --delete-conflicting-outputs` and fix any new analyzer/lint issues in generated or annotated code.
- **Lint:** riverpod_lint 3.1.3 may report new hints; address or disable as you prefer.

**Effort:** Low – version bump, run build_runner, test (especially ProviderScope + PageView/LayoutBuilder).

---

### 2.5 Other Dart transitive packages (analyzer, test, win32, etc.)

- These are pulled in by the SDK and other packages. Upgrading them usually means upgrading the Flutter/Dart SDK or waiting for dependency resolution to allow newer versions.
- If you do upgrade (e.g. by upgrading Flutter): run `dart analyze` and fix any new deprecations or errors. No application code rewrite is typically required unless you use deprecated APIs from those packages.

---

## 3. Summary table

| Upgrade | Where | Code/config changes | Effort |
|--------|--------|----------------------|--------|
| @sentry/node 10 | functions | Possibly small type fixes in Sentry init/event | Low |
| @typescript-eslint 8 | functions | Config tweak; fix new lint/rule violations | Low–medium |
| @types/node 25 | functions, marketing | Fix new TypeScript errors | Low |
| Riverpod 3.2 + annotation/generator/lint | Flutter | build_runner; test ProviderScope/PageView | Low |
| Other Dart (analyzer, test, etc.) | Flutter | Usually only after SDK upgrade; fix analyze errors | Low (when done with SDK) |

**Bottom line:** None of these upgrades require a full rewrite. They’re incremental: bump versions, then fix types, lint, and (for Riverpod) run code gen and test. I can walk through or apply any of these upgrades step by step if you want to do them next.
