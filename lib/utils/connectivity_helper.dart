import 'package:flutter/foundation.dart';

/// Helper class for handling connectivity issues in development vs production
class ConnectivityHelper {
  static bool _isProduction = kReleaseMode;
  
  /// Check if we're in a development environment with connectivity issues
  static bool get isDevelopmentOffline => !_isProduction && !_hasReliableConnection;
  
  /// Track if we have reliable Firebase connection
  static bool _hasReliableConnection = true;
  
  /// Set connection status (called by Firebase services)
  static void setConnectionStatus(bool isConnected) {
    _hasReliableConnection = isConnected;
  }
  
  /// Get user-friendly error message for connectivity issues
  static String getConnectivityMessage() {
    if (isDevelopmentOffline) {
      return 'Development mode: Limited connectivity. Data may not sync immediately.';
    }
    return 'Please check your internet connection and try again.';
  }
  
  /// Show appropriate error based on environment
  static String getOperationMessage(String operation) {
    if (isDevelopmentOffline) {
      return '$operation completed locally. Will sync when connected.';
    }
    return '$operation failed. Please check your connection.';
  }
  
  /// Determine if we should show retry option
  static bool shouldShowRetry() => !isDevelopmentOffline;
  
  /// Get timeout duration based on environment
  static Duration getTimeoutDuration() {
    if (_isProduction) {
      return const Duration(seconds: 30);
    }
    return const Duration(seconds: 10); // Shorter timeout in development
  }
}
