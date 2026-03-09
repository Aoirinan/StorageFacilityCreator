/// Breakpoints for responsive layout.
/// xs < 600 (phones), sm 600-1024 (tablets), md 1024-1440 (laptops), lg >= 1440 (desktop)
class Breakpoints {
  static const double xs = 600;
  static const double sm = 1024;
  static const double md = 1440;

  static bool isXs(double width) => width < xs;
  static bool isSm(double width) => width >= xs && width < sm;
  static bool isMd(double width) => width >= sm && width < md;
  static bool isLg(double width) => width >= md;

  /// Phone: use card list, filters in sheet
  static bool isPhone(double width) => isXs(width);
  /// Tablet: compact table or list
  static bool isTablet(double width) => isSm(width);
  /// Laptop/desktop: table, only data area scrolls
  static bool isDesktop(double width) => isMd(width) || isLg(width);

  /// Use table layout (vs card list) when true
  static bool useTableLayout(double width) => width >= sm;
  /// Filter columns for top bar: 1 = stacked, 2 = two columns
  static int filterColumns(double width) => isXs(width) ? 1 : 2;
}
