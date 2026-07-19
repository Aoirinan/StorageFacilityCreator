import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import '../models/dnr_model.dart';
import '../models/global_dnr_model.dart';
import '../providers/dnr_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../providers/active_facility_provider.dart';
import '../services/facility_service.dart';
import '../services/dnr_service.dart';
import '../services/dnr_terms_service.dart';
import '../services/tenant_service.dart';
import '../services/facility_creator_account_service.dart';
import '../services/superadmin_service.dart';
import '../screens/subscription_test_screen.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import 'dnr_entry_screen.dart';
import 'client_detail_screen.dart';
import 'global_dnr_entry_screen.dart';
import 'global_dnr_detail_screen.dart';

class DNRListScreen extends ConsumerStatefulWidget {
  final String? facilityId;
  
  const DNRListScreen({super.key, this.facilityId});

  @override
  ConsumerState<DNRListScreen> createState() => _DNRListScreenState();
}

class _DNRListScreenState extends ConsumerState<DNRListScreen> {
  final TextEditingController _searchController = TextEditingController();
  String? _selectedFacilityId;
  bool _showArchived = false;

  @override
  void initState() {
    super.initState();
    _selectedFacilityId = widget.facilityId;
    _runBackfillIfNeeded();
  }
  
  Future<void> _runBackfillIfNeeded() async {
    try {
      await DNRService.runBackfillIfNeeded();
      // Removed SnackBar - user requested no green box
      if (kDebugMode) {
        print('✅ DNR attribution backfill completed silently');
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error running DNR backfill: $e');
      }
      // Only show error if it's a real problem, not just "already done"
      if (mounted && !e.toString().contains('already') && !e.toString().contains('complete')) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backfill error: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    ref.listen(activeFacilityIdProvider, (prev, next) {
      final nextId = next.whenOrNull(data: (d) => d);
      if (mounted) {
        if (nextId == null) {
          if (_selectedFacilityId != null) setState(() => _selectedFacilityId = null);
        } else if (_selectedFacilityId != nextId) {
          setState(() => _selectedFacilityId = nextId);
        }
      }
    });
    return authState.when(
      data: (user) {
        if (user == null) {
          return const Scaffold(
            body: Center(child: Text('Please sign in to view DNR entries')),
          );
        }

        return _buildBodyWithPremiumCheck(context, user.uid);
      },
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => const Scaffold(
        body: Center(child: Text('Error loading user data')),
      ),
    );
  }

  Widget _buildBodyWithPremiumCheck(BuildContext context, String userId) {
    return FutureBuilder(
      future: _checkPremiumAccess(userId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        final hasAccess = snapshot.data ?? false;
        if (!hasAccess) {
          return _buildUpgradePrompt(context);
        }

        // Premium OK — also require one-time DNR terms acceptance (participation),
        // which Firestore rules enforce for all shared DNR reads.
        return FutureBuilder(
          future: DnrTermsService.hasAccepted(),
          builder: (context, termsSnapshot) {
            if (termsSnapshot.connectionState == ConnectionState.waiting) {
              return const Center(child: CircularProgressIndicator());
            }

            final termsAccepted = termsSnapshot.data ?? false;
            if (!termsAccepted) {
              return _buildTermsAcceptancePrompt(context);
            }

            return _buildBody(userId);
          },
        );
      },
    );
  }

  Widget _buildTermsAcceptancePrompt(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.policy_outlined,
              size: 64,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(height: 24),
            const Text(
              'Do Not Rent Terms',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            const Text(
              'The DNR list is shared between participating facilities. Before accessing it, '
              'review and accept the Do Not Rent terms below.',
              style: TextStyle(fontSize: 16, color: AppTheme.textTertiary),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () async {
                final accepted = await DnrTermsService.ensureAccepted(context);
                if (accepted && mounted) {
                  setState(() {});
                }
              },
              icon: const Icon(Icons.check_circle_outline),
              label: const Text('Review & Accept Terms'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.error,
                foregroundColor: AppTheme.textOnDark,
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<bool> _checkPremiumAccess(String userId) async {
    try {
      // Superadmins have full access
      if (SuperAdminService.isSuperAdmin()) {
        if (kDebugMode) {
          print('✅ Superadmin - bypassing premium access check');
        }
        return true;
      }

      final account = await FacilityCreatorAccountService.getAccountByOwnerUid(userId);
      if (account == null) {
        return false;
      }
      return account.hasPremiumAccess;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error checking premium access: $e');
      }
      return false;
    }
  }

  Widget _buildUpgradePrompt(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.lock_outline,
              size: 64,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(height: 24),
            const Text(
              'DNR System - Premium Feature',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            const Text(
              'The Do Not Rent (DNR) system is only available with an active subscription. '
              'Upgrade from your trial to access this feature.',
              style: TextStyle(
                fontSize: 16,
                color: AppTheme.textTertiary,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 32),
            ElevatedButton.icon(
              onPressed: () => context.go(AppRoute.subscription),
              icon: const Icon(Icons.upgrade),
              label: const Text('Upgrade to Premium'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.success,
                foregroundColor: AppTheme.textOnDark,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () {
                Navigator.of(context).pop();
              },
              child: const Text('Go Back'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(String userId) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: _buildFacilitySelector(userId),
        ),
        // Filter chips and Add to Global DNR (when viewing all facilities)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
          child: Row(
            children: [
              FilterChip(
                label: Text(_showArchived ? 'All Entries' : 'Active Only'),
                selected: !_showArchived,
                onSelected: (selected) {
                  setState(() {
                    _showArchived = !selected;
                  });
                },
                selectedColor: AppTheme.error.withOpacity(0.2),
                checkmarkColor: AppTheme.error,
              ),
              const SizedBox(width: 8),
              if (_showArchived)
                FilterChip(
                  label: const Text('Archived Only'),
                  selected: _showArchived,
                  onSelected: (selected) {
                    setState(() {
                      _showArchived = selected;
                    });
                  },
                  selectedColor: AppTheme.borderLight,
                  checkmarkColor: AppTheme.textTertiary,
                ),
              if (_selectedFacilityId == null) ...[
                const Spacer(),
                TextButton.icon(
                  onPressed: _navigateToAddGlobalDNR,
                  icon: const Icon(Icons.add, size: 20),
                  label: const Text('Add to Global DNR'),
                ),
              ],
            ],
          ),
        ),
        
        // Search bar
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16.0),
          child: TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search by name, email, or phone...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: () {
                        _searchController.clear();
                        setState(() {});
                      },
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onChanged: (value) {
              setState(() {});
            },
          ),
        ),
        
        const SizedBox(height: 8),
        
        // DNR entries list
        Expanded(
          child: _buildDNRList(),
        ),
      ],
    );
  }

  Widget _buildFacilitySelector(String userId) {
    final facilitiesAsync = ref.watch(userFacilitiesProvider(userId));

    return facilitiesAsync.when(
      data: (facilities) {
        if (facilities.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.warning.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.warning),
            ),
            child: const Text(
              'No facilities found. Create a facility to manage DNR entries.',
              style: TextStyle(color: AppTheme.textPrimary),
            ),
          );
        }

        // Scope banner only — the facility is switched with the single selector in
        // the top bar (FacilitySwitcher). A second dropdown here previously
        // duplicated it and rendered a broken, overlapping menu.
        String scopeName = 'All Facilities';
        if (_selectedFacilityId != null) {
          for (final facility in facilities) {
            if (facility.id == _selectedFacilityId) {
              scopeName = facility.name;
              break;
            }
          }
        }
        final isGlobalScope = _selectedFacilityId == null;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: AppTheme.primaryBlue.withOpacity(0.06),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.primaryBlue.withOpacity(0.25)),
          ),
          child: Row(
            children: [
              Icon(
                isGlobalScope ? Icons.public : Icons.business,
                size: 20,
                color: AppTheme.primaryBlue,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Viewing: $scopeName',
                      style: const TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                    ),
                    Text(
                      isGlobalScope
                          ? 'Platform-wide shared list. Switch facilities using the selector in the top bar.'
                          : 'This facility\'s own list. Switch to "All Facilities" in the top bar for the shared list.',
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppTheme.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
      loading: () => const SizedBox(
        height: 4,
        child: LinearProgressIndicator(),
      ),
      error: (error, stackTrace) => Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.error.withOpacity(0.1),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.error),
        ),
        child: Text(
          'Error loading facilities: $error',
          style: TextStyle(color: AppTheme.error),
        ),
      ),
    );
  }

  Widget _buildDNRList() {
    if (_searchController.text.isNotEmpty) {
      return _buildSearchResults();
    }
    
    if (_selectedFacilityId != null) {
      return _buildFacilityDNRList();
    }
    
    return _buildGlobalDNRList();
  }

  Widget _buildSearchResults() {
    return Consumer(
      builder: (context, ref, child) {
        final query = _searchController.text.trim();
        if (_selectedFacilityId == null) {
          final searchParams = {
            'query': query,
            'status': _showArchived ? null : 'active',
          };
          final globalSearchAsync = ref.watch(globalDnrSearchProvider(searchParams));
          return globalSearchAsync.when(
            data: (entries) {
              if (entries.isEmpty) {
                return const Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.search_off, size: 64, color: AppTheme.textTertiary),
                      SizedBox(height: 16),
                      Text('No DNR entries found'),
                      SizedBox(height: 8),
                      Text('Try a different search term'),
                    ],
                  ),
                );
              }
              return ListView.builder(
                itemCount: entries.length,
                itemBuilder: (context, index) {
                  return _buildGlobalDNRCard(entries[index]);
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stackTrace) => Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error, size: 64, color: AppTheme.error),
                  const SizedBox(height: 16),
                  Text('Error searching DNR entries: $error'),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () => ref.invalidate(globalDnrSearchProvider(searchParams)),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          );
        }
        final searchParams = {
          'facilityId': _selectedFacilityId ?? '',
          'query': query,
          'active': _showArchived ? null : true,
        };
        final dnrAsync = ref.watch(dnrSearchProvider(searchParams));
        return dnrAsync.when(
          data: (entries) {
            if (entries.isEmpty) {
              return const Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.search_off, size: 64, color: AppTheme.textTertiary),
                    SizedBox(height: 16),
                    Text('No DNR entries found'),
                    SizedBox(height: 8),
                    Text('Try a different search term'),
                  ],
                ),
              );
            }
            return ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) => _buildDNRCard(entries[index]),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error, size: 64, color: AppTheme.error),
                const SizedBox(height: 16),
                Text('Error searching DNR entries: $error'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref.invalidate(dnrSearchProvider(searchParams)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildFacilityDNRList() {
    return Consumer(
      builder: (context, ref, child) {
        final dnrAsync = ref.watch(dnrEntriesForFacilityProvider(_selectedFacilityId!));
        
        return dnrAsync.when(
          data: (entries) {
            // Filter archived entries if needed
            final filteredEntries = _showArchived 
                ? entries 
                : entries.where((entry) => entry.active).toList();
            
            if (filteredEntries.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.person_off, size: 64, color: AppTheme.textTertiary),
                    const SizedBox(height: 16),
                    Text(_showArchived ? 'No archived DNR entries' : 'No DNR entries found'),
                    const SizedBox(height: 8),
                    Text(_showArchived 
                      ? 'All DNR entries are active' 
                      : 'Add a DNR entry to get started'),
                    const SizedBox(height: 16),
                    ElevatedButton(
                      onPressed: _navigateToCreateDNR,
                      child: const Text('Add DNR Entry'),
                    ),
                  ],
                ),
              );
            }
            
            return ListView.builder(
              itemCount: filteredEntries.length,
              itemBuilder: (context, index) {
                final entry = filteredEntries[index];
                return _buildDNRCard(entry);
              },
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error, size: 64, color: AppTheme.error),
                const SizedBox(height: 16),
                Text('Error loading DNR entries: $error'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () {
                    if (_selectedFacilityId != null) {
                      ref.invalidate(dnrEntriesForFacilityProvider(_selectedFacilityId!));
                    }
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildGlobalDNRList() {
    return Consumer(
      builder: (context, ref, child) {
        final status = _showArchived ? null : GlobalDnrStatus.active;
        final dnrAsync = ref.watch(globalDnrEntriesFromGlobalCollectionProvider(status));
        return dnrAsync.when(
          data: (entries) {
            if (entries.isEmpty) {
              return Center(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.person_off, size: 64, color: AppTheme.textTertiary),
                    const SizedBox(height: 16),
                    Text(_showArchived ? 'No archived DNR entries' : 'No DNR entries found'),
                    const SizedBox(height: 8),
                    Text(_showArchived
                        ? 'All DNR entries are active'
                        : 'Add a Global DNR entry to share with every Storage Facility Creator operator'),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _navigateToAddGlobalDNR,
                      icon: const Icon(Icons.add),
                      label: const Text('Add to Global DNR'),
                    ),
                  ],
                ),
              );
            }
            return ListView.builder(
              itemCount: entries.length,
              itemBuilder: (context, index) => _buildGlobalDNRCard(entries[index]),
            );
          },
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error, size: 64, color: AppTheme.error),
                const SizedBox(height: 16),
                Text('Error loading DNR entries: $error'),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: () => ref.invalidate(globalDnrEntriesFromGlobalCollectionProvider(status)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildGlobalDNRCard(GlobalDNREntryModel entry) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: entry.isActive ? AppTheme.error : AppTheme.borderLight,
          width: entry.isActive ? 2 : 1,
        ),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: entry.isActive ? AppTheme.error : AppTheme.textTertiary,
          child: Icon(Icons.person_off, color: AppTheme.textOnDark),
        ),
        title: Text(
          entry.fullName,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            decoration: entry.isActive ? null : TextDecoration.lineThrough,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.email),
            Text(entry.phone),
            Text(entry.reason, style: const TextStyle(fontStyle: FontStyle.italic)),
            Text(
              entry.createdByFacilityName ?? 'Facility: ${entry.createdByFacilityId}',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            if (entry.createdByState != null && entry.createdByState!.isNotEmpty)
              Text(
                'State: ${entry.createdByState}',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
            Row(
              children: [
                Chip(
                  label: Text(entry.severity.value),
                  backgroundColor: AppTheme.primaryBlue.withOpacity(0.2),
                ),
                const SizedBox(width: 4),
                Chip(
                  label: Text(entry.status.value),
                  backgroundColor: entry.isActive
                      ? AppTheme.success.withOpacity(0.2)
                      : AppTheme.textTertiary.withOpacity(0.2),
                ),
                if (entry.evidenceCount > 0) ...[
                  const SizedBox(width: 4),
                  Chip(
                    label: Text('${entry.evidenceCount} evidence'),
                    backgroundColor: AppTheme.textTertiary.withOpacity(0.2),
                  ),
                ],
              ],
            ),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => _openGlobalDNREntryDetail(entry),
      ),
    );
  }

  void _navigateToAddGlobalDNR() {
    context.push(AppRoute.legacyScreen, extra: const GlobalDNREntryScreen()).then((_) {
      ref.invalidate(globalDnrEntriesFromGlobalCollectionProvider);
      ref.invalidate(globalDnrSearchProvider);
    });
  }

  void _openGlobalDNREntryDetail(GlobalDNREntryModel entry) {
    context.push(AppRoute.legacyScreen, extra: GlobalDNRDetailScreen(entry: entry)).then((_) {
      ref.invalidate(globalDnrEntriesFromGlobalCollectionProvider);
      ref.invalidate(globalDnrSearchProvider);
    });
  }

  Widget _buildDNRCard(DNRModel entry) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: entry.active ? AppTheme.error : AppTheme.borderLight,
          width: entry.active ? 2 : 1,
        ),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: entry.active ? AppTheme.error : AppTheme.textTertiary,
          child: Icon(
            Icons.person_off,
            color: AppTheme.textOnDark,
          ),
        ),
        title: Text(
          entry.name,
          style: TextStyle(
            fontWeight: FontWeight.bold,
            decoration: entry.active ? null : TextDecoration.lineThrough,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(entry.email),
            Text(entry.phone),
            Text(
              entry.reason,
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
            Text(
              entry.facilityName != null
                  ? 'Facility: ${entry.facilityName}'
                  : 'Facility ID: ${entry.facilityId}',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
            if (entry.ownerEmail != null && entry.ownerEmail!.isNotEmpty)
              Text(
                'Facility Email: ${entry.ownerEmail}',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
            if (entry.facilityPhone != null && entry.facilityPhone!.isNotEmpty)
              Text(
                'Facility Phone: ${entry.facilityPhone}',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
            if (entry.addedByName != null && entry.addedByEmail != null)
              Text(
                'Added by: ${entry.addedByName} (${entry.addedByEmail})',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              )
            else
              Text(
                'Added by: Unknown (backfill needed)',
                style: TextStyle(fontSize: 12, color: AppTheme.warning),
              ),
            if (entry.linkedTenantId != null && entry.linkedTenantId!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Icon(Icons.link, size: 16, color: AppTheme.textTertiary),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'Linked tenant: ${entry.linkedTenantName ?? 'View tenant record'}',
                        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                      ),
                    ),
                    TextButton(
                      onPressed: () => _openLinkedTenant(entry),
                      child: const Text('View'),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                Chip(
                  label: Text(entry.active ? 'Active' : 'Inactive'),
                  backgroundColor: entry.active ? AppTheme.success.withOpacity(0.2) : AppTheme.textTertiary.withOpacity(0.2),
                ),
                if (entry.expiresAt != null)
                  Chip(
                    label: Text('Expires: ${entry.expiresAt!.day}/${entry.expiresAt!.month}/${entry.expiresAt!.year}'),
                    backgroundColor: AppTheme.primaryBlue.withOpacity(0.2),
                  ),
              ],
            ),
          ],
        ),
        trailing: PopupMenuButton(
          itemBuilder: (context) => [
            PopupMenuItem(
              value: 'edit',
              child: const Row(
                children: [
                  Icon(Icons.edit),
                  SizedBox(width: 8),
                  Text('Edit'),
                ],
              ),
            ),
            PopupMenuItem(
              value: entry.active ? 'archive' : 'restore',
              child: Row(
                children: [
                  Icon(entry.active ? Icons.archive : Icons.unarchive),
                  const SizedBox(width: 8),
                  Text(entry.active ? 'Archive' : 'Restore'),
                ],
              ),
            ),
            if (entry.active)
              PopupMenuItem(
                value: 'delete',
                child: const Row(
                  children: [
                    Icon(Icons.delete, color: AppTheme.error),
                    SizedBox(width: 8),
                    Text('Delete', style: TextStyle(color: AppTheme.error)),
                  ],
                ),
              ),
          ],
          onSelected: (value) {
            _handleDNRAction(value, entry);
          },
        ),
        onTap: () {
          _navigateToEditDNR(entry);
        },
      ),
    );
  }


  void _handleDNRAction(String action, DNRModel entry) {
    switch (action) {
      case 'edit':
        _navigateToEditDNR(entry);
        break;
      case 'archive':
        _archiveDNR(entry);
        break;
      case 'restore':
        _restoreDNR(entry);
        break;
      case 'delete':
        _deleteDNR(entry);
        break;
    }
  }

  void _navigateToCreateDNR() {
    if (_selectedFacilityId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select a facility before adding a DNR entry.'),
        ),
      );
      return;
    }

    context.push(
      AppRoute.legacyScreen,
      extra: DNREntryScreen(
        facilityId: _selectedFacilityId,
      ),
    ).then((_) {
      // Refresh providers when returning from DNR creation/editing
      if (_selectedFacilityId != null) {
        ref.invalidate(dnrEntriesForFacilityProvider(_selectedFacilityId!));
      }
      // Invalidate all global DNR entries (family provider)
      ref.invalidate(globalDnrEntriesProvider);
    });
  }

  void _navigateToEditDNR(DNRModel entry) {
    if (_selectedFacilityId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select a facility before editing a DNR entry.'),
        ),
      );
      return;
    }

    context.push(
      AppRoute.legacyScreen,
      extra: DNREntryScreen(
        dnrEntry: entry,
        facilityId: _selectedFacilityId,
      ),
    ).then((_) {
      // Refresh providers when returning from DNR creation/editing
      if (_selectedFacilityId != null) {
        ref.invalidate(dnrEntriesForFacilityProvider(_selectedFacilityId!));
      }
      // Invalidate all global DNR entries (family provider)
      ref.invalidate(globalDnrEntriesProvider);
    });
  }

  Future<void> _openLinkedTenant(DNRModel entry) async {
    final tenantId = entry.linkedTenantId;
    if (tenantId == null || tenantId.isEmpty) return;

    try {
      final tenant = await TenantService.getTenantById(entry.facilityId, tenantId);
      if (!mounted) return;

      if (tenant == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Linked tenant could not be found.')),
        );
        return;
      }

      context.push(AppRoute.tenantDetail, extra: tenant);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error loading tenant: $e')),
      );
    }
  }

  void _archiveDNR(DNRModel entry) {
    if (entry.facilityId == null) return;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Archive DNR Entry'),
        content: Text(
            'Are you sure you want to archive "${entry.name}"? The entry will be deactivated and can be restored later.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                // Archive = deactivate (recoverable); permanent removal is the separate Delete action.
                await DNRService.toggleDNRActive(
                  facilityId: entry.facilityId!,
                  dnrId: entry.id,
                  active: false,
                );
                // Refresh providers after archiving
                ref.invalidate(dnrEntriesForFacilityProvider(entry.facilityId!));
                // Invalidate all global DNR entries (family provider)
      ref.invalidate(globalDnrEntriesProvider);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('DNR entry archived')),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Error archiving DNR entry: $e')),
                );
              }
            },
            child: const Text('Archive'),
          ),
        ],
      ),
    );
  }

  void _restoreDNR(DNRModel entry) {
    if (entry.facilityId == null) return;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore DNR Entry'),
        content: Text('Are you sure you want to restore "${entry.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                final updatedEntry = entry.copyWith(
                  active: true,
                  updatedAt: DateTime.now(),
                );
                await DNRService.updateDNREntry(
                  facilityId: entry.facilityId!,
                  dnrId: entry.id,
                  name: updatedEntry.name,
                  email: updatedEntry.email,
                  phone: updatedEntry.phone,
                  reason: updatedEntry.reason,
                  active: updatedEntry.active,
                  expiresAt: updatedEntry.expiresAt,
                  evidenceUrls: updatedEntry.evidenceUrls,
                );
                // Refresh providers after restoring
                ref.invalidate(dnrEntriesForFacilityProvider(entry.facilityId!));
                // Invalidate all global DNR entries (family provider)
      ref.invalidate(globalDnrEntriesProvider);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('DNR entry restored')),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Error restoring DNR entry: $e')),
                );
              }
            },
            child: const Text('Restore'),
          ),
        ],
      ),
    );
  }

  void _deleteDNR(DNRModel entry) {
    if (entry.facilityId == null) return;
    
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete DNR Entry'),
        content: Text('Are you sure you want to permanently delete "${entry.name}"? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              try {
                await DNRService.deleteDNREntry(
                  facilityId: entry.facilityId!,
                  dnrId: entry.id,
                );
                // Refresh providers after deleting
                ref.invalidate(dnrEntriesForFacilityProvider(entry.facilityId!));
                // Invalidate all global DNR entries (family provider)
      ref.invalidate(globalDnrEntriesProvider);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('DNR entry deleted')),
                );
              } catch (e) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Error deleting DNR entry: $e')),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}