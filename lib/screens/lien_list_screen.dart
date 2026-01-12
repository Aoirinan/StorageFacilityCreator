import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../models/lien_model.dart';
import '../models/facility_model.dart';
import '../providers/facility_provider.dart';
import '../providers/auth_provider.dart';
import '../services/facility_creator_account_service.dart';
import '../services/lien_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import 'lien_detail_screen.dart';

/// Provider for liens stream (by facility)
final liensForFacilityProvider = StreamProvider.family<List<LienModel>, String>((ref, facilityId) {
  return LienService.getLiensForFacilityStream(facilityId);
});

class LienListScreen extends ConsumerStatefulWidget {
  const LienListScreen({super.key});

  @override
  ConsumerState<LienListScreen> createState() => _LienListScreenState();
}

class _LienListScreenState extends ConsumerState<LienListScreen> {
  String _selectedFacilityId = '';
  LienStage? _stageFilter;
  LienStatus? _statusFilter;

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
        } catch (accountError) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Account setup error: $accountError'),
                backgroundColor: AppTheme.warning,
              ),
            );
            return;
          }
        }
        
        await Future.delayed(const Duration(milliseconds: 500));
        
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading facilities: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/liens',
      title: 'Liens & Auctions',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        IconButton(
          icon: const Icon(Icons.filter_list),
          onPressed: () => _showFiltersDialog(context),
          tooltip: 'Filter',
        ),
      ],
      child: _selectedFacilityId.isEmpty
          ? _buildNoFacilitiesMessage()
          : Column(
              children: [
                _buildFilters(),
                _buildStats(),
                Expanded(
                  child: _buildLiensList(),
                ),
              ],
            ),
    );
  }

  Widget _buildNoFacilitiesMessage() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.business, size: 64, color: AppTheme.textTertiary),
          const SizedBox(height: 16),
          Text(
            'No Facilities',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
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
          
          return DropdownButtonFormField<String>(
            value: _selectedFacilityId.isEmpty ? null : _selectedFacilityId,
            decoration: InputDecoration(
              labelText: 'Facility',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
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

  Widget _buildStats() {
    if (_selectedFacilityId.isEmpty) return const SizedBox.shrink();

    final liensAsync = ref.watch(liensForFacilityProvider(_selectedFacilityId));

    return liensAsync.when(
      data: (liens) {
        final active = liens.where((l) => l.isActiveLien).length;
        final filed = liens.where((l) => l.currentStage == LienStage.lienFiled).length;
        final auctionScheduled = liens.where((l) => l.currentStage == LienStage.auctionScheduled).length;
        final resolved = liens.where((l) => l.status == LienStatus.resolved).length;
        final totalAmount = liens.where((l) => l.isActiveLien).fold(0.0, (sum, l) => sum + l.totalAmount);

        return Container(
          padding: const EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color: AppTheme.backgroundLight,
            border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
          ),
          child: Row(
            children: [
              _buildStatCard('Active Liens', active.toString(), Icons.gavel, AppTheme.warning),
              const SizedBox(width: 16),
              _buildStatCard('Filed', filed.toString(), Icons.description, AppTheme.info),
              const SizedBox(width: 16),
              _buildStatCard('Auction Scheduled', auctionScheduled.toString(), Icons.calendar_today, AppTheme.error),
              const SizedBox(width: 16),
              _buildStatCard('Resolved', resolved.toString(), Icons.check_circle, AppTheme.success),
              const SizedBox(width: 16),
              _buildStatCard('Total Amount', '\$${totalAmount.toStringAsFixed(2)}', Icons.attach_money, AppTheme.primaryBlue),
            ],
          ),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => Padding(
        padding: const EdgeInsets.all(16.0),
        child: Text('Error loading stats: $error', style: TextStyle(color: AppTheme.error)),
      ),
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, Color color) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            children: [
              Icon(icon, color: color, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildLiensList() {
    if (_selectedFacilityId.isEmpty) {
      return const Center(child: Text('Select a facility'));
    }

    final liensAsync = ref.watch(liensForFacilityProvider(_selectedFacilityId));

    return liensAsync.when(
      data: (liens) {
        var filteredLiens = liens;
        
        if (_stageFilter != null) {
          filteredLiens = filteredLiens.where((l) => l.currentStage == _stageFilter).toList();
        }
        
        if (_statusFilter != null) {
          filteredLiens = filteredLiens.where((l) => l.status == _statusFilter).toList();
        }

        if (filteredLiens.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.gavel, size: 64, color: AppTheme.textTertiary),
                const SizedBox(height: 16),
                Text(
                  _stageFilter != null || _statusFilter != null
                      ? 'No liens match your filters'
                      : 'No liens yet',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16.0),
          itemCount: filteredLiens.length,
          itemBuilder: (context, index) {
            final lien = filteredLiens[index];
            return _buildLienCard(lien);
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: AppTheme.error),
            const SizedBox(height: 16),
            Text(
              'Error loading liens',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: AppTheme.error,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              error.toString(),
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => ref.invalidate(liensForFacilityProvider(_selectedFacilityId)),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLienCard(LienModel lien) {
    final stageColor = _getStageColor(lien.currentStage);
    final dateFormat = DateFormat('MMM d, yyyy');

    return Card(
      margin: const EdgeInsets.only(bottom: 12.0),
      child: InkWell(
        onTap: () {
          context.push(
            '${AppRoute.liens}/detail',
            extra: {'lien': lien, 'facilityId': _selectedFacilityId},
          );
        },
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Row(
            children: [
              Container(
                width: 4,
                height: 60,
                decoration: BoxDecoration(
                  color: stageColor,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Lien #${lien.id.substring(0, 8)}',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: stageColor.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            lien.stageDisplayName,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: stageColor,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Tenant: ${lien.tenantId.substring(0, 8)}...',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    if (lien.lienFiledDate != null)
                      Text(
                        'Filed: ${dateFormat.format(lien.lienFiledDate!)}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    lien.formattedTotal,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  if (lien.lienNumber != null)
                    Text(
                      'Lien #${lien.lienNumber}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 8),
              Icon(Icons.chevron_right, color: AppTheme.textTertiary),
            ],
          ),
        ),
      ),
    );
  }

  Color _getStageColor(LienStage stage) {
    switch (stage) {
      case LienStage.notStarted:
        return AppTheme.textSecondary;
      case LienStage.noticeSent:
        return AppTheme.warning;
      case LienStage.lienFiled:
        return AppTheme.info;
      case LienStage.auctionScheduled:
        return AppTheme.error;
      case LienStage.auctionComplete:
        return AppTheme.textSecondary;
      case LienStage.resolved:
        return AppTheme.success;
      case LienStage.cancelled:
        return AppTheme.textSecondary;
    }
  }

  void _showFiltersDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Filter Liens'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              DropdownButtonFormField<LienStage?>(
                value: _stageFilter,
                decoration: const InputDecoration(labelText: 'Stage'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All Stages')),
                  ...LienStage.values.map((stage) => DropdownMenuItem(
                    value: stage,
                    child: Text(_getStageLabel(stage)),
                  )),
                ],
                onChanged: (value) => setState(() => _stageFilter = value),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<LienStatus?>(
                value: _statusFilter,
                decoration: const InputDecoration(labelText: 'Status'),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All Statuses')),
                  ...LienStatus.values.map((status) => DropdownMenuItem(
                    value: status,
                    child: Text(status.name.toUpperCase()),
                  )),
                ],
                onChanged: (value) => setState(() => _statusFilter = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                setState(() {
                  _stageFilter = null;
                  _statusFilter = null;
                });
              },
              child: const Text('Clear'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                Navigator.pop(context);
                setState(() {});
              },
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
  }

  String _getStageLabel(LienStage stage) {
    switch (stage) {
      case LienStage.notStarted:
        return 'Not Started';
      case LienStage.noticeSent:
        return 'Notice Sent';
      case LienStage.lienFiled:
        return 'Lien Filed';
      case LienStage.auctionScheduled:
        return 'Auction Scheduled';
      case LienStage.auctionComplete:
        return 'Auction Complete';
      case LienStage.resolved:
        return 'Resolved';
      case LienStage.cancelled:
        return 'Cancelled';
    }
  }
}

