import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/locale_model.dart';
import '../providers/locale_provider.dart';
import '../theme/app_theme.dart';

/// Language selector dropdown widget
class LanguageSelector extends ConsumerWidget {
  const LanguageSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentLocale = ref.watch(localeProvider);
    final localeNotifier = ref.read(localeProvider.notifier);

    // Map locale to AppLocale enum
    AppLocale? currentAppLocale;
    if (currentLocale.languageCode == 'en') {
      currentAppLocale = AppLocale.english;
    } else if (currentLocale.languageCode == 'es') {
      currentAppLocale = AppLocale.spanish;
    } else if (currentLocale.languageCode == 'fr') {
      currentAppLocale = AppLocale.french;
    } else if (currentLocale.languageCode == 'de') {
      currentAppLocale = AppLocale.german;
    } else if (currentLocale.languageCode == 'zh') {
      currentAppLocale = AppLocale.chinese;
    } else if (currentLocale.languageCode == 'ja') {
      currentAppLocale = AppLocale.japanese;
    } else {
      currentAppLocale = AppLocale.english;
    }

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.borderLight),
        borderRadius: BorderRadius.circular(8),
        color: Colors.white, // Ensure white background for visibility on dark login screen
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<AppLocale>(
          value: currentAppLocale,
          isDense: true,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          icon: const Icon(Icons.arrow_drop_down, size: 20),
          items: AppLocale.values.map((locale) {
            return DropdownMenuItem<AppLocale>(
              value: locale,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _getLanguageFlag(locale),
                    style: const TextStyle(fontSize: 18),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    locale.displayName,
                    style: const TextStyle(fontSize: 14),
                  ),
                ],
              ),
            );
          }).toList(),
          onChanged: (AppLocale? newLocale) {
            if (newLocale != null) {
              localeNotifier.setLocale(newLocale);
            }
          },
        ),
      ),
    );
  }

  String _getLanguageFlag(AppLocale locale) {
    switch (locale) {
      case AppLocale.english:
        return '🇺🇸';
      case AppLocale.spanish:
        return '🇪🇸';
      case AppLocale.french:
        return '🇫🇷';
      case AppLocale.german:
        return '🇩🇪';
      case AppLocale.chinese:
        return '🇨🇳';
      case AppLocale.japanese:
        return '🇯🇵';
    }
  }
}
