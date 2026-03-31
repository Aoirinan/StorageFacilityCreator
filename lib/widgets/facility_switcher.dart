import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/active_facility_provider.dart';
import '../providers/facility_provider.dart';
import '../providers/auth_provider.dart';
import '../models/facility_model.dart';
import '../theme/app_theme.dart';


Widget _facilityNameWithAccessLine(
  BuildContext context,
  FacilityModel facility,
  String? currentUserId,
  TextStyle nameStyle,
) {
  final cs = Theme.of(context).colorScheme;
  final team = facility.showsAsTeamMemberForViewer(currentUserId);
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(
        facility.name,
        style: nameStyle,
        softWrap: true,
        maxLines: team ? 2 : 1,
        overflow: TextOverflow.ellipsis,
      ),
      if (team) ...[
        const SizedBox(height: 2),
        Text(
          'Team member',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: cs.primary,
          ),
        ),
      ],
    ],
  );
}

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
        final currentUid = authState.whenOrNull(data: (u) => u?.uid);

        if (facilities.isEmpty) {
          return const SizedBox.shrink();
        }

        // ALWAYS show switcher even with one facility (for clarity)
        // User needs to see which facility they're viewing
        // Commented out: if (facilities.length == 1) return const SizedBox.shrink();

        final activeFacilityId = activeFacilityState.whenOrNull(data: (d) => d);

        String facilitySwitcherTooltip = 'Switch facility';
        if (activeFacilityId == null) {
          facilitySwitcherTooltip = 'All Facilities — tap to switch';
        } else {
          final f = facilities.firstWhere(
            (x) => x.id == activeFacilityId,
            orElse: () => facilities.first,
          );
          facilitySwitcherTooltip = f.showsAsTeamMemberForViewer(currentUid)
              ? '${f.name} — Team member — tap to switch'
              : '${f.name} — tap to switch';
        }

        if (compact) {
          final screenW = MediaQuery.sizeOf(context).width;
          final menuMinWidth = math.min(screenW - 24, 320.0).clamp(260.0, 360.0);
          // Mobile / narrow top bar: icon menu + visible "Team" when not owner (no hover tooltips).
          FacilityModel? compactSelected;
          if (activeFacilityId != null) {
            for (final x in facilities) {
              if (x.id == activeFacilityId) {
                compactSelected = x;
                break;
              }
            }
          }
          final compactTeam = compactSelected != null &&
              compactSelected.showsAsTeamMemberForViewer(currentUid);
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              PopupMenuButton<String?>(
                constraints: BoxConstraints(minWidth: menuMinWidth),
                icon: Icon(
                  Icons.business,
                  color: AppTheme.primaryBlue,
                ),
                tooltip: facilitySwitcherTooltip,
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
                                child: _facilityNameWithAccessLine(
                                  context,
                                  facility,
                                  currentUid,
                                  AppTheme.dropdownItemTextStyle,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }),
                  ];
                },
              ),
              if (compactTeam)
                Padding(
                  padding: const EdgeInsets.only(left: 2),
                  child: Text(
                    'Team member',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.primaryBlue,
                    ),
                  ),
                ),
            ],
          );
        } else {
          // Full dropdown version for desktop top bar
          final colorScheme = Theme.of(context).colorScheme;
          FacilityModel? selectedFacility;
          if (activeFacilityId != null) {
            for (final x in facilities) {
              if (x.id == activeFacilityId) {
                selectedFacility = x;
                break;
              }
            }
          }
          final selectedIsTeam = selectedFacility != null &&
              selectedFacility.showsAsTeamMemberForViewer(currentUid);
          return Container(
            constraints: const BoxConstraints(maxWidth: 320),
            child: DropdownButtonFormField<String?>(
              value: activeFacilityId,
              decoration: InputDecoration(
                labelText: 'Facility',
                helperText: activeFacilityId != null && selectedIsTeam
                    ? 'You are a team member here (not the owner).'
                    : null,
                helperMaxLines: 2,
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
                ...facilities.map(
                  (f) {
                    final team = f.showsAsTeamMemberForViewer(currentUid);
                    final style = AppTheme.dropdownItemTextStyle.copyWith(
                      color: colorScheme.onSurface,
                    );
                    if (!team) {
                      return Text(
                        f.name,
                        style: style,
                        overflow: TextOverflow.ellipsis,
                        maxLines: 1,
                      );
                    }
                    return Text(
                      '${f.name} · Team member',
                      style: style,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    );
                  },
                ),
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
                            child: _facilityNameWithAccessLine(
                              context,
                              facility,
                              currentUid,
                              AppTheme.dropdownItemTextStyle,
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
