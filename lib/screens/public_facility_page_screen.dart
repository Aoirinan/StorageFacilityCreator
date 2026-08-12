import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/foundation.dart';
import '../services/facility_public_service.dart';
import '../services/public_rental_service.dart';
import '../models/facility_model.dart';
import '../models/facility_public_settings_model.dart';
import '../widgets/unit_availability_widget.dart';
import '../theme/app_theme.dart';
import '../services/facility_map_v2_service.dart';
import '../widgets/keyboard_scrollable.dart';

/// Public facility showcase page
/// Accessible via /facility/:facilityId or custom domain
class PublicFacilityPageScreen extends StatefulWidget {
  final String? facilityId;

  const PublicFacilityPageScreen({
    super.key,
    this.facilityId,
  });

  @override
  State<PublicFacilityPageScreen> createState() =>
      _PublicFacilityPageScreenState();
}

class _PublicFacilityPageScreenState extends State<PublicFacilityPageScreen> {
  FacilityModel? _facility;
  FacilityPublicSettings? _settings;
  bool _isLoading = true;
  String? _error;
  String? _publicMapSlug;

  @override
  void initState() {
    super.initState();
    _loadFacility();
  }

  Future<void> _loadFacility() async {
    final facilityId = widget.facilityId ?? _getFacilityIdFromUrl();
    if (facilityId == null || facilityId.isEmpty) {
      setState(() {
        _error = 'Facility not found';
        _isLoading = false;
      });
      return;
    }

    try {
      final facility = await PublicRentalService.getFacility(facilityId);
      final settings =
          await FacilityPublicService.getPublicSettings(facilityId);
      final mapSlug =
          await FacilityMapV2Service.getPublicSlugForFacility(facilityId);

      if (facility == null) {
        setState(() {
          _error = 'Facility not found';
          _isLoading = false;
        });
        return;
      }

      // Check if public page is enabled
      if (settings != null && !settings.enabled) {
        setState(() {
          _error = 'This facility page is not publicly available';
          _isLoading = false;
        });
        return;
      }

      setState(() {
        _facility = facility;
        _settings = settings;
        _publicMapSlug = mapSlug;
        _isLoading = false;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error loading facility page: $e');
      }
      setState(() {
        _error = 'Error loading facility information';
        _isLoading = false;
      });
    }
  }

  String? _getFacilityIdFromUrl() {
    final uri = Uri.base;
    final pathSegments = uri.pathSegments;
    // Check if path is /facility/:facilityId
    if (pathSegments.length >= 2 && pathSegments[0] == 'facility') {
      return pathSegments[1];
    }
    return uri.queryParameters['facilityId'];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: KeyboardScrollable(
        child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline,
                          size: 64, color: AppTheme.error),
                      const SizedBox(height: 16),
                      Text(_error!, style: const TextStyle(fontSize: 16)),
                    ],
                  ),
                )
              : _facility == null
                  ? const Center(child: Text('Facility not found'))
                  : SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildHeader(),
                          _buildFeaturedSection(),
                          if (_settings?.showAvailableUnits ?? true)
                            _buildUnitsSection(),
                          _buildContactSection(),
                        ],
                      ),
                    ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.primaryBlueDark,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_facility?.logoUrl != null) ...[
            Image.network(
              _facility!.logoUrl!,
              height: 80,
              errorBuilder: (context, error, stackTrace) => const SizedBox(),
            ),
            const SizedBox(height: 16),
          ],
          Text(
            _facility?.name ?? '',
            style: const TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          if (_settings?.pageDescription != null ||
              _facility?.description != null) ...[
            const SizedBox(height: 12),
            Text(
              _settings?.pageDescription ?? _facility?.description ?? '',
              style: const TextStyle(
                fontSize: 16,
                color: Colors.white70,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFeaturedSection() {
    final featuredImages = _settings?.featuredImages ?? [];
    if (featuredImages.isEmpty) return const SizedBox.shrink();

    return Container(
      height: 300,
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 8,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: PageView.builder(
          itemCount: featuredImages.length,
          itemBuilder: (context, index) {
            return Image.network(
              featuredImages[index],
              fit: BoxFit.cover,
              errorBuilder: (context, error, stackTrace) => Container(
                color: AppTheme.backgroundLight,
                child: const Icon(Icons.image, size: 64),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildUnitsSection() {
    if (_facility == null) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Available Units',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: UnitAvailabilityWidget(
                facilityId: _facility!.id,
                allowReservation: _settings?.allowOnlineReservations ?? true,
              ),
            ),
          ),
          if (_settings?.allowOnlineReservations ?? true) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () {
                  final slug = _publicMapSlug;
                  if (slug != null && slug.isNotEmpty) {
                    context.push('/f/$slug/rent');
                  } else {
                    context.push('/rental?facilityId=${_facility!.id}');
                  }
                },
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  backgroundColor: AppTheme.primaryBlueDark,
                  foregroundColor: Colors.white,
                ),
                child: const Text('View All Units & Reserve'),
              ),
            ),
            if (_publicMapSlug != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () =>
                      context.push('/public/${_publicMapSlug!}/map'),
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('View Facility Map'),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildContactSection() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Contact Us',
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 16),
          if (_facility?.address != null) ...[
            _buildContactRow(Icons.location_on, _facility!.address!),
            const SizedBox(height: 12),
          ],
          if (_facility?.phone != null) ...[
            _buildContactRow(Icons.phone, _facility!.phone!),
            const SizedBox(height: 12),
          ],
          if (_facility?.email != null) ...[
            _buildContactRow(Icons.email, _facility!.email!),
          ],
        ],
      ),
    );
  }

  Widget _buildContactRow(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 20, color: AppTheme.primaryBlueDark),
        const SizedBox(width: 12),
        Expanded(child: Text(text)),
      ],
    );
  }
}
