import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../constants/app_version.dart';
import '../router/app_route.dart';
import 'bug_report_dialog.dart';

/// Modern sidebar navigation inspired by Storable's design
class ModernSidebar extends StatelessWidget {
  final String currentRoute;
  final Function(String) onNavigate;
  final bool isCollapsed;

  const ModernSidebar({
    super.key,
    required this.currentRoute,
    required this.onNavigate,
    this.isCollapsed = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    // Enhanced route matching: exact match or starts with, and handle query parameters.
    // Reminder sub-routes are treated as part of Delinquency so the sidebar stays highlighted.
    final routeWithoutQuery = currentRoute.split('?').first;
    final isActive = (String route) {
      if (route == '/delinquency' &&
          (routeWithoutQuery == '/reminders' ||
              routeWithoutQuery.startsWith('/reminders/'))) {
        return true;
      }
      return routeWithoutQuery == route ||
          routeWithoutQuery.startsWith('$route/');
    };

    return Container(
      width: isCollapsed ? 80 : null,
      constraints: isCollapsed ? null : const BoxConstraints(minWidth: 240),
      decoration: BoxDecoration(
        color: colorScheme.surface,
        border: Border(
          right: BorderSide(
            color: theme.dividerColor,
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          // Logo/Brand area (clickable to go to dashboard)
          InkWell(
            onTap: () => onNavigate('/dashboard'),
            child: Container(
              height: 64,
              padding: EdgeInsets.all(isCollapsed ? 12 : 16),
              child: isCollapsed
                  ? Icon(
                      Icons.storage,
                      color: colorScheme.primary,
                      size: 32,
                    )
                  : Row(
                      children: [
                        Icon(
                          Icons.storage,
                          color: colorScheme.primary,
                          size: 28,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'SFC',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: colorScheme.primary,
                            letterSpacing: -0.5,
                          ),
                        ),
                      ],
                    ),
            ),
          ),
          Divider(height: 1, color: theme.dividerColor),
          // Navigation items: Expanded + ListView only (exactly as pre-2.5 – no Scrollbar wrapper)
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 8),
              children: [
                _SectionHeader(label: 'OPS', isCollapsed: isCollapsed),
                _SidebarItem(
                  icon: Icons.dashboard_outlined,
                  activeIcon: Icons.dashboard,
                  label: 'Dashboard',
                  route: '/dashboard',
                  isActive: isActive('/dashboard'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/dashboard'),
                ),
                _SidebarItem(
                  icon: Icons.apartment_outlined,
                  activeIcon: Icons.apartment,
                  label: 'Facilities',
                  route: '/facilities',
                  isActive: isActive('/facilities'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/facilities'),
                ),
                _SidebarItem(
                  icon: Icons.people_outline,
                  activeIcon: Icons.people,
                  label: 'Tenants',
                  route: '/tenants',
                  isActive: isActive('/tenants'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/tenants'),
                ),
                _SidebarItem(
                  icon: Icons.message_outlined,
                  activeIcon: Icons.message,
                  label: 'Messaging',
                  route: '/messaging',
                  isActive: isActive('/messaging'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/messaging'),
                ),
                _SidebarItem(
                  icon: Icons.payments_outlined,
                  activeIcon: Icons.payments,
                  label: 'Payments',
                  route: '/payments',
                  isActive: isActive('/payments'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/payments'),
                ),
                _SidebarItem(
                  icon: Icons.local_offer_outlined,
                  activeIcon: Icons.local_offer,
                  label: 'Retail',
                  route: AppRoute.retail,
                  isActive:
                      isActive(AppRoute.pos) || isActive(AppRoute.inventory),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate(AppRoute.retail),
                ),
                _SidebarItem(
                  icon: Icons.storefront_outlined,
                  activeIcon: Icons.storefront,
                  label: 'Online Rentals',
                  route: '/online-rentals',
                  isActive: isActive('/online-rentals'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/online-rentals'),
                ),
                _SidebarItem(
                  icon: Icons.warning_amber_outlined,
                  activeIcon: Icons.warning_amber,
                  label: 'Delinquency',
                  route: '/delinquency',
                  isActive: isActive('/delinquency'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/delinquency'),
                ),
                _SidebarItem(
                  icon: Icons.receipt_long_outlined,
                  activeIcon: Icons.receipt,
                  label: 'Billing',
                  route: '/billing',
                  isActive: isActive('/billing'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/billing'),
                ),
                _SidebarItem(
                  icon: Icons.calendar_month_outlined,
                  activeIcon: Icons.calendar_month,
                  label: 'Calendar',
                  route: '/calendar',
                  isActive: isActive('/calendar'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/calendar'),
                ),
                _SidebarItem(
                  icon: Icons.lock_outlined,
                  activeIcon: Icons.lock,
                  label: 'Manager Overlock',
                  route: '/manager-overlock',
                  isActive: isActive('/manager-overlock'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/manager-overlock'),
                ),
                _SidebarItem(
                  icon: Icons.description_outlined,
                  activeIcon: Icons.description,
                  label: 'Contracts',
                  route: '/contracts',
                  isActive: isActive('/contracts'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/contracts'),
                ),
                _UnitsSection(
                  isCollapsed: isCollapsed,
                  isActive: isActive('/units') || isActive('/units/map'),
                  currentRoute: currentRoute,
                  onNavigate: onNavigate,
                ),
                _SidebarItem(
                  icon: Icons.assessment_outlined,
                  activeIcon: Icons.assessment,
                  label: 'Reports',
                  route: '/reports',
                  isActive: isActive('/reports'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/reports'),
                ),
                _SidebarItem(
                  icon: Icons.trending_up_outlined,
                  activeIcon: Icons.trending_up,
                  label: 'Yield Mgmt',
                  route: '/yield',
                  isActive: isActive('/yield'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/yield'),
                ),
                _SidebarItem(
                  icon: Icons.shield_outlined,
                  activeIcon: Icons.shield,
                  label: 'Insurance',
                  route: '/insurance',
                  isActive: isActive('/insurance'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/insurance'),
                ),
                _SidebarItem(
                  icon: Icons.lock_outline,
                  activeIcon: Icons.lock,
                  label: 'Access Codes',
                  route: '/access',
                  isActive: isActive('/access'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/access'),
                ),
                _SidebarItem(
                  icon: Icons.smart_toy_outlined,
                  activeIcon: Icons.smart_toy,
                  label: 'AI Assistant',
                  route: '/ai-assistant',
                  isActive: isActive('/ai-assistant'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/ai-assistant'),
                ),
                _SidebarItem(
                  icon: Icons.settings_outlined,
                  activeIcon: Icons.settings,
                  label: 'Settings',
                  route: '/settings',
                  isActive: isActive('/settings'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/settings'),
                ),
              ],
            ),
          ),
          // Report a Bug + version footer
          Container(
            decoration: BoxDecoration(
              border: Border(
                top: BorderSide(color: theme.dividerColor, width: 1),
              ),
            ),
            child: Column(
              children: [
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: () => BugReportDialog.show(context),
                    child: Container(
                      margin: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                      padding: EdgeInsets.symmetric(
                        horizontal: isCollapsed ? 12 : 16,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: AppTheme.error.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: AppTheme.error.withValues(alpha: 0.2),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: isCollapsed
                            ? MainAxisAlignment.center
                            : MainAxisAlignment.start,
                        children: [
                          Icon(Icons.bug_report_outlined,
                              color: AppTheme.error, size: 18),
                          if (!isCollapsed) ...[
                            const SizedBox(width: 10),
                            Text(
                              'Report a Bug',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                                color: AppTheme.error,
                                letterSpacing: 0.3,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 10),
                  child: Center(
                    child: Text(
                      AppVersion.displayVersion,
                      style: TextStyle(
                        fontSize: 10,
                        color: colorScheme.onSurfaceVariant,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _SidebarItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final String route;
  final bool isActive;
  final bool isCollapsed;
  final VoidCallback onTap;
  final int? badgeCount;

  const _SidebarItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.route,
    required this.isActive,
    required this.isCollapsed,
    required this.onTap,
    this.badgeCount,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final showBadge = badgeCount != null && badgeCount! > 0;
    final itemColor =
        isActive ? colorScheme.primary : colorScheme.onSurfaceVariant;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: EdgeInsets.symmetric(
            horizontal: isCollapsed ? 12 : 16,
            vertical: 12,
          ),
          decoration: BoxDecoration(
            color: isActive ? colorScheme.primary.withOpacity(0.15) : null,
            borderRadius: BorderRadius.circular(8),
            border: isActive
                ? Border.all(
                    color: colorScheme.primary.withOpacity(0.4),
                    width: 1,
                  )
                : null,
          ),
          child: Row(
            children: [
              Icon(
                isActive ? activeIcon : icon,
                color: itemColor,
                size: 20,
              ),
              if (!isCollapsed) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                      color: itemColor,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
                if (showBadge)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppTheme.error,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      badgeCount! > 99 ? '99+' : '$badgeCount',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: Colors.white,
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String label;
  final bool isCollapsed;

  const _SectionHeader({required this.label, required this.isCollapsed});

  @override
  Widget build(BuildContext context) {
    if (isCollapsed) return const SizedBox.shrink();
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: colorScheme.onSurfaceVariant,
          letterSpacing: 1,
        ),
      ),
    );
  }
}

class _UnitsSection extends StatelessWidget {
  final bool isCollapsed;
  final bool isActive;
  final String currentRoute;
  final Function(String) onNavigate;

  const _UnitsSection({
    required this.isCollapsed,
    required this.isActive,
    required this.currentRoute,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    if (isCollapsed) {
      return _SidebarItem(
        icon: Icons.map_outlined,
        activeIcon: Icons.map,
        label: 'Units',
        route: '/units',
        isActive: isActive,
        isCollapsed: isCollapsed,
        onTap: () => onNavigate('/units'),
      );
    }

    final expanded = currentRoute.startsWith('/units');
    final unitsPath = currentRoute.split('?').first;
    final unitListActive = unitsPath == '/units' ||
        unitsPath == AppRoute.unitCreate ||
        unitsPath == AppRoute.unitEdit ||
        unitsPath == AppRoute.unitDetail;

    final colorScheme = Theme.of(context).colorScheme;
    final itemColor =
        isActive ? colorScheme.primary : colorScheme.onSurfaceVariant;
    return ExpansionTile(
      initiallyExpanded: expanded,
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(
        Icons.map_outlined,
        color: itemColor,
      ),
      title: Text(
        'Units',
        style: TextStyle(
          fontSize: 13,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
          color: itemColor,
          letterSpacing: 0.5,
        ),
      ),
      children: [
        _SidebarItem(
          icon: Icons.list_alt_outlined,
          activeIcon: Icons.list_alt,
          label: 'Unit List',
          route: '/units',
          isActive: unitListActive,
          isCollapsed: false,
          onTap: () => onNavigate('/units'),
        ),
        _SidebarItem(
          icon: Icons.map_outlined,
          activeIcon: Icons.map,
          label: 'Map Editor',
          route: '/units/map',
          isActive: currentRoute.startsWith('/units/map'),
          isCollapsed: false,
          onTap: () => onNavigate('/units/map'),
        ),
      ],
    );
  }
}
