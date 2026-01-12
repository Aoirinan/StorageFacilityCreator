/// Supported application locales
enum AppLocale {
  english,
  spanish,
  french,
  german,
  chinese,
  japanese,
}

extension AppLocaleExtension on AppLocale {
  String get languageCode {
    switch (this) {
      case AppLocale.english:
        return 'en';
      case AppLocale.spanish:
        return 'es';
      case AppLocale.french:
        return 'fr';
      case AppLocale.german:
        return 'de';
      case AppLocale.chinese:
        return 'zh';
      case AppLocale.japanese:
        return 'ja';
    }
  }

  String get countryCode {
    switch (this) {
      case AppLocale.english:
        return 'US';
      case AppLocale.spanish:
        return 'ES';
      case AppLocale.french:
        return 'FR';
      case AppLocale.german:
        return 'DE';
      case AppLocale.chinese:
        return 'CN';
      case AppLocale.japanese:
        return 'JP';
    }
  }

  String get displayName {
    switch (this) {
      case AppLocale.english:
        return 'English';
      case AppLocale.spanish:
        return 'Español';
      case AppLocale.french:
        return 'Français';
      case AppLocale.german:
        return 'Deutsch';
      case AppLocale.chinese:
        return '中文';
      case AppLocale.japanese:
        return '日本語';
    }
  }

  String get localeString {
    return '${languageCode}_$countryCode';
  }

  static AppLocale? fromString(String? localeString) {
    if (localeString == null) return null;
    
    final parts = localeString.split('_');
    final langCode = parts[0].toLowerCase();
    
    switch (langCode) {
      case 'en':
        return AppLocale.english;
      case 'es':
        return AppLocale.spanish;
      case 'fr':
        return AppLocale.french;
      case 'de':
        return AppLocale.german;
      case 'zh':
        return AppLocale.chinese;
      case 'ja':
        return AppLocale.japanese;
      default:
        return AppLocale.english; // Default fallback
    }
  }
}

