import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import '../services/public_rental_service.dart';
import '../models/unit_model.dart';
import '../theme/app_theme.dart';
import 'package:intl/intl.dart';

/// Embeddable widget for displaying unit availability
/// Can be embedded on external websites
class UnitAvailabilityWidget extends StatefulWidget {
  final String facilityId;
  final int? maxUnits; // Maximum number of units to display
  final bool showPricing;
  final bool showDetails;
  final bool allowReservation; // Show reservation button

  const UnitAvailabilityWidget({
    super.key,
    required this.facilityId,
    this.maxUnits,
    this.showPricing = true,
    this.showDetails = true,
    this.allowReservation = true,
  });

  @override
  State<UnitAvailabilityWidget> createState() => _UnitAvailabilityWidgetState();
}

class _UnitAvailabilityWidgetState extends State<UnitAvailabilityWidget> {
  List<UnitModel> _units = [];
  bool _isLoading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadUnits();
  }

  Future<void> _loadUnits() async {
    try {
      final units = await PublicRentalService.getAvailableUnits(widget.facilityId);
      final displayedUnits = widget.maxUnits != null
          ? units.take(widget.maxUnits!).toList()
          : units;

      setState(() {
        _units = displayedUnits;
        _isLoading = false;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error loading units for widget: $e');
      }
      setState(() {
        _error = 'Unable to load units';
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 200),
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Text(
                      _error!,
                      style: TextStyle(color: AppTheme.error),
                    ),
                  ),
                )
              : _units.isEmpty
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(16.0),
                        child: Text('No units currently available'),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: _units.length,
                      itemBuilder: (context, index) {
                        return _buildUnitCard(_units[index]);
                      },
                    ),
    );
  }

  Widget _buildUnitCard(UnitModel unit) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        title: Text(
          'Unit ${unit.unitNumber}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.showDetails) ...[
              const SizedBox(height: 4),
              Text('Type: ${unit.unitType}'),
              if (unit.description != null) ...[
                const SizedBox(height: 4),
                Text(unit.description!),
              ],
            ],
          ],
        ),
        trailing: widget.showPricing
            ? Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    '\$${unit.monthlyRate.toStringAsFixed(2)}/mo',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      color: AppTheme.primaryBlueDark,
                    ),
                  ),
                  if (widget.allowReservation) ...[
                    const SizedBox(height: 4),
                    ElevatedButton(
                      onPressed: () => _handleReservation(unit),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      ),
                      child: const Text('Reserve'),
                    ),
                  ],
                ],
              )
            : null,
        isThreeLine: widget.showDetails && unit.description != null,
      ),
    );
  }

  void _handleReservation(UnitModel unit) {
    // Open reservation in new window/tab or show dialog
    // For embedded widget, might want to open parent window
    if (kIsWeb) {
      // In web context, we can navigate to the reservation page
      // This would need to be handled by the parent page
    }
    // Could also show a dialog or bottom sheet
  }
}

