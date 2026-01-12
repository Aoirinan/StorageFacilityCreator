import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

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
    // Enhanced route matching: exact match or starts with, and handle query parameters
    final isActive = (String route) {
      final routeWithoutQuery = currentRoute.split('?').first;
      return routeWithoutQuery == route || routeWithoutQuery.startsWith('$route/');
    };

    return Container(
      width: isCollapsed ? 80 : 240,
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border(
          right: BorderSide(
            color: Theme.of(context).dividerColor,
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          // Logo/Brand area
          Container(
            height: 64,
            padding: EdgeInsets.all(isCollapsed ? 12 : 16),
            child: isCollapsed
                ? const Icon(
                    Icons.storage,
                    color: AppTheme.primaryBlue,
                    size: 32,
                  )
                : Row(
                    children: [
                      const Icon(
                        Icons.storage,
                        color: AppTheme.primaryBlue,
                        size: 28,
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'SFC',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: AppTheme.primaryBlue,
                          letterSpacing: -0.5,
                        ),
                      ),
                    ],
                  ),
          ),
          const Divider(height: 1),
          
          // Navigation items
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
                _UnitsSection(
                  isCollapsed: isCollapsed,
                  isActive: isActive('/units') || isActive('/units/map'),
                  currentRoute: currentRoute,
                  onNavigate: onNavigate,
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
                _SidebarItem(
                  icon: Icons.shield_outlined,
                  activeIcon: Icons.shield,
                  label: 'Insurance',
                  route: '/insurance',
                  isActive: isActive('/insurance'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/insurance'),
                ),
                _SectionHeader(label: 'MONEY', isCollapsed: isCollapsed),
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
                  icon: Icons.payments_outlined,
                  activeIcon: Icons.payments,
                  label: 'Payments',
                  route: '/payments',
                  isActive: isActive('/payments'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/payments'),
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
                  icon: Icons.trending_up_outlined,
                  activeIcon: Icons.trending_up,
                  label: 'Yield Mgmt',
                  route: '/yield',
                  isActive: isActive('/yield'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/yield'),
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
                _SectionHeader(label: 'SECURITY', isCollapsed: isCollapsed),
                _SidebarItem(
                  icon: Icons.lock_outline,
                  activeIcon: Icons.lock,
                  label: 'Access',
                  route: '/access',
                  isActive: isActive('/access'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/access'),
                ),
                _SectionHeader(label: 'COMMS', isCollapsed: isCollapsed),
                _SidebarItem(
                  icon: Icons.message_outlined,
                  activeIcon: Icons.message,
                  label: 'Messaging',
                  route: '/messaging',
                  isActive: isActive('/messaging'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/messaging'),
                ),
                _SectionHeader(label: 'ADMIN', isCollapsed: isCollapsed),
                _SidebarItem(
                  icon: Icons.settings_outlined,
                  activeIcon: Icons.settings,
                  label: 'Settings',
                  route: '/settings',
                  isActive: isActive('/settings'),
                  isCollapsed: isCollapsed,
                  onTap: () => onNavigate('/settings'),
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

  const _SidebarItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.route,
    required this.isActive,
    required this.isCollapsed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
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
            color: isActive ? AppTheme.primaryBlue.withOpacity(0.1) : null,
            borderRadius: BorderRadius.circular(8),
            border: isActive
                ? Border.all(
                    color: AppTheme.primaryBlue.withOpacity(0.3),
                    width: 1,
                  )
                : null,
          ),
          child: Row(
            children: [
              Icon(
                isActive ? activeIcon : icon,
                color: isActive ? AppTheme.primaryBlue : AppTheme.textSecondary,
                size: 20,
              ),
              if (!isCollapsed) ...[
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                    color: isActive ? AppTheme.primaryBlue : AppTheme.textSecondary,
                    letterSpacing: 0.5,
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
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 6),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: AppTheme.textSecondary,
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

    return ExpansionTile(
      initiallyExpanded: expanded,
      tilePadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: Icon(
        Icons.map_outlined,
        color: isActive ? AppTheme.primaryBlue : AppTheme.textSecondary,
      ),
      title: Text(
        'Units',
        style: TextStyle(
          fontSize: 13,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
          color: isActive ? AppTheme.primaryBlue : AppTheme.textSecondary,
          letterSpacing: 0.5,
        ),
      ),
      children: [
        _SidebarItem(
          icon: Icons.list_alt_outlined,
          activeIcon: Icons.list_alt,
          label: 'Unit List',
          route: '/units',
          isActive: currentRoute == '/units',
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

