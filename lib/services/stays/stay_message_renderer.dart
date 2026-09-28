/// One `{{variable}}` a Stays message template may use (spec §9).
class StayMessageVariable {
  const StayMessageVariable(this.name, this.description, {this.sensitive = false, this.guestSpecific = false});

  final String name;
  final String description;

  /// Door codes and wifi: filled only for staff; viewers see the placeholder.
  final bool sensitive;

  /// Left as a placeholder in "Copy for Airbnb scheduled messages", which
  /// Airbnb fills per guest itself.
  final bool guestSpecific;
}

/// Fills `{{variable}}` placeholders in a copy-first template. A value that
/// is missing, empty, unknown or not allowed shows as `[variable]` so a gap
/// is visible before she sends it, never a silent blank. Pure: no Firestore,
/// no sending (Stays v1 sends nothing; she copies, prints or opens her own
/// mail or text app).
class StayMessageRenderer {
  const StayMessageRenderer._();

  static const List<StayMessageVariable> variables = [
    StayMessageVariable('guestFirstName', "Guest's first name", guestSpecific: true),
    StayMessageVariable('guestName', "Guest's name as shown on the stay", guestSpecific: true),
    StayMessageVariable('listingName', 'Listing name'),
    StayMessageVariable('siteCode', 'Short code, e.g. RV3'),
    StayMessageVariable('address', 'Listing address'),
    StayMessageVariable('directionsUrl', 'Directions link'),
    StayMessageVariable('checkInDate', 'Check-in date', guestSpecific: true),
    StayMessageVariable('checkInTime', 'Check-in time'),
    StayMessageVariable('checkOutDate', 'Checkout date', guestSpecific: true),
    StayMessageVariable('checkOutTime', 'Checkout time'),
    StayMessageVariable('nights', 'Number of nights', guestSpecific: true),
    StayMessageVariable('adults', 'Number of adults', guestSpecific: true),
    StayMessageVariable('doorCode', 'Door code', sensitive: true, guestSpecific: true),
    StayMessageVariable('lockboxCode', 'Lockbox code', sensitive: true),
    StayMessageVariable('gateCode', 'Gate code', sensitive: true),
    StayMessageVariable('wifiName', 'Wifi network', sensitive: true),
    StayMessageVariable('wifiPassword', 'Wifi password', sensitive: true),
    StayMessageVariable('houseRules', 'House rules'),
    StayMessageVariable('parkingNotes', 'Parking'),
    StayMessageVariable('trashNotes', 'Trash'),
    StayMessageVariable('checkoutInstructions', 'Checkout instructions'),
    StayMessageVariable('hookups', 'RV hookups'),
    StayMessageVariable('amps', 'RV amps'),
    StayMessageVariable('maxLengthFt', 'Max RV length (ft)'),
    StayMessageVariable('quietHours', 'Quiet hours'),
    StayMessageVariable('parkRules', 'Park rules'),
    StayMessageVariable('totalDue', 'Total for the stay', guestSpecific: true),
    StayMessageVariable('balanceDue', 'Balance still due', guestSpecific: true),
    StayMessageVariable('facilityName', 'Facility name'),
    StayMessageVariable('facilityPhone', 'Facility phone'),
  ];

  static final Set<String> variableNames = {for (final v in variables) v.name};

  static final Set<String> sensitiveVariables = {
    for (final v in variables)
      if (v.sensitive) v.name,
  };

  static final Set<String> guestSpecificVariables = {
    for (final v in variables)
      if (v.guestSpecific) v.name,
  };

  static final RegExp _placeholder = RegExp(r'\{\{\s*([A-Za-z0-9_]+)\s*\}\}');

  /// Fills [body] from [values].
  ///
  /// [canSeeAccess]: false for viewers, so codes and wifi stay placeholders.
  /// [forScheduledMessages]: "Copy for Airbnb scheduled messages" keeps
  /// guest-specific values as placeholders and fills listing-level ones.
  static String render(
    String body,
    Map<String, String?> values, {
    bool canSeeAccess = true,
    bool forScheduledMessages = false,
  }) {
    return body.replaceAllMapped(_placeholder, (match) {
      final name = match.group(1)!;
      final missing = '[$name]';
      if (!variableNames.contains(name)) return missing;
      if (!canSeeAccess && sensitiveVariables.contains(name)) return missing;
      if (forScheduledMessages && guestSpecificVariables.contains(name)) return missing;
      final value = values[name];
      if (value == null || value.trim().isEmpty) return missing;
      return value;
    });
  }

  /// The variable names [body] uses, in order, without repeats.
  static List<String> variablesIn(String body) {
    final seen = <String>{};
    return [
      for (final m in _placeholder.allMatches(body))
        if (seen.add(m.group(1)!)) m.group(1)!,
    ];
  }

  /// Variables [body] uses that [values] cannot fill, e.g. to warn before copying.
  static List<String> missingIn(String body, Map<String, String?> values, {bool canSeeAccess = true}) => [
        for (final name in variablesIn(body))
          if (!variableNames.contains(name) ||
              (!canSeeAccess && sensitiveVariables.contains(name)) ||
              (values[name]?.trim().isEmpty ?? true))
            name,
      ];

  /// "Jane D." → "Jane"; empty when unknown.
  static String firstNameOf(String displayName) {
    final trimmed = displayName.trim();
    if (trimmed.isEmpty) return '';
    return trimmed.split(RegExp(r'\s+')).first;
  }
}
