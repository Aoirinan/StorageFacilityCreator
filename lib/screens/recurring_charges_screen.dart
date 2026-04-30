import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/facility_model.dart';
import '../providers/facility_provider.dart';
import '../providers/auth_provider.dart';
import '../services/facility_creator_account_service.dart';
import '../services/recurring_charges_service.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';

class RecurringChargesScreen extends ConsumerStatefulWidget {
  const RecurringChargesScreen({super.key});

  @override
  ConsumerState<RecurringChargesScreen> createState() => _RecurringChargesScreenState();
}

class _RecurringChargesScreenState extends ConsumerState<RecurringChargesScreen> {
  String _selectedFacilityId = '';
  bool _isGenerating = false;
  DateTime? _selectedDate;

  @override
  void initState() {
    super.initState();
    _loadUserFacilities();
  }

  Future<void> _loadUserFacilities() async {
    try {
      final authState = ref.read(authStateProvider);
      if (authState.hasValue && authState.value != null) {
        final user = authState.value!;
        
        try {
          await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
          if (kDebugMode) {
            print('✅ Account verified/created for user: ${user.uid}');
          }
        } catch (accountError) {
          if (mounted) {
            print('❌ Could not ensure account exists: $accountError');
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Account setup error: $accountError. Please try again or contact support.'),
                backgroundColor: AppTheme.warning,
                duration: const Duration(seconds: 5),
                action: SnackBarAction(
                  label: 'Retry',
                  onPressed: () => _loadUserFacilities(),
                ),
              ),
            );
            return;
          }
        }

        ref.invalidate(userFacilitiesProvider(user.uid));
        final facilitiesAsync = await ref.read(userFacilitiesProvider(user.uid).future);
        final facilities = facilitiesAsync as List<FacilityModel>? ?? <FacilityModel>[];
        if (facilities.isNotEmpty) {
          setState(() {
            _selectedFacilityId = facilities.first.id;
          });
        }
      }
    } catch (e) {
      if (mounted) {
        print('❌ Error loading facilities: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading facilities: $e'),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 6),
            action: SnackBarAction(
              label: 'Retry',
              onPressed: () => _loadUserFacilities(),
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/recurring-charges',
      title: 'Recurring Charges',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        if (_selectedFacilityId.isNotEmpty)
          ElevatedButton.icon(
            onPressed: _isGenerating ? null : () => _showGenerateDialog(context),
            icon: _isGenerating
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.play_arrow),
            label: Text(_isGenerating ? 'Generating...' : 'Generate Charges'),
          ),
      ],
      child: _selectedFacilityId.isEmpty
          ? _buildNoFacilitiesMessage()
          : Column(
              children: [
                _buildFacilitySelector(),
                const SizedBox(height: 16),
                _buildInfoCard(),
                const SizedBox(height: 16),
                _buildGenerationHistory(),
              ],
            ),
    );
  }

  Widget _buildNoFacilitiesMessage() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.business,
            size: 64,
            color: AppTheme.textTertiary,
          ),
          const SizedBox(height: 16),
          Text(
            'No Facilities',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create a facility to manage recurring charges',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppTheme.textTertiary,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () => context.go(AppRoute.facilityCreate),
            icon: const Icon(Icons.add),
            label: const Text('Create Facility'),
          ),
        ],
      ),
    );
  }

  Widget _buildFacilitySelector() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(
          bottom: BorderSide(color: AppTheme.borderLight),
        ),
      ),
      child: FutureBuilder<List<FacilityModel>>(
        future: ref.read(authStateProvider).maybeWhen(
          data: (user) => user != null
              ? ref.read(userFacilitiesProvider(user.uid).future)
              : Future.value(<FacilityModel>[]),
          orElse: () => Future.value(<FacilityModel>[]),
        ),
        builder: (context, snapshot) {
          final facilities = snapshot.data ?? [];
          if (facilities.isEmpty) return const SizedBox.shrink();
          
          final style = AppTheme.dropdownItemTextStyle.copyWith(
            color: Theme.of(context).colorScheme.onSurface,
          );
          return DropdownButtonFormField<String>(
            value: _selectedFacilityId.isEmpty ? null : _selectedFacilityId,
            decoration: InputDecoration(
              labelText: 'Facility',
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            selectedItemBuilder: (context) => facilities
                .map((f) => Text(f.name, style: style, overflow: TextOverflow.ellipsis, maxLines: 1))
                .toList(),
            items: facilities.map((facility) {
              return DropdownMenuItem(
                value: facility.id,
                child: Text(facility.name),
              );
            }).toList(),
            onChanged: (value) {
              if (value != null) {
                setState(() {
                  _selectedFacilityId = value;
                });
              }
            },
          );
        },
      ),
    );
  }

  Widget _buildInfoCard() {
    return Card(
      margin: const EdgeInsets.all(16.0),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.info_outline, color: AppTheme.primaryBlue),
                const SizedBox(width: 8),
                Text(
                  'Recurring Charges Information',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              'Monthly rent charges are automatically generated on the 1st of each month for all active tenants.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              'You can also manually trigger charge generation for a specific month using the "Generate Charges" button.',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.all(12.0),
              decoration: BoxDecoration(
                color: AppTheme.info.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.schedule, color: AppTheme.info, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Automatic generation runs on the 1st of each month at 12:00 AM UTC via Cloud Function.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.info,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGenerationHistory() {
    if (_selectedFacilityId.isEmpty) {
      return Expanded(
        child: Card(
          margin: const EdgeInsets.symmetric(horizontal: 16.0),
          child: Padding(
            padding: const EdgeInsets.all(16.0),
            child: Center(
              child: Text(
                'Please select a facility to view generation history',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Expanded(
      child: Card(
        margin: const EdgeInsets.symmetric(horizontal: 16.0),
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Generation History',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              Expanded(
                child: StreamBuilder<QuerySnapshot>(
                  stream: FirebaseFirestore.instance
                      .collection('facilities')
                      .doc(_selectedFacilityId)
                      .collection('auditLogs')
                      .where('action', isEqualTo: 'recurringcharge.generated')
                      .orderBy('at', descending: true)
                      .limit(50)
                      .snapshots(),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Center(child: CircularProgressIndicator());
                    }

                    if (snapshot.hasError) {
                      return Center(
                        child: Text(
                          'Error loading history: ${snapshot.error}',
                          style: TextStyle(color: AppTheme.error),
                        ),
                      );
                    }

                    if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.history, size: 64, color: AppTheme.textTertiary),
                            const SizedBox(height: 16),
                            Text(
                              'No generation history yet',
                              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: AppTheme.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      );
                    }

                    // Group by date (group runs together)
                    final logs = snapshot.data!.docs;
                    final groupedLogs = <String, List<DocumentSnapshot>>{};
                    
                    for (final log in logs) {
                      final timestamp = log.data() as Map<String, dynamic>;
                      final at = timestamp['at'] as Timestamp?;
                      if (at != null) {
                        final dateKey = DateFormat('yyyy-MM-dd').format(at.toDate());
                        groupedLogs.putIfAbsent(dateKey, () => []).add(log);
                      }
                    }

                    return ListView.builder(
                      itemCount: groupedLogs.length,
                      itemBuilder: (context, index) {
                        final dateKey = groupedLogs.keys.elementAt(index);
                        final dateLogs = groupedLogs[dateKey]!;
                        final firstLog = dateLogs.first;
                        final timestamp = firstLog.data() as Map<String, dynamic>;
                        final at = timestamp['at'] as Timestamp?;
                        final details = timestamp['details'] as Map<String, dynamic>?;
                        final chargeType = details?['chargeType'] as String? ?? 'unknown';
                        final amount = (details?['amount'] as num?)?.toDouble() ?? 0.0;
                        final month = details?['month'] as int?;
                        final year = details?['year'] as int?;
                        final actorEmail = timestamp['actorEmail'] as String? ?? 'System';

                        return Card(
                          margin: const EdgeInsets.only(bottom: 8),
                          child: ListTile(
                            leading: CircleAvatar(
                              backgroundColor: AppTheme.primaryBlue.withOpacity(0.2),
                              child: Icon(Icons.repeat, color: AppTheme.primaryBlue),
                            ),
                            title: Text(
                              '${chargeType == 'monthlyRent' ? 'Monthly Rent' : chargeType == 'insurance' ? 'Insurance' : chargeType} Charges',
                              style: const TextStyle(fontWeight: FontWeight.bold),
                            ),
                            subtitle: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (month != null && year != null)
                                  Text('For: ${_getMonthName(month)} $year'),
                                Text('Generated: ${at != null ? DateFormat('MMM d, yyyy h:mm a').format(at.toDate()) : 'Unknown'}'),
                                Text('By: $actorEmail'),
                                Text('${dateLogs.length} charge${dateLogs.length == 1 ? '' : 's'} generated'),
                              ],
                            ),
                            trailing: Text(
                              '\$${amount.toStringAsFixed(2)}',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppTheme.primaryBlue,
                              ),
                            ),
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getMonthName(int month) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December'
    ];
    return months[month - 1];
  }

  bool _dryRun = false;

  void _showGenerateDialog(BuildContext context) {
    final now = DateTime.now();
    final firstOfMonth = DateTime(now.year, now.month, 1);
    
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Generate Recurring Charges'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Select the month to generate charges for:',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              ListTile(
                title: const Text('Target Month'),
                subtitle: Text(
                  _selectedDate != null
                      ? DateFormat('MMMM yyyy').format(_selectedDate!)
                      : DateFormat('MMMM yyyy').format(firstOfMonth),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.calendar_today),
                  onPressed: () async {
                    final date = await showDatePicker(
                      context: context,
                      initialDate: _selectedDate ?? firstOfMonth,
                      firstDate: DateTime(2020),
                      lastDate: DateTime(now.year + 1, 12, 31),
                      initialDatePickerMode: DatePickerMode.year,
                    );
                    if (date != null) {
                      setState(() {
                        _selectedDate = DateTime(date.year, date.month, 1);
                      });
                    }
                  },
                ),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                title: const Text('Dry Run (Preview Only)'),
                subtitle: const Text('Preview charges without creating them'),
                value: _dryRun,
                onChanged: (value) {
                  setState(() {
                    _dryRun = value ?? false;
                  });
                },
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12.0),
                decoration: BoxDecoration(
                  color: _dryRun 
                      ? AppTheme.info.withOpacity(0.1)
                      : AppTheme.warning.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      _dryRun ? Icons.visibility : Icons.warning_amber,
                      color: _dryRun ? AppTheme.info : AppTheme.warning,
                      size: 20,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _dryRun
                            ? 'Preview mode: This will show what charges would be created without actually creating them.'
                            : 'This will generate rent charges for all active tenants. Existing charges for the selected month will be skipped.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: _dryRun ? AppTheme.info : AppTheme.warning,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _selectedDate = null;
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                _generateCharges(_selectedDate ?? firstOfMonth, _dryRun);
              },
              child: Text(_dryRun ? 'Preview' : 'Generate'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _generateCharges(DateTime targetDate, bool dryRun) async {
    if (_selectedFacilityId.isEmpty) return;

    setState(() {
      _isGenerating = true;
    });

    try {
      final result = await RecurringChargesService.generateMonthlyRentCharges(
        facilityId: _selectedFacilityId,
        forDate: targetDate,
        dryRun: dryRun,
      );

      if (mounted) {
        if (result.success) {
          if (dryRun) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Preview: ${result.successCount} charges would be created (${result.skippedCount} skipped)',
                ),
                backgroundColor: AppTheme.info,
                duration: const Duration(seconds: 5),
              ),
            );
          } else {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'Generated ${result.successCount} charges. '
                  '${result.skippedCount} skipped (already exist). '
                  '${result.errorCount} errors.',
                ),
                backgroundColor: (result.errorCount ?? 0) > 0 ? AppTheme.warning : AppTheme.success,
                duration: const Duration(seconds: 5),
              ),
            );

            if (result.errors.isNotEmpty) {
              // Show errors in a dialog
              showDialog(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Generation Errors'),
                  content: SingleChildScrollView(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'The following errors occurred during generation:',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 16),
                        ...result.errors.map((error) => Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Text(
                            '• $error',
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.error,
                            ),
                          ),
                        )),
                      ],
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                  ],
                ),
              );
            }
          }
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error generating charges: ${result.error ?? "Unknown error"}'),
              backgroundColor: AppTheme.error,
              duration: const Duration(seconds: 5),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error generating charges: $e'),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
          _selectedDate = null;
        });
      }
    }
  }
}

