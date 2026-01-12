import 'package:flutter/material.dart';

/// Responsive breakpoints and utilities for mobile-first design
class ResponsiveBreakpoints {
  static const double xs = 360;   // Small phones (iPhone SE, older Android)
  static const double sm = 480;   // Regular phones (iPhone 14, most Android)
  static const double md = 768;   // Tablets (iPad, Android tablets)
  static const double lg = 1024;  // Small laptops/desktops
  static const double xl = 1200;  // Large desktops
  static const double xxl = 1600; // Ultrawide monitors
}

/// Responsive sizing constants
class ResponsiveSizes {
  // Edge padding
  static const double paddingXS = 12.0;
  static const double paddingSM = 16.0;
  static const double paddingMD = 20.0;
  static const double paddingLG = 24.0;
  static const double paddingXL = 32.0;
  
  // Gutter spacing
  static const double gutterXS = 8.0;
  static const double gutterSM = 12.0;
  static const double gutterMD = 16.0;
  static const double gutterLG = 20.0;
  static const double gutterXL = 24.0;
  
  // Icon sizes
  static const double iconXS = 16.0;
  static const double iconSM = 20.0;
  static const double iconMD = 24.0;
  static const double iconLG = 32.0;
  static const double iconXL = 40.0;
  static const double iconXXL = 48.0;
  
  // Font scales
  static const double fontScaleXS = 0.85;
  static const double fontScaleSM = 0.9;
  static const double fontScaleMD = 1.0;
  static const double fontScaleLG = 1.1;
  static const double fontScaleXL = 1.2;
  
  // Button heights
  static const double buttonHeightXS = 40.0;
  static const double buttonHeightSM = 44.0;
  static const double buttonHeightMD = 48.0;
  static const double buttonHeightLG = 52.0;
  
  // Card heights
  static const double cardHeightXS = 100.0;
  static const double cardHeightSM = 120.0;
  static const double cardHeightMD = 140.0;
  static const double cardHeightLG = 160.0;
  
  // Minimum tap targets
  static const double minTapTarget = 44.0;
}

/// Responsive breakpoint extensions
extension ResponsiveContext on BuildContext {
  double get screenWidth => MediaQuery.of(this).size.width;
  double get screenHeight => MediaQuery.of(this).size.height;
  double get textScaleFactor => MediaQuery.of(this).textScaleFactor;
  
  // Breakpoint checks
  bool get isXS => screenWidth < ResponsiveBreakpoints.xs;
  bool get isSM => screenWidth >= ResponsiveBreakpoints.xs && screenWidth < ResponsiveBreakpoints.sm;
  bool get isMD => screenWidth >= ResponsiveBreakpoints.sm && screenWidth < ResponsiveBreakpoints.md;
  bool get isLG => screenWidth >= ResponsiveBreakpoints.md && screenWidth < ResponsiveBreakpoints.lg;
  bool get isXL => screenWidth >= ResponsiveBreakpoints.lg && screenWidth < ResponsiveBreakpoints.xl;
  bool get isXXL => screenWidth >= ResponsiveBreakpoints.xl;
  
  // Mobile/Desktop checks
  bool get isMobile => screenWidth < ResponsiveBreakpoints.md;
  bool get isTablet => screenWidth >= ResponsiveBreakpoints.md && screenWidth < ResponsiveBreakpoints.lg;
  bool get isDesktop => screenWidth >= ResponsiveBreakpoints.lg;
  
  // Responsive values
  double get responsivePadding {
    if (isXS) return ResponsiveSizes.paddingXS;
    if (isSM) return ResponsiveSizes.paddingSM;
    if (isMD) return ResponsiveSizes.paddingMD;
    if (isLG) return ResponsiveSizes.paddingLG;
    return ResponsiveSizes.paddingXL;
  }
  
  double get responsiveGutter {
    if (isXS) return ResponsiveSizes.gutterXS;
    if (isSM) return ResponsiveSizes.gutterSM;
    if (isMD) return ResponsiveSizes.gutterMD;
    if (isLG) return ResponsiveSizes.gutterLG;
    return ResponsiveSizes.gutterXL;
  }
  
  double get responsiveIconSize {
    if (isXS) return ResponsiveSizes.iconXS;
    if (isSM) return ResponsiveSizes.iconSM;
    if (isMD) return ResponsiveSizes.iconMD;
    if (isLG) return ResponsiveSizes.iconLG;
    if (isXL) return ResponsiveSizes.iconXL;
    return ResponsiveSizes.iconXXL;
  }
  
