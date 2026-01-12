import 'package:flutter/material.dart';
import '../services/home_button_service.dart';
import 'package:go_router/go_router.dart';

class GlobalHomeOverlay extends StatelessWidget {
  final Widget? child;

  const GlobalHomeOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final media = MediaQuery.of(context);
    final bottomOffset = (media.size.height * 0.14).clamp(88.0, 156.0);
    final leftOffset = (16.0 + media.size.width * 0.015).clamp(16.0, 48.0);

    return ValueListenableBuilder<bool>(
      valueListenable: HomeButtonService.instance.visibilityListenable,
      builder: (context, isVisible, _) {
        final canGoBack = Navigator.canPop(context);
        return Stack(
          children: [
            if (child != null) child!,
            if (isVisible)
              Positioned(
                bottom: bottomOffset,
                left: leftOffset,
                child: SafeArea(
                  child: ElevatedButton.icon(
                    onPressed: () => _navigateHome(context),
                    style: ElevatedButton.styleFrom(
                      elevation: 6,
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ).copyWith(
                      backgroundColor: MaterialStateProperty.resolveWith((states) {
                        final isHover = states.contains(MaterialState.hovered) ||
                            states.contains(MaterialState.focused) ||
                            states.contains(MaterialState.pressed);
                        final base = canGoBack ? theme.colorScheme.primary : theme.colorScheme.surface;
                        // 60% transparency on hover (0.4 opacity), normal opacity otherwise
                        final opacity = isHover ? 0.4 : 0.82;
                        return base.withOpacity(opacity);
                      }),
                      foregroundColor: MaterialStateProperty.resolveWith((states) {
                        return canGoBack ? theme.colorScheme.onPrimary : theme.colorScheme.primary;
                      }),
                    ),
                    icon: Icon(
                      Icons.home_outlined,
                      color: canGoBack
                          ? theme.colorScheme.onPrimary
                          : theme.colorScheme.primary,
                    ),
                    label: Text(
                      'Dashboard',
                      style: theme.textTheme.labelLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: canGoBack
                            ? theme.colorScheme.onPrimary
                            : theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  void _navigateHome(BuildContext context) {
    if (context.mounted) {
      try {
        // Use GoRouter to navigate to dashboard
        final router = GoRouter.of(context);
        router.go('/dashboard');
      } catch (e) {
        // Fallback navigation if go() fails
        if (context.mounted) {
          try {
            context.go('/dashboard');
          } catch (e2) {
            // Last resort: use Navigator
            Navigator.of(context).pushNamedAndRemoveUntil('/dashboard', (route) => false);
          }
        }
      }
    }
  }
}

