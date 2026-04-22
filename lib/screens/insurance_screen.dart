import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/facility_service.dart';
import '../services/facility_creator_account_service.dart';
import '../services/insurance_service.dart';
import '../models/facility_model.dart';
import '../models/tenant_insurance_model.dart';
import '../providers/search_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';

const _kAllFacilitiesIns = '__all__';

class InsuranceScreen extends ConsumerStatefulWidget {
  const InsuranceScreen({super.key});

  @override
  ConsumerState<InsuranceScreen> createState() => _InsuranceScreenState();
}

class _InsuranceScreenState extends ConsumerState<InsuranceScreen> {
  List<FacilityModel> _facilities = [];
  // null = loading; _kAllFacilitiesIns = all; otherwise a real facility id
  String? _selectedFacilityId;
  bool _loadingFacilities = true;

  // Per-facility insurance settings stored in Firestore
  bool _savingSettings = false;
  final _referralUrlController = TextEditingController();
  final _referralNameController = TextEditingController();
  final _referralNotesController = TextEditingController();
  bool _settingsLoaded = false;

  bool get _isAllFacilities => _selectedFacilityId == _kAllFacilitiesIns;

  @override
  void initState() {
    super.initState();
    _loadFacilities();
  }

  @override
  void dispose() {
    _referralUrlController.dispose();
    _referralNameController.dispose();
    _referralNotesController.dispose();
    super.dispose();
  }

  Future<void> _loadFacilities() async {
    try {
      await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
      final facilities = await FacilityService.getUserFacilities();
      if (mounted) {
        // Respect global picker if already set, otherwise default to All Facilities
        final globalFacility = ref.read(selectedFacilityProvider);
        final initialId = (globalFacility != null && facilities.any((f) => f.id == globalFacility.id))
            ? globalFacility.id
            : _kAllFacilitiesIns;
        setState(() {
          _facilities = facilities;
          _selectedFacilityId = initialId;
          _loadingFacilities = false;
        });
        if (!_isAllFacilities && _selectedFacilityId != null) {
          await _loadInsuranceSettings(_selectedFacilityId!);
        }
      }
    } catch (e) {
      if (mounted) setState(() => _loadingFacilities = false);
    }
  }

  Future<void> _loadInsuranceSettings(String facilityId) async {
    setState(() => _settingsLoaded = false);
    try {
      final doc = await FirebaseFirestore.instance
          .collection('facilities')
          .doc(facilityId)
          .collection('settings')
          .doc('insurance')
          .get();
      if (mounted) {
        final data = doc.data();
        _referralUrlController.text = data?['referralUrl'] as String? ?? '';
        _referralNameController.text = data?['referralName'] as String? ?? '';
        _referralNotesController.text = data?['referralNotes'] as String? ?? '';
        setState(() => _settingsLoaded = true);
      }
    } catch (e) {
      if (mounted) setState(() => _settingsLoaded = true);
    }
  }

  Future<void> _saveSettings() async {
    if (_selectedFacilityId == null || _isAllFacilities) return;
    setState(() => _savingSettings = true);
    try {
      await FirebaseFirestore.instance
          .collection('facilities')
          .doc(_selectedFacilityId!)
          .collection('settings')
          .doc('insurance')
          .set({
        'referralUrl': _referralUrlController.text.trim(),
        'referralName': _referralNameController.text.trim(),
        'referralNotes': _referralNotesController.text.trim(),
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Insurance settings saved.'), behavior: SnackBarBehavior.floating),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error saving: $e'), behavior: SnackBarBehavior.floating, backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _savingSettings = false);
    }
  }

  Future<void> _launchUrl(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Sync with global facility picker
    final globalFacility = ref.watch(selectedFacilityProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final globalId = globalFacility?.id;
      if (globalId != null && _selectedFacilityId != globalId) {
        setState(() => _selectedFacilityId = globalId);
        _loadInsuranceSettings(globalId);
      }
    });

