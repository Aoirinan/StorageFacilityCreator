import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/services/error_reporter.dart';
import 'package:sfcapp/widgets/facilities_load_error.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/facility_service.dart';
import '../services/facility_creator_account_service.dart';
import '../services/insurance_service.dart';
import '../models/facility_model.dart';
import '../models/tenant_insurance_model.dart';
import '../providers/search_provider.dart';
import '../providers/facility_provider.dart' as cached_facility_providers;
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
  Object? _facilitiesError;

  bool get _isAllFacilities => _selectedFacilityId == _kAllFacilitiesIns;

  @override
  void initState() {
    super.initState();
    _loadFacilities();
  }

  Future<void> _loadFacilities({bool retry = false}) async {
    // Only creation flows need the account, so a failed account read must not
    // stop the facilities loading.
    FacilityCreatorAccountService.ensureAccountInBackground();
    try {
      final uid = (await ref.read(authStateProvider.future))?.uid;
      if (!mounted) return;
      if (retry && uid != null) {
        ref.invalidate(cached_facility_providers.userFacilitiesProvider(uid));
      }
      final facilities = uid == null
          ? await FacilityService.getUserFacilities(throwOnError: true)
          : await ref.read(cached_facility_providers.userFacilitiesProvider(uid).future);
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
          _facilitiesError = null;
        });
      }
    } catch (e, st) {
      // Shown with a Retry: it used to fall through to "No Facilities Found".
      ErrorReporter.reportError(e, st, context: 'InsuranceScreen._loadFacilities');
      if (mounted) {
        setState(() {
          _loadingFacilities = false;
          _facilitiesError = e;
        });
      }
    }
  }

  void _retryLoadFacilities() {
    setState(() {
      _loadingFacilities = true;
      _facilitiesError = null;
    });
    _loadFacilities(retry: true);
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
      }
    });

    if (_loadingFacilities) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_facilitiesError != null) {
      return FacilitiesLoadError(onRetry: _retryLoadFacilities);
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
                if (!_isAllFacilities && _selectedFacilityId != null) ...[
                  InsuranceReferralCard(facilityId: _selectedFacilityId!),
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
            onChanged: (id) {
              if (id == null) return;
              setState(() => _selectedFacilityId = id);
              // Sync global picker
              if (id == _kAllFacilitiesIns) {
                ref.read(selectedFacilityProvider.notifier).state = null;
              } else {
                final picked = _facilities.firstWhere((f) => f.id == id);
                ref.read(selectedFacilityProvider.notifier).state = picked;
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

/// A facility's insurance referral form. The save writes all three fields, so
/// the form and its Save show only once [facilityId]'s saved referral is in
/// them: before a load, or after a failed one, they are blank or hold another
/// facility's values, and saving would write those over its link.
class InsuranceReferralCard extends StatefulWidget {
  const InsuranceReferralCard({super.key, required this.facilityId});

  final String facilityId;

  @override
  State<InsuranceReferralCard> createState() => _InsuranceReferralCardState();
}

class _InsuranceReferralCardState extends State<InsuranceReferralCard> {
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();
  final _notesController = TextEditingController();

  /// The facility whose saved referral is in the fields; null while a load
  /// runs or after one fails.
  String? _loadedFacilityId;
  Object? _loadError;
  bool _saving = false;

  /// Bumped by every load, so a slower load for a facility the owner has
  /// switched away from cannot land in the next one's fields.
  int _loadSeq = 0;

  bool get _loaded => _loadedFacilityId == widget.facilityId;

  @override
  void initState() {
    super.initState();
    _startLoad();
  }

  @override
  void didUpdateWidget(InsuranceReferralCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.facilityId != widget.facilityId) _startLoad();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// Callers rebuild after this (initState, didUpdateWidget, or setState).
  void _startLoad() {
    final seq = ++_loadSeq;
    _loadedFacilityId = null;
    _loadError = null;
    _load(widget.facilityId, seq);
  }

  Future<void> _load(String facilityId, int seq) async {
    try {
      final referral = await InsuranceService.getReferral(facilityId);
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _nameController.text = referral.name;
        _urlController.text = referral.url;
        _notesController.text = referral.notes;
        _loadedFacilityId = facilityId;
      });
    } catch (e, st) {
      ErrorReporter.reportError(e, st, context: 'InsuranceReferralCard._load');
      if (!mounted || seq != _loadSeq) return;
      setState(() => _loadError = e);
    }
  }

  Future<void> _save() async {
    if (!_loaded) return;
    final facilityId = _loadedFacilityId!;
    setState(() => _saving = true);
    try {
      await InsuranceService.saveReferral(facilityId, (
        name: _nameController.text.trim(),
        url: _urlController.text.trim(),
        notes: _notesController.text.trim(),
      ));
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
      if (mounted) setState(() => _saving = false);
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
    final theme = Theme.of(context);
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
            if (_loadError != null)
              _buildLoadError(theme)
            else if (!_loaded)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 16),
                child: LinearProgressIndicator(),
              )
            else
              _buildForm(),
          ],
        ),
      ),
    );
  }

  Widget _buildLoadError(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.error_outline, size: 20, color: AppTheme.error),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                "Couldn't load this facility's insurance referral. Check your connection and try again.",
                style: theme.textTheme.bodyMedium,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: () => setState(_startLoad),
          icon: const Icon(Icons.refresh),
          label: const Text('Retry'),
        ),
      ],
    );
  }

  Widget _buildForm() {
    final url = _urlController.text.trim();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(
            labelText: 'Provider Name (e.g. "Example Insurance")',
            border: OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _urlController,
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
          controller: _notesController,
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
              onPressed: _saving ? null : _save,
              child: _saving
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
    );
  }
}
