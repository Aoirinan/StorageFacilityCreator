import 'package:flutter/material.dart';

/// Title bar and body for a page inside the router's ShellRoute.
///
/// AppShell already draws the sidebar, the global top bar and the Scaffold,
/// so a page there must not use ModernPageWrapper: that draws a second
/// sidebar inside the first. This is the header the POS and Inventory pages
/// build for themselves: the title, the page's actions on the right, a
/// divider, then the body filling the rest.
class ShellPage extends StatelessWidget {
  final String title;

  /// A second line under the title, such as the facility the page is for.
  final String? subtitle;
  final List<Widget>? actions;
  final Widget child;

  const ShellPage({
    super.key,
    required this.title,
    this.subtitle,
    this.actions,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    // AppShell's own breakpoint for its mobile layout.
    final isMobile = MediaQuery.sizeOf(context).width < 900;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: cs.surface,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: isMobile ? 16 : 24, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        style: theme.textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: cs.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                if (actions != null && actions!.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  IconTheme(
                    data: IconThemeData(color: cs.onSurface),
                    child: Row(mainAxisSize: MainAxisSize.min, children: actions!),
                  ),
                ],
              ],
            ),
          ),
        ),
        Divider(height: 1, color: theme.dividerColor),
        Expanded(child: child),
      ],
    );
  }
}
