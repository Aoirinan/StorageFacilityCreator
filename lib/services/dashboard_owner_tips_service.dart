import 'package:shared_preferences/shared_preferences.dart';

/// Persists whether the facility owner has opted out of dashboard tips, and
/// when the tips were last shown so they do not reappear on every reload.
class DashboardOwnerTipsService {
  DashboardOwnerTipsService._();

  static const String _disabledKey = 'owner_dashboard_tips_disabled';
  static const String _lastShownKey = 'owner_dashboard_tips_last_shown_ms';

  /// Minimum gap between automatic showings for an owner who has not
  /// opted out.
  static const Duration minimumGap = Duration(days: 1);

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

  /// Whether the tips were shown within [minimumGap] of [now].
  static Future<bool> shownRecently({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    final lastMs = prefs.getInt(_lastShownKey);
    if (lastMs == null) return false;
    final last = DateTime.fromMillisecondsSinceEpoch(lastMs);
    return (now ?? DateTime.now()).difference(last) < minimumGap;
  }

  static Future<void> markShown({DateTime? now}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        _lastShownKey, (now ?? DateTime.now()).millisecondsSinceEpoch);
  }
}
