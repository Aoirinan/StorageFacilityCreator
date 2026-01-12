import 'package:flutter/material.dart';

enum NavigationItemType {
  screen,
  feature,
  action,
  external,
}

class NavigationItem {
  final String id;
  final String title;
  final String description;
  final IconData icon;
  final NavigationItemType type;
  final String? route;
  final VoidCallback? onTap;
  final String? externalUrl;
  final List<NavigationItem>? children;
  final bool isEnabled;
  final Color? color;
  final String? badge;
  final int? badgeCount;

  const NavigationItem({
    required this.id,
    required this.title,
    required this.description,
    required this.icon,
    required this.type,
    this.route,
    this.onTap,
    this.externalUrl,
    this.children,
    this.isEnabled = true,
    this.color,
    this.badge,
    this.badgeCount,
  });

  NavigationItem copyWith({
    String? id,
    String? title,
    String? description,
    IconData? icon,
    NavigationItemType? type,
    String? route,
    VoidCallback? onTap,
    String? externalUrl,
    List<NavigationItem>? children,
    bool? isEnabled,
    Color? color,
    String? badge,
    int? badgeCount,
  }) {
    return NavigationItem(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      icon: icon ?? this.icon,
      type: type ?? this.type,
      route: route ?? this.route,
      onTap: onTap ?? this.onTap,
      externalUrl: externalUrl ?? this.externalUrl,
      children: children ?? this.children,
      isEnabled: isEnabled ?? this.isEnabled,
      color: color ?? this.color,
      badge: badge ?? this.badge,
      badgeCount: badgeCount ?? this.badgeCount,
    );
  }
}

class NavigationSection {
  final String id;
  final String title;
  final IconData icon;
  final List<NavigationItem> items;
  final bool isExpanded;
  final Color? color;

  const NavigationSection({
    required this.id,
    required this.title,
    required this.icon,
    required this.items,
    this.isExpanded = true,
    this.color,
  });

  NavigationSection copyWith({
    String? id,
    String? title,
    IconData? icon,
    List<NavigationItem>? items,
    bool? isExpanded,
    Color? color,
  }) {
    return NavigationSection(
      id: id ?? this.id,
      title: title ?? this.title,
      icon: icon ?? this.icon,
      items: items ?? this.items,
      isExpanded: isExpanded ?? this.isExpanded,
      color: color ?? this.color,
    );
  }
}

class NavigationHistory {
  final String id;
  final String title;
  final String route;
  final DateTime timestamp;
  final Map<String, dynamic>? metadata;

  const NavigationHistory({
    required this.id,
    required this.title,
    required this.route,
    required this.timestamp,
    this.metadata,
  });

  NavigationHistory copyWith({
    String? id,
    String? title,
    String? route,
    DateTime? timestamp,
    Map<String, dynamic>? metadata,
  }) {
    return NavigationHistory(
      id: id ?? this.id,
      title: title ?? this.title,
      route: route ?? this.route,
      timestamp: timestamp ?? this.timestamp,
      metadata: metadata ?? this.metadata,
    );
  }
}

class QuickAction {
  final String id;
  final String title;
  final IconData icon;
  final VoidCallback onTap;
  final Color? color;
  final String? badge;
  final bool isEnabled;

  const QuickAction({
    required this.id,
    required this.title,
    required this.icon,
    required this.onTap,
    this.color,
    this.badge,
    this.isEnabled = true,
  });
}
