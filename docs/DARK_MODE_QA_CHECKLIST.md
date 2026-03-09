# Dark Mode QA Checklist

Use this after changing theme or layout to confirm readability and contrast.

## Sidebar & layout

- [ ] **Sidebar scroll:** With a short viewport, the left nav scrolls and you can reach Settings, AI Assistant, and version at the bottom.
- [ ] **Scrollbar visible:** The sidebar scrollbar is visible (not hidden) and usable in both light and dark mode.
- [ ] **Content scroll:** Main content area (dashboard, list, etc.) scrolls independently; no double-scroll or layout jump.
- [ ] **Responsive:** Same behavior on desktop, laptop, and mobile (drawer on mobile).

## Dark mode contrast (Settings → Appearance → Dark)

- [ ] **Dashboard (/dashboard):** Card titles (“Total Tenants”, “Total Units”, etc.) and values are readable. Metric cards have visible text and borders.
- [ ] **Unit list (/units):** Table header and row text readable. Toolbar/filter area has visible labels and inputs.
- [ ] **Unit details:** All labels and values readable; back/actions visible.
- [ ] **Manager Overlock (/manager-overlock):** Filter dropdowns, search field, table header, and row text readable. Buttons and badges visible.
- [ ] **Contracts (/contracts):** List and filters readable.
- [ ] **Contract templates (/contracts/templates):** Labels and template list readable.
- [ ] **New contract (/contracts/create):** Facility/tenant dropdowns, labels, and placeholders readable.
- [ ] **Settings (/settings):** Section titles and tile labels (Notifications, Appearance, etc.) readable. No “invisible” nav or card labels.

## Quick verification routes

1. `/dashboard` – cards and metrics  
2. `/units` – unit list table and toolbar  
3. `/manager-overlock` – filters and table  
4. `/contracts` – contract list  
5. `/contracts/templates` – template list  
6. `/settings` – all sections and Appearance

## If something fails

- Replace hard-coded `AppTheme.textSecondary`, `Colors.white`, or `AppTheme.backgroundLight` with `Theme.of(context).colorScheme` (e.g. `onSurfaceVariant`, `surface`, `surfaceContainerHighest`).
- Ensure inputs use theme `inputDecorationTheme` (filled, border, labelStyle, hintStyle).
- See `lib/theme/THEME_TOKENS.md` for token reference.