  double get responsiveFontScale {
    if (isXS) return ResponsiveSizes.fontScaleXS;
    if (isSM) return ResponsiveSizes.fontScaleSM;
    if (isMD) return ResponsiveSizes.fontScaleMD;
    if (isLG) return ResponsiveSizes.fontScaleLG;
    return ResponsiveSizes.fontScaleXL;
  }
  
  double get responsiveButtonHeight {
    if (isXS) return ResponsiveSizes.buttonHeightXS;
    if (isSM) return ResponsiveSizes.buttonHeightSM;
    if (isMD) return ResponsiveSizes.buttonHeightMD;
    return ResponsiveSizes.buttonHeightLG;
  }
  
  double get responsiveCardHeight {
    if (isXS) return ResponsiveSizes.cardHeightXS;
    if (isSM) return ResponsiveSizes.cardHeightSM;
    if (isMD) return ResponsiveSizes.cardHeightMD;
    return ResponsiveSizes.cardHeightLG;
  }
  
  // Grid columns
  int get gridColumns {
    if (isXS) return 1;
    if (isSM) return 2;
    if (isMD) return 3;
    if (isLG) return 4;
    if (isXL) return 5;
    return 6;
  }
  
  // Aspect ratios
  double get cardAspectRatio {
    if (isXS) return 2.5;
    if (isSM) return 1.8;
    if (isMD) return 1.4;
    if (isLG) return 1.2;
    return 1.0;
  }
  
  // Keyboard-aware padding
  EdgeInsets get keyboardAwarePadding {
    final bottom = MediaQuery.of(this).viewInsets.bottom;
    return EdgeInsets.only(
      left: responsivePadding,
      right: responsivePadding,
      top: responsivePadding,
      bottom: bottom + responsivePadding,
    );
  }
  
  // Safe area padding
  EdgeInsets get safeAreaPadding {
    return EdgeInsets.only(
      left: responsivePadding,
      right: responsivePadding,
      top: MediaQuery.of(this).padding.top + responsivePadding,
      bottom: MediaQuery.of(this).padding.bottom + responsivePadding,
    );
  }
}

/// Responsive text styles
class ResponsiveTextStyles {
  static TextStyle headlineLarge(BuildContext context) {
    return Theme.of(context).textTheme.headlineLarge!.copyWith(
      fontSize: (Theme.of(context).textTheme.headlineLarge!.fontSize ?? 32) * context.responsiveFontScale,
    );
  }
  
  static TextStyle headlineMedium(BuildContext context) {
    return Theme.of(context).textTheme.headlineMedium!.copyWith(
      fontSize: (Theme.of(context).textTheme.headlineMedium!.fontSize ?? 28) * context.responsiveFontScale,
    );
  }
  
  static TextStyle headlineSmall(BuildContext context) {
    return Theme.of(context).textTheme.headlineSmall!.copyWith(
      fontSize: (Theme.of(context).textTheme.headlineSmall!.fontSize ?? 24) * context.responsiveFontScale,
    );
  }
  
  static TextStyle titleLarge(BuildContext context) {
    return Theme.of(context).textTheme.titleLarge!.copyWith(
      fontSize: (Theme.of(context).textTheme.titleLarge!.fontSize ?? 22) * context.responsiveFontScale,
    );
  }
  
  static TextStyle titleMedium(BuildContext context) {
    return Theme.of(context).textTheme.titleMedium!.copyWith(
      fontSize: (Theme.of(context).textTheme.titleMedium!.fontSize ?? 16) * context.responsiveFontScale,
    );
  }
  
  static TextStyle titleSmall(BuildContext context) {
    return Theme.of(context).textTheme.titleSmall!.copyWith(
      fontSize: (Theme.of(context).textTheme.titleSmall!.fontSize ?? 14) * context.responsiveFontScale,
    );
  }
  
  static TextStyle bodyLarge(BuildContext context) {
    return Theme.of(context).textTheme.bodyLarge!.copyWith(
      fontSize: (Theme.of(context).textTheme.bodyLarge!.fontSize ?? 16) * context.responsiveFontScale,
    );
  }
  
  static TextStyle bodyMedium(BuildContext context) {
    return Theme.of(context).textTheme.bodyMedium!.copyWith(
      fontSize: (Theme.of(context).textTheme.bodyMedium!.fontSize ?? 14) * context.responsiveFontScale,
    );
  }
  
  static TextStyle bodySmall(BuildContext context) {
    return Theme.of(context).textTheme.bodySmall!.copyWith(
      fontSize: (Theme.of(context).textTheme.bodySmall!.fontSize ?? 12) * context.responsiveFontScale,
    );
  }
}
