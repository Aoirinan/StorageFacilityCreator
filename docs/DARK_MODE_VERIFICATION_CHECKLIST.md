# Dark Mode UI Verification Checklist

**Scope:** Appearance only. All changes use `Theme.of(context).colorScheme` (and theme tokens) so that dark mode has no white blocks and all text is readable. Light mode is unchanged and remains the default.

## Theme & tokens

- **`lib/theme/app_theme.dart`**
  - Light theme: `outline: borderLight` added to `ColorScheme.light`.
  - Dark theme: `chipTheme` and `elevatedButtonTheme` added so chips and buttons follow theme.
  - Extension: `theme` and `colorScheme` getters on `BuildContext` for theme-aware colors.

## Pages verified in dark mode (no white rectangles, readable text)

Use **Settings → Appearance → Dark** (or system dark mode) and confirm:

| Page / area | What was fixed |
|-------------|----------------|
| **Dashboard** (`home_screen_modern.dart`) | Top bar, search bar, welcome card, occupancy card, quick actions, search results, critical items (delinquent / move-outs), error widget. All use `colorScheme.surface`, `surfaceContainerHighest`, `onSurface`, `onSurfaceVariant`, `outline`. |
| **Tenants** (`client_list_screen.dart`) | Filter/search container, search field fill, sort row, selection mode bar, delete button. |
| **Map editor** (`facility_map_editor_screen.dart`) | Toolbar background, Add Unit / Save buttons, toggle icons, canvas background and border. |
| **Contracts** (`contract_list_screen.dart`) | Title bar, disclaimer box, empty state, contract cards, status/type chips, list borders. |
| **Billing / Invoices** (`invoice_list_screen.dart`) | Filters container (background and border). |
| **Payments** (`payment_detail_screen.dart`) | Header, status card, payment info panel, timeline, receipt section, info rows, timeline connector. |
| **Delinquency** (`late_dashboard_screen.dart`) | Tab bar container, no-facilities message icon (already using theme). |
| **Messaging** (`messaging_screen.dart`) | Tabs container, conversations list border and header, SMS list header, list item avatars and text (Employee Chat & SMS), tab underline and labels. |
| **Shared layout** | **Top bar** (`modern_page_wrapper.dart`): background and border use `colorScheme.surface` and `outline`. **Facility switcher** (`facility_switcher.dart`): dropdown fill and menu icon colors. **Map search** (`map_search_bar.dart`), **map filter toolbar** (`map_filter_toolbar.dart`), **map unit tooltip** (`map_unit_tooltip.dart`): surfaces, borders, and text use theme. **Language selector** (`language_selector.dart`): container uses `colorScheme.surface` and `outline`. |
| **Dashboard widgets** | **MetricCard**, **ActivityFeed**, **DonutChart** use `colorScheme.outline`, `onSurface`, `onSurfaceVariant`, and (where applicable) `primary`. |

## Quick manual checks in dark mode

1. **No white rectangles** – No panels, cards, inputs, or dropdowns stay bright white.
2. **Readable text** – Headings, body, muted, and placeholders use `onSurface` / `onSurfaceVariant` (or theme text styles).
3. **Borders visible** – Dividers and borders use `colorScheme.outline` (or theme `dividerColor`).
4. **Hover / focus** – Buttons and list items use theme primary/onPrimary (or equivalent) so focus/hover states are visible.

## Token usage summary

- **Backgrounds:** `colorScheme.surface`, `surfaceContainerHighest`, `background`.
- **Text:** `colorScheme.onSurface` (primary), `onSurfaceVariant` (muted/labels).
- **Borders / dividers:** `colorScheme.outline`.
- **Buttons (primary):** `colorScheme.primary`, `onPrimary`.
- **Errors / destructive:** `colorScheme.error`, `onError` where appropriate.

Semantic colors (e.g. `AppTheme.success`, `AppTheme.warning`, `AppTheme.error`) are still used for status chips and alerts; they are unchanged and work in both themes.
