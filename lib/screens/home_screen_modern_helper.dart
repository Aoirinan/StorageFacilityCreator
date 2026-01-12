import 'package:flutter/material.dart';
import '../models/facility_model.dart';

// Facility selection classes - moved outside to avoid nesting issues
class FacilitySelectResult {
  final String id;
  final String name;

  const FacilitySelectResult({
    required this.id,
    required this.name,
  });
}

class FacilityPickerSheet extends StatelessWidget {
  final List<FacilityModel> facilities;

  const FacilityPickerSheet({super.key, required this.facilities});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 48,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.shade400,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Select Facility',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.6,
              ),
              child: ListView.separated(
                shrinkWrap: true,
                itemCount: facilities.length,
                separatorBuilder: (_, __) => const Divider(height: 1),
                itemBuilder: (context, index) {
                  final facility = facilities[index];
                  return ListTile(
                    leading: const Icon(Icons.business),
                    title: Text(facility.name),
                    subtitle: facility.address?.isNotEmpty == true
                        ? Text(facility.address!)
                        : null,
                    onTap: () {
                      Navigator.of(context).pop(
                        FacilitySelectResult(
                          id: facility.id,
                          name: facility.name,
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

