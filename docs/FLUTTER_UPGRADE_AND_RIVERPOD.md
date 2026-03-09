# Flutter upgrade and what’s blocking Riverpod

## How to upgrade Flutter

From a terminal (any directory):

```bash
flutter upgrade
```

This:

- Updates the Flutter SDK (and bundled Dart SDK) to the latest **stable** on your channel.
- Uses your existing Flutter install (e.g. `C:\src\flutter` or wherever you installed it).

To switch channel (e.g. to get newer fixes sooner):

```bash
flutter channel beta    # or: stable, master
flutter upgrade
```

After upgrading, run:

```bash
flutter doctor -v
```

to confirm the SDK and tools are OK.

---

## What’s stopping Riverpod from being upgraded?

It’s not “Flutter” in the abstract—it’s the **versions of packages that ship with the Flutter SDK**.

Rough dependency chain:

1. Your app depends on **flutter_test** (via `dev_dependencies: flutter_test:`).
2. **flutter_test** is part of the Flutter SDK and pins **test_api** to a specific version (e.g. **0.7.7**).
3. **test_api** and the **test** package work with **analyzer** in a limited range (e.g. analyzer **&lt; 9**).
4. **riverpod_generator** 4.0.2+ and **riverpod_lint** 3.1.1+ pull in **riverpod_analyzer_utils** 1.0.0-dev.9, which requires **analyzer ^9.0.0**.
5. So: SDK’s **test** stack (analyzer &lt; 9) vs Riverpod’s **analyzer ^9** → version solve fails.

So the blocker is: **the Flutter SDK’s bundled test stack (flutter_test → test_api → test → analyzer) doesn’t yet allow analyzer 9**, while the latest Riverpod code-gen/lint does.

This is a known ecosystem issue (e.g. [flutter/flutter#180485](https://github.com/flutter/flutter/issues/180485)): the SDK pins `test_api`, and analyzer majors ship more often than Flutter stable, so there are periods where packages that need the newest analyzer can’t be used on Flutter stable.

---

## Can the thing blocking it be “upgraded”?

- **You can’t upgrade it in your app.**  
  `flutter_test`, `test_api`, and the version of `test` you get are **supplied by the Flutter SDK**. They aren’t regular dependencies you can override in `pubspec.yaml` in a supported way.

- **The only way to “upgrade” that stack is to upgrade the Flutter SDK.**  
  Newer stable (or beta) releases sometimes bump `test_api` / `test` to versions that work with **analyzer 9**. When that happens, the same Riverpod versions will resolve.

So:

1. Run **`flutter upgrade`** to get the latest stable (or switch to beta and upgrade if you want to try earlier).
2. In your project run **`dart pub get`** and try bumping Riverpod again, e.g.:

   ```yaml
   dependencies:
     flutter_riverpod: ^3.2.0
     riverpod_annotation: ^4.0.2
   dev_dependencies:
     riverpod_generator: ^4.0.3
     riverpod_lint: ^3.1.0
   ```

3. If **`dart pub get`** still fails with the same analyzer/test conflict, the current SDK still doesn’t support analyzer 9; wait for the next Flutter stable (or use beta if it’s fixed there).

---

## Summary

| Question | Answer |
|----------|--------|
| How do we upgrade Flutter? | Run **`flutter upgrade`** (optionally **`flutter channel beta`** then **`flutter upgrade`**). |
| What’s stopping Riverpod from upgrading? | The **Flutter SDK’s test stack** (flutter_test → test_api → test → analyzer) only allows **analyzer &lt; 9**; latest Riverpod code-gen/lint wants **analyzer ^9**. |
| Can that blocker be upgraded? | Not inside your project. Only by **upgrading the Flutter SDK** to a version that ships a test stack compatible with **analyzer 9**. |

After every **`flutter upgrade`**, run **`dart pub get`** (and optionally **`dart run build_runner build`** if you use code generation) and re-try the Riverpod version bumps above.