    if (_loadingFacilities) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_facilities.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.shield_outlined, size: 64, color: AppTheme.textTertiary),
            const SizedBox(height: 16),
            const Text('No Facilities Found', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text('Create a facility to manage insurance settings.', style: TextStyle(color: AppTheme.textSecondary)),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFacilitySelector(),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildInfoBanner(),
                const SizedBox(height: 16),
                if (!_isAllFacilities) ...[
                  _buildReferralCard(),
                  const SizedBox(height: 16),
                ],
                _buildTenantTrackingCard(),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildFacilitySelector() {
    if (_facilities.isEmpty) return const SizedBox.shrink();

    final effectiveId = (_selectedFacilityId == _kAllFacilitiesIns ||
            _facilities.any((f) => f.id == _selectedFacilityId))
        ? _selectedFacilityId
        : _kAllFacilitiesIns;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          DropdownButtonFormField<String>(
            value: effectiveId,
            decoration: const InputDecoration(
              labelText: 'Facility',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: [
              const DropdownMenuItem<String>(
                value: _kAllFacilitiesIns,
                child: Text('All Facilities'),
              ),
              ..._facilities.map((f) => DropdownMenuItem<String>(
                value: f.id,
                child: Text(f.name),
              )),
            ],
            onChanged: (id) async {
              if (id == null) return;
              setState(() => _selectedFacilityId = id);
              // Sync global picker
              if (id == _kAllFacilitiesIns) {
                ref.read(selectedFacilityProvider.notifier).state = null;
              } else {
                final picked = _facilities.firstWhere((f) => f.id == id);
                ref.read(selectedFacilityProvider.notifier).state = picked;
                await _loadInsuranceSettings(id);
              }
            },
          ),
          if (_isAllFacilities)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                'Showing insurance tracking across all your facilities.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildInfoBanner() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.primaryBlue.withOpacity(0.07),
        border: Border.all(color: AppTheme.primaryBlue.withOpacity(0.25)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, color: AppTheme.primaryBlueDark, size: 20),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Storage Facility Creator does not provide or sell insurance. '
              'This section lets you recommend an insurance provider to your tenants '
              'and keep track of which tenants have coverage.',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildReferralCard() {
    final theme = Theme.of(context);
    final url = _referralUrlController.text.trim();
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Insurance Referral Link', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Add a link to the insurance provider you recommend. This will be visible to your tenants.',
              style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _referralNameController,
              decoration: const InputDecoration(
                labelText: 'Provider Name (e.g. "Example Insurance")',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _referralUrlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'Website URL (e.g. https://example.com)',
                border: OutlineInputBorder(),
                isDense: true,
                prefixIcon: Icon(Icons.link),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _referralNotesController,
              maxLines: 2,
              decoration: const InputDecoration(
                labelText: 'Notes for tenants (optional)',
                border: OutlineInputBorder(),
                isDense: true,
                hintText: 'e.g. "Mention our facility name for a discount."',
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                FilledButton(
                  onPressed: _savingSettings ? null : _saveSettings,
                  child: _savingSettings
                      ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Text('Save'),
                ),
                if (url.isNotEmpty) ...[
                  const SizedBox(width: 12),
                  OutlinedButton.icon(
                    onPressed: () => _launchUrl(url),
                    icon: const Icon(Icons.open_in_new, size: 16),
                    label: const Text('Preview Link'),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.copy, size: 18),
                    tooltip: 'Copy URL',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: url));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('URL copied.'), behavior: SnackBarBehavior.floating),
                      );
                    },
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTenantTrackingCard() {
    final theme = Theme.of(context);
    if (_selectedFacilityId == null) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Tenant Insurance Tracking', style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              'Track which tenants have provided proof of insurance. '
              'Update a tenant\'s insurance status from their profile page.',
              style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            if (_isAllFacilities)
              _buildAllFacilitiesTenantTracking(theme)
            else
              _buildSingleFacilityTenantTracking(_selectedFacilityId!, theme),
          ],
        ),
      ),
    );
  }

  Widget _buildSingleFacilityTenantTracking(String facilityId, ThemeData theme) {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('facilities')
          .doc(facilityId)
          .collection('tenants')
          .where('isActive', isEqualTo: true)
          .orderBy('name')
          .snapshots(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
          return Text('No active tenants found.', style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary));
        }
        return _buildTenantList(snapshot.data!.docs, theme, showFacilityLabel: false);
      },
    );
  }

  Widget _buildAllFacilitiesTenantTracking(ThemeData theme) {
    if (_facilities.isEmpty) {
      return Text('No facilities found.', style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary));
    }

    // Build a stream for each facility and combine results
    final streams = _facilities
        .map((f) => FirebaseFirestore.instance
            .collection('facilities')
            .doc(f.id)
            .collection('tenants')
            .where('isActive', isEqualTo: true)
            .orderBy('name')
            .snapshots()
            .map((snap) => (facilityId: f.id, facilityName: f.name, docs: snap.docs)))
        .toList();

    return StreamBuilder<List<({String facilityId, String facilityName, List<QueryDocumentSnapshot> docs})>>(
      stream: _combineStreams(streams),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final allEntries = snapshot.data!;
        // Flatten all docs, tagging each with its facility name
        final allDocs = <({QueryDocumentSnapshot doc, String facilityName})>[];
        for (final entry in allEntries) {
          for (final doc in entry.docs) {
            allDocs.add((doc: doc, facilityName: entry.facilityName));
          }
        }
        if (allDocs.isEmpty) {
          return Text('No active tenants found across any facility.', style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary));
        }

        final withInsurance = allDocs.where((e) {
          final status = (e.doc.data() as Map<String, dynamic>)['insuranceStatus'] as String?;
          return status != null && status != 'none';
        }).toList();
        final withoutInsurance = allDocs.where((e) {
          final status = (e.doc.data() as Map<String, dynamic>)['insuranceStatus'] as String?;
          return status == null || status == 'none';
        }).toList();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _summaryChip('${allDocs.length} Total Tenants', AppTheme.primaryBlueDark),
                _summaryChip('${withInsurance.length} With Insurance', AppTheme.success),
                _summaryChip('${withoutInsurance.length} No Insurance on File', AppTheme.warning),
              ],
            ),
            if (withInsurance.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('Tenants with insurance on file', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              ...withInsurance.map((e) => _tenantInsuranceRowTagged(e.doc, e.facilityName, theme)),
            ],
            if (withoutInsurance.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text('No insurance on file', style: theme.textTheme.titleSmall),
              const SizedBox(height: 8),
              ...withoutInsurance.map((e) => _tenantInsuranceRowTagged(e.doc, e.facilityName, theme)),
            ],
          ],
        );
      },
    );
  }

  /// Combines multiple streams into a single stream that emits whenever any upstream emits.
  Stream<List<T>> _combineStreams<T>(List<Stream<T>> streams) {
    if (streams.isEmpty) return Stream.value([]);
    final latest = List<T?>.filled(streams.length, null);
    int received = 0;

    return Stream.multi((controller) {
      for (int i = 0; i < streams.length; i++) {
        final idx = i;
        streams[idx].listen(
          (value) {
            if (latest[idx] == null) received++;
            latest[idx] = value;
            if (received == streams.length) {
              controller.add(latest.cast<T>());
            }
          },
          onError: controller.addError,
        );
      }
    });
  }

  Widget _buildTenantList(List<QueryDocumentSnapshot> docs, ThemeData theme, {required bool showFacilityLabel}) {
    final withInsurance = docs.where((d) {
      final status = (d.data() as Map<String, dynamic>)['insuranceStatus'] as String?;
      return status != null && status != 'none';
    }).toList();
    final withoutInsurance = docs.where((d) {
      final status = (d.data() as Map<String, dynamic>)['insuranceStatus'] as String?;
      return status == null || status == 'none';
    }).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _summaryChip('${docs.length} Total Tenants', AppTheme.primaryBlueDark),
            _summaryChip('${withInsurance.length} With Insurance', AppTheme.success),
            _summaryChip('${withoutInsurance.length} No Insurance on File', AppTheme.warning),
          ],
        ),
        if (withInsurance.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Tenants with insurance on file', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          ...withInsurance.map((d) => _tenantInsuranceRow(d, theme)),
        ],
        if (withoutInsurance.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('No insurance on file', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          ...withoutInsurance.map((d) => _tenantInsuranceRow(d, theme)),
        ],
      ],
    );
  }

  Widget _summaryChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        border: Border.all(color: color.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(label, style: TextStyle(fontSize: 12, color: color, fontWeight: FontWeight.w600)),
    );
  }

  Widget _tenantInsuranceRow(DocumentSnapshot doc, ThemeData theme, {String? facilityName}) {
    final data = doc.data() as Map<String, dynamic>;
    final name = data['name'] as String? ?? 'Unknown';
    final unit = data['unitNumber'] as String? ?? '';
    final status = data['insuranceStatus'] as String? ?? 'none';
    final provider = data['insuranceProvider'] as String?;

    Color statusColor;
    String statusLabel;
    switch (status) {
      case 'providedProof':
        statusColor = AppTheme.success;
        statusLabel = 'Proof Provided';
        break;
      case 'enrolledInTPP':
        statusColor = AppTheme.success;
        statusLabel = 'Enrolled';
        break;
      case 'pendingProof':
        statusColor = AppTheme.warning;
        statusLabel = 'Pending Proof';
        break;
      default:
        statusColor = AppTheme.textTertiary;
        statusLabel = 'None';
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, size: 16, color: statusColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '$name${unit.isNotEmpty ? ' · Unit $unit' : ''}${provider != null && provider.isNotEmpty ? ' · $provider' : ''}',
                  style: theme.textTheme.bodyMedium,
                ),
                if (facilityName != null)
                  Text(
                    facilityName,
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                  ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: statusColor.withOpacity(0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Text(statusLabel, style: TextStyle(fontSize: 11, color: statusColor, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    );
  }

  Widget _tenantInsuranceRowTagged(DocumentSnapshot doc, String facilityName, ThemeData theme) {
    return _tenantInsuranceRow(doc, theme, facilityName: facilityName);
  }
}
