import 'package:flutter/material.dart';

/// Centralized app constants for colors, dimensions, and other UI values
class AppConstants {
  // Colors
  static const Color primaryColor = Color(0xFF3F51B5); // Indigo
  static const Color primaryColorDark = Color(0xFF303F9F);
  static const Color primaryColorLight = Color(0xFFC5CAE9);
  static const Color accentColor = Color(0xFF4CAF50); // Green
  static const Color errorColor = Color(0xFFE53935); // Red
  static const Color warningColor = Color(0xFFFF9800); // Orange
  static const Color successColor = Color(0xFF4CAF50); // Green
  static const Color infoColor = Color(0xFF2196F3); // Blue
  
  // Status Colors
  static const Color statusActive = Color(0xFF4CAF50);
  static const Color statusInactive = Color(0xFF9E9E9E);
  static const Color statusPending = Color(0xFFFF9800);
  static const Color statusError = Color(0xFFE53935);
  static const Color statusWarning = Color(0xFFFF9800);
  
  // Background Colors
  static const Color backgroundColor = Color(0xFFF5F5F5);
  static const Color surfaceColor = Colors.white;
  static const Color cardColor = Colors.white;
  
  // Text Colors
  static const Color textPrimary = Color(0xFF212121);
  static const Color textSecondary = Color(0xFF757575);
  static const Color textHint = Color(0xFFBDBDBD);
  
  // Spacing
  static const double spacingXS = 4.0;
  static const double spacingS = 8.0;
  static const double spacingM = 16.0;
  static const double spacingL = 24.0;
  static const double spacingXL = 32.0;
  static const double spacingXXL = 48.0;
  
  // Border Radius
  static const double radiusS = 4.0;
  static const double radiusM = 8.0;
  static const double radiusL = 12.0;
  static const double radiusXL = 16.0;
  
  // Icon Sizes
  static const double iconXS = 16.0;
  static const double iconS = 20.0;
  static const double iconM = 24.0;
  static const double iconL = 32.0;
  static const double iconXL = 48.0;
  static const double iconXXL = 64.0;
  
  // Font Sizes
  static const double fontSizeXS = 10.0;
  static const double fontSizeS = 12.0;
  static const double fontSizeM = 14.0;
  static const double fontSizeL = 16.0;
  static const double fontSizeXL = 18.0;
  static const double fontSizeXXL = 24.0;
  static const double fontSizeTitle = 28.0;
  
  // Animation Durations
  static const Duration animationFast = Duration(milliseconds: 150);
  static const Duration animationNormal = Duration(milliseconds: 300);
  static const Duration animationSlow = Duration(milliseconds: 500);
  
  // Breakpoints for responsive design
  static const double breakpointMobile = 600.0;
  static const double breakpointTablet = 900.0;
  static const double breakpointDesktop = 1200.0;
  static const double breakpointLarge = 1600.0;
  
  // Grid configurations
  static const int gridColumnsMobile = 2;
  static const int gridColumnsTablet = 3;
  static const int gridColumnsDesktop = 4;
  static const int gridColumnsLarge = 5;
  static const int gridColumnsUltrawide = 6;
  
  // Feature card configurations
  static const double featureCardHeight = 140.0;
  static const double featureCardHeightMobile = 120.0;
  static const double featureCardHeightTablet = 160.0;
  
  // Search and pagination
  static const int searchDebounceMs = 300;
  static const int maxSearchResults = 25;
  static const int defaultPageSize = 20;
  
  // Timeouts
  static const Duration networkTimeout = Duration(seconds: 15);
  static const Duration shortTimeout = Duration(seconds: 5);
  static const Duration longTimeout = Duration(seconds: 30);
  
  // Validation
  static const int minPasswordLength = 8;
  static const int maxNameLength = 100;
  static const int maxDescriptionLength = 500;
  static const int maxNotesLength = 1000;
  
  // File upload
  static const int maxFileSizeMB = 10;
  static const List<String> allowedImageTypes = ['jpg', 'jpeg', 'png', 'gif', 'webp'];
  static const List<String> allowedDocumentTypes = ['pdf', 'doc', 'docx', 'txt'];
  
  // DNR Configuration
  static const int dnrRetentionDays = 365;
  static const int maxDNRNotesLength = 1000;
  
  // Payment Configuration
  static const double defaultLateFee = 25.0;
  static const double dailyLateFee = 5.0;
  static const int gracePeriodDays = 3;
  static const int severeOverdueDays = 30;
  
  // Security
  static const int maxLoginAttempts = 5;
  static const Duration lockoutDuration = Duration(minutes: 15);
  static const Duration sessionTimeout = Duration(hours: 24);
  
  // Navigation
  static const int maxNavigationHistory = 50;
  static const int maxFavorites = 20;
  static const int maxQuickActions = 10;
}

/// Extension methods for responsive design
extension ResponsiveBreakpoints on BuildContext {
  bool get isMobile => MediaQuery.of(this).size.width < AppConstants.breakpointMobile;
  bool get isTablet => MediaQuery.of(this).size.width >= AppConstants.breakpointMobile && 
                      MediaQuery.of(this).size.width < AppConstants.breakpointTablet;
  bool get isDesktop => MediaQuery.of(this).size.width >= AppConstants.breakpointTablet && 
                       MediaQuery.of(this).size.width < AppConstants.breakpointDesktop;
  bool get isLarge => MediaQuery.of(this).size.width >= AppConstants.breakpointDesktop && 
                     MediaQuery.of(this).size.width < AppConstants.breakpointLarge;
  bool get isUltrawide => MediaQuery.of(this).size.width >= AppConstants.breakpointLarge;
  
  int get gridColumns {
    if (isMobile) return AppConstants.gridColumnsMobile;
    if (isTablet) return AppConstants.gridColumnsTablet;
    if (isDesktop) return AppConstants.gridColumnsDesktop;
    if (isLarge) return AppConstants.gridColumnsLarge;
    return AppConstants.gridColumnsUltrawide;
  }
  
  double get featureCardHeight {
    if (isMobile) return AppConstants.featureCardHeightMobile;
    if (isTablet) return AppConstants.featureCardHeightTablet;
    return AppConstants.featureCardHeight;
  }
}
