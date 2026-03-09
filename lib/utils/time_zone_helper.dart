/// Helpers for time zone display in facility creation/edit.
/// Uses IANA time zone IDs (e.g. America/New_York); displays human-readable labels.
class TimeZoneHelper {
  TimeZoneHelper._();

  /// Default time zone when creating a new facility (Eastern).
  static const String defaultTimeZoneId = 'America/New_York';

  /// Human-readable label for dropdown/list display.
  /// Covers common US zones used in facility creation; fallback for others.
  static String displayLabel(String ianaId) {
    const labels = <String, String>{
      'America/New_York': 'Eastern (New York)',
      'America/Chicago': 'Central (Chicago)',
      'America/Denver': 'Mountain (Denver)',
      'America/Phoenix': 'Mountain – Arizona (Phoenix, no DST)',
      'America/Los_Angeles': 'Pacific (Los Angeles)',
      'America/Anchorage': 'Alaska (Anchorage)',
      'Pacific/Honolulu': 'Hawaii (Honolulu)',
    };
    return labels[ianaId] ??
        ianaId.split('/').last.replaceAll('_', ' ').split(' ').map((w) {
          if (w.isEmpty) return w;
          return w[0].toUpperCase() + w.substring(1).toLowerCase();
        }).join(' ');
  }
}
