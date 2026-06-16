import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'modern_sidebar.dart';
import '../services/modern_navigation_service.dart';
import '../providers/messaging_provider.dart';

/// Modern page wrapper that provides consistent layout for all screens
/// Includes sidebar, top bar, and modern styling
class ModernPageWrapper extends StatelessWidget {
  final Widget child;
  final String? title;
  final List<Widget>? actions;
  final Widget? floatingActionButton;
  final String currentRoute;
  final Function(String)? onNavigate;
  final bool showSidebar;

  const ModernPageWrapper({
    super.key,
    required this.child,
    this.title,
    this.actions,
    this.floatingActionButton,
    required this.currentRoute,
    this.onNavigate,
    this.showSidebar = true,
  });

  @override
  Widget build(BuildContext context) {
    // Safely get active route - defer GoRouter access to avoid build-time errors
    String activeRoute = currentRoute;
    try {
      if (activeRoute.isEmpty) {
        final router = GoRouter.maybeOf(context);
        if (router != null) {
          activeRoute = router.routeInformationProvider.value.location ?? currentRoute;
        }
      }
    } catch (e) {
      // If router access fails, use provided currentRoute
      activeRoute = currentRoute;
    }
    final isMobile = MediaQuery.of(context).size.width < 900;

    if (!showSidebar) {
      // Simple wrapper without sidebar for auth screens, etc.
      return Scaffold(
        body: Column(
          children: [
            _buildTopBar(context, isMobile),
            Expanded(child: child),
          ],
        ),
        floatingActionButton: floatingActionButton,
      );
    }

    return Scaffold(
      body: Row(
        children: [
          // Sidebar
          if (!isMobile && showSidebar)
            Consumer(
              builder: (context, ref, _) {
                final unread = ref.watch(activeFacilityEmployeeChatUnreadCountProvider);
                return ModernSidebar(
                  currentRoute: activeRoute,
                  isCollapsed: false,
                  onNavigate: onNavigate ??
                      (route) => ModernNavigationService.navigateToRoute(
                            context,
                            route,
                          ),
                  employeeChatUnreadCount: unread,
                );
              },
            ),
          
          // Main content
          Expanded(
            child: Column(
              children: [
                // Top bar
                _buildTopBar(context, isMobile),
                
                // Main content area
                Expanded(child: child),
              ],
            ),
          ),
        ],
      ),
      floatingActionButton: floatingActionButton,
      drawer: isMobile && showSidebar
          ? Drawer(
              child: Consumer(
                builder: (context, ref, _) {
                  final unread = ref.watch(activeFacilityEmployeeChatUnreadCountProvider);
                  return ModernSidebar(
                    currentRoute: activeRoute,
                    isCollapsed: false,
                    onNavigate: (route) {
                      Navigator.of(context).pop();
                      (onNavigate ??
                              (r) => ModernNavigationService.navigateToRoute(context, r))(
                          route);
                    },
                    employeeChatUnreadCount: unread,
                  );
                },
              ),
            )
          : null,
    );
  }

  Widget _buildTopBar(BuildContext context, bool isMobile) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      height: 64,
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          bottom: BorderSide(
            color: colorScheme.outline,
            width: 1,
          ),
        ),
      ),
      padding: EdgeInsets.symmetric(
        horizontal: isMobile ? 16 : 24,
      ),
      child: Row(
        children: [
          if (isMobile && showSidebar)
            Builder(
              builder: (context) => IconButton(
                icon: const Icon(Icons.menu),
                onPressed: () => Scaffold.of(context).openDrawer(),
              ),
            ),
          if (title != null) ...[
            Expanded(
              child: Text(
                title!,
                style: TextStyle(
                  fontSize: isMobile ? 18 : 20,
                  fontWeight: FontWeight.w600,
                  color: colorScheme.onSurface,
                ),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            SizedBox(width: isMobile ? 12 : 24),
          ],
          const Spacer(),
          if (actions != null)
            IconTheme(
              data: IconThemeData(color: colorScheme.onSurface),
              child: Row(mainAxisSize: MainAxisSize.min, children: actions!),
            ),
        ],
      ),
    );
  }
}

