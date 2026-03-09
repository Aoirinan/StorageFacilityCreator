# Dart analyze: issues and what was fixed

## Summary

- **All 12 analyze errors are fixed.** The remaining output from `dart analyze lib` is warnings and infos only.
- **Warnings** are safe to fix in batches (unused imports, nullability, dead code). They do not block builds.

---

## What was fixed (errors)

### 1. Web-only APIs (imports/guards)

**Issue:** Code used browser-only types (`Blob`, `Url`, `AnchorElement`, `window`) via a conditional `dart:html` import. The analyzer still type-checks both branches, so when the non-web branch is used it saw `html` as `dart:io`, which doesn’t define those names.

**Fix:** Move web-only behavior into small helpers that are selected by conditional import, so the main app code never references `dart:html` directly on the “wrong” platform.

- **facility_map_editor_screen.dart**
  - Added:
    - `lib/utils/map_export_web.dart` – uses `dart:html` Blob/Url/AnchorElement to trigger a download.
    - `lib/utils/map_export_stub.dart` – stub that throws on non-web.
  - Replaced the inline web download block with:
    - `import '...map_export_stub.dart' if (dart.library.html) '...map_export_web.dart' as map_export;`
    - Call `map_export.downloadBytesAsFileWeb(pngBytes, filename)` when `kIsWeb`.

- **stripe_connect_onboarding_screen.dart**
  - Added:
    - `lib/utils/open_url_web.dart` – uses `dart:html` `window.open` / `location.href`.
    - `lib/utils/open_url_stub.dart` – stub that throws on non-web.
  - Replaced the inline `html.window` usage with:
    - Conditional import of the helpers as `open_url`.
    - Call `open_url.openUrlInBrowserWeb(url)` when `kIsWeb`.

### 2. Undefined `AuditService`

**Issue:** `delinquency_automation_service.dart` called `AuditService.logEvent(...)` but had no import for `AuditService`.

**Fix:** Added:

```dart
import 'package:sfcapp/services/audit_service.dart';
```

### 3. `dart:js_util` removed in Dart 3

**Issue:** `stripe_web_bridge_web.dart` used `import 'dart:js_util'`. In Dart 3.11 that library no longer exists; the SDK uses `dart:js_interop` and `dart:js_interop_unsafe` instead.

**Fix:** Rewrote the Stripe web bridge to use:

- `dart:js_interop` – `jsify()`, `toJS` (getter), `JSPromise.toDart`, etc.
- `dart:js_interop_unsafe` – `JSObject[]`, `callMethod`, `JSFunction.callAsConstructor`.

Important: `toJS` is a **getter**, not a method – use `.toJS` not `.toJS()`.

---

## Warning categories (remaining)

These do not block builds; you can fix them over time.

| Category | What it means | Typical fix |
|----------|----------------|-------------|
| **unused_import** | An import is never used. | Remove the import line. |
| **unnecessary_null_comparison** | A condition checks `== null` or `!= null` on a non-nullable type. | Simplify the condition or remove it. |
| **invalid_null_aware_operator** | Use of `?.` or `??` where the left side can’t be null. | Use `.` or remove the `?? right` part. |
| **dead_null_aware_expression** | The right side of `??` is never used. | Remove the `?? right` part. |
| **unnecessary_non_null_assertion** | A `!` is used on a value that’s already non-null. | Remove the `!`. |
| **unused_local_variable** | A local variable is never read. | Remove it or use it. |
| **unused_field** | A field is never read. | Remove the field or use it. |
| **unused_element** | A method/function/declaration is never referenced. | Remove it or wire it up. |
| **unreachable_switch_case** | A switch case is already covered by earlier cases. | Remove the redundant case. |
| **duplicate_import** | The same library is imported more than once. | Keep a single import. |
| **unused_shown_name** | A name in a `show` clause is not used. | Remove it from the list. |
| **deprecated_member_use** / **avoid_web_libraries_in_flutter** | Use of `dart:html` etc. | Optional: migrate to `package:web` when convenient. |

---

## How to re-check

- **Errors only (should be 0):**
  ```bash
  dart analyze lib 2>&1 | findstr /C:"error -"
  ```
- **Full report:**
  ```bash
  dart analyze lib
  ```

---

## Optional: fix warnings in batches

- **Unused imports:** Search for `unused_import` in the analyze output and remove the corresponding import in each file.
- **Nullability:** For `unnecessary_null_comparison`, `invalid_null_aware_operator`, `dead_null_aware_expression`, `unnecessary_non_null_assertion`, adjust conditions and operators as in the table above.
- **Unused variables/fields/elements:** Either remove them or use them; for private helpers, removing is usually safe if you’re sure they’re not needed.

If you want, we can go file-by-file or category-by-category and apply these warning fixes next.
