# Future Upgrade Notes

## Completed (medium-risk upgrades)

- **csv 7** (Flutter): Migrated CsvToListConverter/ListToCsvConverter → csv.decode/encode
- **google_fonts 8** (Flutter): Upgraded; no code changes needed
- **Tailwind 4** (marketing): Upgraded via @tailwindcss/upgrade; PostCSS + globals.css migrated
- **React 19** (marketing): Upgraded
- **Node 22** (functions): Updated engines.node. Note: Firebase Node 22 is experimental—revert to 20 if deploy fails.
- **ESLint 10** (functions): Flat config; removed eslint-config-google, eslint-plugin-import. Vulns 15→7.
- **ESLint 10** (marketing): Upgraded. Vulns 13→10.
- **js package** (Flutter): Removed direct dep; still transitive.
- **firebase-admin** (functions): ^13.0 → ^13.6
- **@eslint/js** (functions): ^9 → ^10
- **Next.js 16** (marketing): Upgraded from 15; build verified.

## Blocked

### Riverpod 3/4, build_runner (Flutter)

- **Blocked:** riverpod_generator 4 conflicts with Flutter SDK (analyzer, test_api versions)
- **Current:** Riverpod 2.6.x, build_runner 2.5.4 (2.11.1 available but constrained)
- **When:** Revisit after Flutter SDK upgrade

## Future (low priority)

### dart:html → dart:js_interop (Flutter)

- **Current:** dart:html in 15+ web-only files
- **Note:** Works today; migrate when Flutter promotes package:web for Wasm
