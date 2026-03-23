import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/providers/feature_flag_provider.dart';
import 'package:sfcapp/screens/facility_map_builder_v2_screen.dart';
import 'package:sfcapp/screens/facility_map_editor_screen.dart';
import 'package:sfcapp/services/facility_map_v2_service.dart';

class UnitsMapEntryScreen extends ConsumerWidget {
  final String facilityId;

  const UnitsMapEntryScreen({
    super.key,
    required this.facilityId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final globalEnabled = ref.watch(featureFlagEnabledProvider('mapEngineV2'));
    if (!globalEnabled) {
      return FacilityMapEditorScreen(facilityId: facilityId);
    }

    return StreamBuilder(
      stream: FacilityMapV2Service.metaStream(facilityId),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final enabledForFacility = snapshot.data!.enabledForFacility;
        if (!enabledForFacility) {
          return Column(
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                color: Colors.amber.withOpacity(0.15),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Map Engine V2 is available for this facility. Enable it when ready; legacy map remains available.',
                      ),
                    ),
                    TextButton(
                      onPressed: () => FacilityMapV2Service.setFacilityV2Enabled(
                        facilityId: facilityId,
                        enabled: true,
                      ),
                      child: const Text('Enable V2'),
                    ),
                  ],
                ),
              ),
              Expanded(child: FacilityMapEditorScreen(facilityId: facilityId)),
            ],
          );
        }
        return FacilityMapBuilderV2Screen(facilityId: facilityId);
      },
    );
  }
}
