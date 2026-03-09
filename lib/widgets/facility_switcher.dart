import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/active_facility_provider.dart';
import '../providers/facility_provider.dart';
import '../providers/auth_provider.dart';
import '../models/facility_model.dart';
import '../theme/app_theme.dart';

/// Widget for switching between facilities or viewing "All Facilities"
/// Displays in top bar or sidebar
class FacilitySwitcher extends ConsumerWidget {
  final bool compact; // If true, shows icon only; if false, shows full dropdown

  const FacilitySwitcher({
    super.key,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authStateProvider);
    final activeFacilityState = ref.watch(activeFacilityIdProvider);
    final facilitiesAsync = authState.whenData((user) => user?.uid).maybeWhen(
      data: (uid) => uid != null ? ref.watch(userFacilitiesProvider(uid)) : null,
      orElse: () => null,
    );

    return facilitiesAsync?.when(
      data: (facilities) {
        if (facilities.isEmpty) {
          return const SizedBox.shrink();
        }

        // ALWAYS show switcher even with one facility (for clarity)
        // User needs to see which facility they're viewing
        // Commented out: if (facilities.length == 1) return const SizedBox.shrink();

        final activeFacilityId = activeFacilityState.whenOrNull(data: (d) => d);

        // Find active facility name
        String displayText;
        if (activeFacilityId == null) {
          displayText = 'All Facilities';
        } else {
          final facility = facilities.firstWhere(
            (f) => f.id == activeFacilityId,
            orElse: () => facilities.first,
          );
          displayText = facility.name;
        }

        if (compact) {
          // Icon-only version for mobile/sidebar
          return PopupMenuButton<String?>(
            icon: Icon(
              Icons.business,
              color: AppTheme.primaryBlue,
            ),
            tooltip: 'Switch Facility',
            padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
            onSelected: (value) {
              ref.read(activeFacilityIdProvider.notifier).setActiveFacilityId(value);
            },
            itemBuilder: (context) {
              final cs = Theme.of(context).colorScheme;
              return [
                PopupMenuItem<String?>(
                  value: null,
                  height: 48,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Icon(
                          activeFacilityId == null ? Icons.check : Icons.radio_button_unchecked,
                          size: 20,
                          color: activeFacilityId == null ? cs.primary : cs.onSurfaceVariant,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'All Facilities',
                            style: AppTheme.dropdownItemTextStyle,
                            softWrap: true,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const PopupMenuDivider(),
                ...facilities.map((facility) {
                  final isSelected = activeFacilityId == facility.id;
                  return PopupMenuItem<String?>(
                    value: facility.id,
                    height: 48,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            isSelected ? Icons.check : Icons.radio_button_unchecked,
                            size: 20,
                            color: isSelected ? cs.primary : cs.onSurfaceVariant,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              facility.name,
                              style: AppTheme.dropdownItemTextStyle,
                              softWrap: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ];
            },
          );
        } else {
          // Full dropdown version for desktop top bar
          final colorScheme = Theme.of(context).colorScheme;
          return Container(
            constraints: const BoxConstraints(maxWidth: 280),
            child: DropdownButtonFormField<String?>(
              value: activeFacilityId,
              decoration: InputDecoration(
                labelText: 'Facility',
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                filled: true,
                fillColor: colorScheme.surfaceContainerHighest,
              ),
              isExpanded: true,
              selectedItemBuilder: (context) => [
                Text(
                  'All Facilities',
                  style: AppTheme.dropdownItemTextStyle.copyWith(
                    color: colorScheme.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
                ...facilities.map((f) => Text(
                  f.name,
                  style: AppTheme.dropdownItemTextStyle.copyWith(
                    color: colorScheme.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                )),
              ],
              items: [
                DropdownMenuItem<String?>(
                  value: null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.dashboard,
                          size: 18,
                          color: AppTheme.primaryBlue,
                        ),
                        const SizedBox(width: 12),
                        Text(
                          'All Facilities',
                          style: AppTheme.dropdownItemTextStyle,
                          softWrap: true,
                        ),
                      ],
                    ),
                  ),
                ),
                ...facilities.map((facility) {
                  return DropdownMenuItem<String?>(
                    value: facility.id,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Row(
                        children: [
                          Icon(
                            Icons.business,
                            size: 18,
                            color: AppTheme.primaryBlue,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              facility.name,
                              style: AppTheme.dropdownItemTextStyle,
                              softWrap: true,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }),
              ],
              onChanged: (value) {
                ref.read(activeFacilityIdProvider.notifier).setActiveFacilityId(value);
              },
            ),
          );
        }
      },
      loading: () => const SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
      error: (_, __) => const SizedBox.shrink(),
    ) ?? const SizedBox.shrink();
  }
}
