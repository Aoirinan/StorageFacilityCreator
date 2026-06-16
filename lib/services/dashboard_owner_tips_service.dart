import 'package:shared_preferences/shared_preferences.dart';

/// Persists whether the facility owner has opted out of dashboard tips.
class DashboardOwnerTipsService {
  DashboardOwnerTipsService._();

  static const String _disabledKey = 'owner_dashboard_tips_disabled';

  static Future<bool> isDisabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_disabledKey) ?? false;
  }

  static Future<void> setDisabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value) {
      await prefs.setBool(_disabledKey, true);
    } else {
      await prefs.remove(_disabledKey);
    }
  }
}
