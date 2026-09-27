import 'package:flutter/material.dart';

import 'package:sfcapp/theme/app_theme.dart';

/// Edit Facility's "Unit numbers repeat across areas" switch
/// (`unitNumbersRepeatAcrossAreas`), with why it could not be turned off
/// ([error]) and, while it is on at a facility taking online rentals, a
/// warning ([onlineRentalsEnabled]).
class UnitNumbersRepeatSetting extends StatelessWidget {
  const UnitNumbersRepeatSetting({
    super.key,
    required this.value,
    required this.onChanged,
    this.checking = false,
    this.error,
    this.onlineRentalsEnabled = false,
  });

  final bool value;

  /// Null while [checking].
  final ValueChanged<bool>? onChanged;

  /// Checking that no two units share a number before turning it off.
  final bool checking;
  final String? error;
  final bool onlineRentalsEnabled;

  static const title = 'Unit numbers repeat across areas';
  static const help =
      'Turn on if the same door number is used in more than one area, '
      'e.g. unit 12 in Complex 2 and unit 12 in Complex 3. Units with a '
      'repeated number must have an area. Statements, invoices and texts '
      'will show the area next to the unit number.';

  /// Online rentals still match rented units by unit number (a follow-up
  /// changes that), so the website can count both of two units numbered
  /// alike as rented when one is.
  static const onlineRentalsWarning =
      'Online rentals are on for this facility. Until a follow-up update '
      'ships, online availability for a repeated unit number may be '
      'understated: when one unit 12 is rented, the website may show every '
      'unit 12 as rented. This can only hide free units from online '
      'renters, not offer rented ones.';

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SwitchListTile(
          key: const ValueKey('unitNumbersRepeatAcrossAreas'),
          contentPadding: EdgeInsets.zero,
          value: value,
          onChanged: checking ? null : onChanged,
          title: const Text(title),
          subtitle: const Text(help),
        ),
        if (checking) const LinearProgressIndicator(minHeight: 2),
        if (error != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              error!,
              style: const TextStyle(color: AppTheme.error),
            ),
          ),
        if (value && onlineRentalsEnabled)
          Container(
            key: const ValueKey('unitNumbersRepeatOnlineRentalsWarning'),
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.warning),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, color: AppTheme.warning),
                SizedBox(width: 8),
                Expanded(child: Text(onlineRentalsWarning)),
              ],
            ),
          ),
      ],
    );
  }
}
