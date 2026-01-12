import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/locale_model.dart';

/// Service for managing application locale and language preferences
class LocaleService {
  static const String _localeKey = 'app_locale';
  static AppLocale? _cachedLocale;

  /// Get the saved locale preference
  static Future<AppLocale> getLocale() async {
    if (_cachedLocale != null) {
      return _cachedLocale!;
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final localeString = prefs.getString(_localeKey);
      
      if (localeString != null) {
        _cachedLocale = AppLocaleExtension.fromString(localeString);
        return _cachedLocale ?? AppLocale.english;
      }

      return AppLocale.english; // Default locale
    } catch (e) {
      if (kDebugMode) {
        print('❌ [LocaleService] Error getting locale: $e');
      }
      return AppLocale.english;
    }
  }

  /// Set the locale preference
  static Future<void> setLocale(AppLocale locale) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_localeKey, locale.localeString);
      _cachedLocale = locale;

      if (kDebugMode) {
        print('✅ [LocaleService] Locale set to: ${locale.displayName}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [LocaleService] Error setting locale: $e');
      }
    }
  }

  /// Get locale string for tenant/facility preference
  static String? getLocaleString(AppLocale? locale) {
    return locale?.localeString;
  }

  /// Parse locale from string
  static AppLocale? parseLocale(String? localeString) {
    return AppLocaleExtension.fromString(localeString);
  }

  /// Clear cached locale (useful for testing or logout)
  static void clearCache() {
    _cachedLocale = null;
  }
}

