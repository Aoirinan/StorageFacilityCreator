# SFC App Theme Tokens

Central reference for semantic colors used across the app. Use these via `Theme.of(context).colorScheme` or `AppTheme` constants so light and dark modes stay consistent.

## Light mode (AppTheme + ColorScheme)

| Token | Use | Value (light) |
|-------|-----|----------------|
| `colorScheme.surface` | Sidebar, cards, top bar | `#FFFFFF` |
| `colorScheme.surfaceContainerHighest` | Table headers, filter bars, raised panels | `#F1F5F9` (backgroundSecondary) |
| `colorScheme.primary` | Active nav, buttons, links | `#1E3A8A` |
| `colorScheme.onSurface` | Primary text | `#1F2937` (textPrimary) |
| `colorScheme.onSurfaceVariant` | Muted text, labels, secondary icons | `#6B7280` (textSecondary) |
| `theme.dividerColor` | Borders, dividers | `#E5E7EB` (borderLight) |
| `scrollbarTheme` | Scrollbar thumb/track | Visible, thumbVisibility: true |

## Dark mode (ColorScheme + AppTheme.dark*)

| Token | Use | Value (dark) |
|-------|-----|----------------|
| `colorScheme.surface` | Sidebar, cards, top bar | `#1E293B` (darkSurface) |
| `colorScheme.surfaceContainerHighest` | Table headers, filter bars | `#334155` |
| `colorScheme.primary` | Active nav, buttons | `#3B82F6` (primaryBlueLight) |
| `colorScheme.onSurface` | Primary text | `#F1F5F9` (darkTextPrimary) |
| `colorScheme.onSurfaceVariant` | Muted text, labels | `#94A3B8` (darkTextSecondary) |
| `theme.dividerColor` | Borders | `#334155` (darkBorder) |
| `scrollbarTheme` | Scrollbar | Visible; thumb `#64748B`, track `#1E293B` |

## Usage

- **Sidebar / nav:** `colorScheme.surface`, `colorScheme.primary`, `colorScheme.onSurfaceVariant`.
- **Top bar:** `colorScheme.surface`, `theme.dividerColor`, `colorScheme.onSurfaceVariant` for icons.
- **Tables:** `headingRowColor: surfaceContainerHighest`; cell text uses theme `dataTextStyle` / `headingTextStyle`.
- **Inputs:** Use theme `inputDecorationTheme` (fill, border, label, hint) so dark mode has visible borders and placeholders.
- **Cards:** Use `Card` with theme or `colorScheme.surface`; avoid hard-coded `Colors.white` or `AppTheme.backgroundLight`.

## Do not

- Hide scrollbars with `display: none` or `scrollbarThumbVisibility: false`.
- Use raw `AppTheme.textSecondary` / `Colors.white` for text or backgrounds without considering dark mode; prefer `colorScheme.onSurface` / `colorScheme.onSurfaceVariant` / `colorScheme.surface`.
