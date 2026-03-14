# App Analyze Backlog Summary

Date: 2026-03-14

## Scope

This summary captures the current Flutter static-analysis backlog observed from:

- `flutter analyze`

This was run as a release-safety visibility step. No app runtime code was changed as part of this summary.

## Overall Result

- Analyzer status: **FAIL**
- Total reported issues: **3293**

## Top Rule Categories (by volume)

- `always_use_package_imports`: 1434
- `deprecated_member_use`: 599
- `unused_import`: 296
- `avoid_print`: 152
- `avoid_dynamic_calls`: 134
- `use_build_context_synchronously`: 131
- `unawaited_futures`: 72
- `unnecessary_non_null_assertion`: 47
- `unused_element`: 44
- `unused_field`: 41
- `unnecessary_null_comparison`: 39
- `unused_local_variable`: 39
- `dead_null_aware_expression`: 38
- `unnecessary_brace_in_string_interps`: 32
- `unnecessary_import`: 30
- `prefer_final_fields`: 22
- `avoid_types_as_parameter_names`: 21
- `curly_braces_in_flow_control_structures`: 19
- `avoid_web_libraries_in_flutter`: 14
- `unused_element_parameter`: 12

## Suggested Cleanup Order (Non-Blocking to Marketing Release)

1. **Low-risk hygiene batch**
   - Remove `unused_import`, `unused_local_variable`, `unused_field`, `unused_element`.
2. **Import normalization batch**
   - Tackle `always_use_package_imports` consistently by directory.
3. **Async correctness batch**
   - Address `use_build_context_synchronously` and `unawaited_futures`.
4. **Deprecation batch**
   - Replace `withOpacity`, old form `value`, and other `deprecated_member_use` patterns.
5. **Web/library architecture batch**
   - Handle `avoid_web_libraries_in_flutter` and related web-interoperability warnings.

## Release Impact

- This backlog is an app-code quality concern.
- It is **not introduced by the marketing/compliance refactor**.
- It is **not a direct blocker** for the current public marketing site release scope.
