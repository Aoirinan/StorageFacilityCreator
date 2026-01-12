import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:state_notifier/state_notifier.dart';
import '../models/locale_model.dart';
import '../services/locale_service.dart';

/// Provider for managing app locale
final localeProvider = StateNotifierProvider<LocaleNotifier, Locale>((ref) {
  return LocaleNotifier();
});

class LocaleNotifier extends StateNotifier<Locale> {
  LocaleNotifier() : super(const Locale('en', 'US')) {
    _loadLocale();
  }

  Future<void> _loadLocale() async {
    final appLocale = await LocaleService.getLocale();
    state = Locale(appLocale.languageCode, appLocale.countryCode);
  }

  Future<void> setLocale(AppLocale appLocale) async {
    await LocaleService.setLocale(appLocale);
    state = Locale(appLocale.languageCode, appLocale.countryCode);
  }

  Future<void> setLocaleFromCode(String languageCode, String countryCode) async {
    final appLocale = _getAppLocaleFromCode(languageCode);
    if (appLocale != null) {
      await setLocale(appLocale);
    }
  }

  AppLocale? _getAppLocaleFromCode(String languageCode) {
    switch (languageCode.toLowerCase()) {
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
        return null;
    }
  }
}
