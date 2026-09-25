import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:sfcapp/models/contract_model.dart';
import 'package:sfcapp/models/ledger_entry_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/providers/permission_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/services/audit_service.dart';
import 'package:sfcapp/services/contract_service.dart';
import 'package:sfcapp/services/dnr_service.dart';
import 'package:sfcapp/services/ledger_service.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/services/unit_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/widgets/move_out_action.dart';

/// Whether the unit menu offers Remove Lockout. Not only on occupied units:
/// Set Lockout moves the unit to lockout status, and the tenant-archive and
/// delete refusals send the owner here to remove it before unassigning.
@visibleForTesting
bool unitOffersRemoveLockout(UnitModel unit) =>
    (unit.isOccupied && unit.isOverlocked) ||
    unit.status == UnitStatus.lockout ||
    unit.status == UnitStatus.overlocked;

/// The status Remove Lockout leaves: occupied while a tenant holds the unit,
/// available when none does. It always said occupied, and Remove Lockout is
/// now offered on any locked-out unit, so a unit with no tenant was counted
/// as rented.
@visibleForTesting
UnitStatus statusAfterRemovingLockout(UnitModel unit) =>
    (unit.tenantId ?? '').trim().isEmpty
        ? UnitStatus.available
        : UnitStatus.occupied;

/// What the unit screen reads for its tenant and writes for Remove Lockout.
/// A provider so widget tests can open the real menu without Firebase.
class UnitDetailActions {
  const UnitDetailActions();

  Future<UnitModel?> unit(String facilityId, String unitId) =>
      UnitService.getUnit(facilityId, unitId);

  Future<TenantModel?> tenant(String facilityId, String tenantId) =>
      TenantService.getTenantById(facilityId, tenantId);

  /// The tenant's active contracts, for Move out.
  Future<List<ContractModel>> contracts(String facilityId, String tenantId) =>
      ContractService.getContractsForTenant(facilityId, tenantId);

  Future<double> balance(String facilityId, String tenantId) =>
      LedgerService.getLedgerBalance(tenantId: tenantId, facilityId: facilityId);

  Future<void> setStatus(String facilityId, String unitId, UnitStatus status) =>
      UnitService.updateUnit(facilityId: facilityId, unitId: unitId, status: status);
}

final unitDetailActionsProvider =
    Provider<UnitDetailActions>((ref) => const UnitDetailActions());

class UnitDetailScreen extends ConsumerStatefulWidget {
  final String facilityId;
  final String unitId;
  final UnitModel? unit; // Optional pre-loaded unit

  const UnitDetailScreen({
    super.key,
    required this.facilityId,
    required this.unitId,
    this.unit,
  });

  // Factory constructor for backward compatibility
  factory UnitDetailScreen.fromUnit(UnitModel unit) {
    return UnitDetailScreen(
      facilityId: unit.facilityId,
      unitId: unit.id,
      unit: unit,
    );
  }

  @override
  ConsumerState<UnitDetailScreen> createState() => _UnitDetailScreenState();
}

class _UnitDetailScreenState extends ConsumerState<UnitDetailScreen> {
  UnitModel? _unit;
  TenantModel? _tenant;
  bool _isLoading = true;
  String? _errorMessage;
  double? _balance;

  @override
  void initState() {
    super.initState();
    _loadUnit();
  }

  Future<void> _loadUnit() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // The unit passed in serves the first load only. Every later load is
      // a refresh after an action on this page, and kept showing the unit as
      // it was before it (a moved-out unit still occupied).
      if (_unit == null && widget.unit != null) {
        _unit = widget.unit;
      } else {
        final unit = await ref
            .read(unitDetailActionsProvider)
            .unit(widget.facilityId, widget.unitId);
        if (unit == null) {
          setState(() {
            _errorMessage = 'Unit not found';
            _isLoading = false;
          });
          return;
        }
        _unit = unit;
      }

      // Load tenant if unit is occupied
      if (_unit!.tenantId != null && _unit!.tenantId!.isNotEmpty) {
        final actions = ref.read(unitDetailActionsProvider);
        final tenant = await actions.tenant(widget.facilityId, _unit!.tenantId!);
        setState(() {
          _tenant = tenant;
        });

        // Load balance for occupied units
        if (tenant != null) {
          try {
            final balance = await actions.balance(widget.facilityId, tenant.id);
            setState(() {
              _balance = balance;
            });
          } catch (e) {
            if (kDebugMode) {
              print('Error loading balance: $e');
            }
          }
        }
      }

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Error loading unit: $e';
        _isLoading = false;
      });
    }
  }

  PreferredSizeWidget _buildAppBar(BuildContext context, String title, {List<Widget>? actions}) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    return AppBar(
      backgroundColor: cs.surface,
      foregroundColor: cs.onSurface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 1,
      centerTitle: false,
      title: Text(
        title,
        style: theme.textTheme.titleLarge
            ?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.2),
      ),
      actions: actions,
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Divider(height: 1, thickness: 1, color: cs.outlineVariant),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: _buildAppBar(context, 'Loading Unit...'),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_errorMessage != null || _unit == null) {
      return Scaffold(
        appBar: _buildAppBar(context, 'Unit Not Found'),
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                _errorMessage ?? 'Unit not found',
                style: const TextStyle(color: Colors.red),
              ),
              const SizedBox(height: 16),
              ElevatedButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    final canMoveOut =
        ref.watch(canProcessMoveOutAtFacilityProvider(widget.facilityId)).value ?? false;

    return Scaffold(
      appBar: _buildAppBar(
        context,
        'Unit ${_unit!.unitNumber}',
        actions: [
          IconButton(
            onPressed: () => _navigateToEditUnit(context),
            icon: const Icon(Icons.edit),
            tooltip: 'Edit Unit',
          ),
          PopupMenuButton<String>(
            onSelected: (value) => _handleMenuAction(context, value),
            itemBuilder: (context) => [
              const PopupMenuItem(
                value: 'assign_tenant',
                child: ListTile(
                  leading: Icon(Icons.person_add),
                  title: Text('Assign Tenant'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              if (_unit!.isOccupied) ...[
                if (canMoveOut && (_unit!.tenantId ?? '').trim().isNotEmpty)
                  const PopupMenuItem(
                    value: 'move_out',
                    child: ListTile(
                      leading: Icon(Icons.logout),
                      title: Text('Move out'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                const PopupMenuItem(
                  value: 'unassign_tenant',
                  child: ListTile(
                    leading: Icon(Icons.person_remove),
                    title: Text('Unassign Tenant'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'transfer',
                  child: ListTile(
                    leading: Icon(Icons.swap_horiz),
                    title: Text('Transfer Unit'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'apply_fee',
                  child: ListTile(
                    leading: Icon(Icons.add_card),
                    title: Text('Apply Fee'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                if (_balance != null && _balance! > 0)
                  const PopupMenuItem(
                    value: 'set_lockout',
                    child: ListTile(
                      leading: Icon(Icons.lock, color: AppTheme.error),
                      title: Text('Set Lockout'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
              ],
              // Outside the occupied block: Set Lockout moves the unit to
              // lockout status, so Remove Lockout vanished the moment it was
              // needed, and the tenant could not be unassigned either.
              if (unitOffersRemoveLockout(_unit!))
                const PopupMenuItem(
                  value: 'remove_lockout',
                  child: ListTile(
                    leading: Icon(Icons.lock_open, color: Colors.green),
                    title: Text('Remove Lockout'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              if (!_unit!.isOccupied) ...[
                const PopupMenuItem(
                  value: 'reserve_unit',
                  child: ListTile(
                    leading: Icon(Icons.bookmark),
                    title: Text('Reserve Unit'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
              const PopupMenuItem(
                value: 'maintenance',
                child: ListTile(
                  leading: Icon(Icons.build),
                  title: Text('Mark for Maintenance'),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ],
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Status and Basic Info Card
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          'Unit ${_unit!.unitNumber}',
                          style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        _buildStatusChip(_unit!.status),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _unit!.area == null
                          ? _unit!.unitTypeDisplayName
                          : '${_unit!.unitTypeDisplayName} · ${_unit!.area}',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        Expanded(
                          child: _buildInfoItem(
                            'Monthly Rate',
                            _unit!.formattedPrice,
                            Icons.attach_money,
                            AppTheme.success,
                          ),
                        ),
                        if (_unit!.securityDeposit != null)
                          Expanded(
                            child: _buildInfoItem(
                              'Security Deposit',
                              '\$${_unit!.securityDeposit!.toStringAsFixed(2)}',
                              Icons.security,
                              AppTheme.warning,
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),

            // Tenant Information
            if (_unit!.isOccupied && _tenant != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.person, color: AppTheme.textTertiary),
                          const SizedBox(width: 8),
                          Text(
                            'Tenant Information',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          TextButton(
                            onPressed: () {
                              context.push(
                                '${AppRoute.tenantDetail}?tenantId=${_tenant!.id}&facilityId=${widget.facilityId}',
                              );
                            },
                            child: const Text('View Details'),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      _buildDetailRow('Name', _tenant!.name),
                      _buildDetailRow('Email', _tenant!.email),
                      _buildDetailRow('Phone', _tenant!.phone),
                      if (_balance != null) ...[
                        const SizedBox(height: 12),
                        Divider(color: AppTheme.borderLight),
                        const SizedBox(height: 12),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'Account Balance',
                              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              '\$${_balance!.toStringAsFixed(2)}',
                              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                fontWeight: FontWeight.bold,
                                color: _balance! > 0 ? AppTheme.error : AppTheme.success,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Unit Details
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info, color: AppTheme.textTertiary),
                        const SizedBox(width: 8),
                        Text(
                          'Unit Details',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    if (_unit!.description != null) ...[
                      _buildDetailRow('Description', _unit!.description!),
                      const SizedBox(height: 12),
                    ],
                    if (_unit!.dimensions != null) ...[
                      _buildDetailRow('Dimensions', _unit!.dimensionsDisplay),
                      const SizedBox(height: 12),
                    ],
                    if (_unit!.features != null && _unit!.features!.isNotEmpty) ...[
                      _buildDetailRow('Features', _unit!.features!.join(', ')),
                      const SizedBox(height: 12),
                    ],
                    if (_unit!.notes != null) ...[
                      _buildDetailRow('Notes', _unit!.notes!),
                      const SizedBox(height: 12),
                    ],
                    _buildDetailRow('Created', _formatDate(_unit!.createdAt)),
                    if (_unit!.updatedAt != _unit!.createdAt) ...[
                      const SizedBox(height: 12),
                      _buildDetailRow('Last Updated', _formatDate(_unit!.updatedAt)),
                    ],
                    if (_unit!.moveInDate != null) ...[
                      const SizedBox(height: 12),
                      _buildDetailRow('Move-In Date', _formatDate(_unit!.moveInDate!)),
                    ],
                    if (_unit!.moveOutDate != null) ...[
                      const SizedBox(height: 12),
                      _buildDetailRow('Move-Out Date', _formatDate(_unit!.moveOutDate!)),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusChip(UnitStatus status) {
    final color = _getStatusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color, width: 1.5),
      ),
      child: Text(
        _unit!.statusDisplayName,
        style: TextStyle(
          color: color,
          fontWeight: FontWeight.bold,
          fontSize: 12,
        ),
      ),
    );
  }

  Widget _buildInfoItem(String label, String value, IconData icon, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 4),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
          ],
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
    );
  }

  Widget _buildDetailRow(String label, String value) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 120,
          child: Text(
            '$label:',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    );
  }

  Color _getStatusColor(UnitStatus status) {
    switch (status) {
      case UnitStatus.available:
        return AppTheme.success;
      case UnitStatus.occupied:
        return AppTheme.primaryBlue;
      case UnitStatus.reserved:
        return AppTheme.warning;
      case UnitStatus.maintenance:
        return AppTheme.error;
      case UnitStatus.outOfOrder:
        return Colors.grey;
      case UnitStatus.overlocked:
      case UnitStatus.lockout:
        return Colors.red.shade700;
      case UnitStatus.auction:
        return Colors.orange.shade700;
    }
  }

  String _formatDate(DateTime date) {
    return DateFormat('MMM d, y').format(date);
  }

  void _navigateToEditUnit(BuildContext context) {
    if (_unit == null) return;
    context.push(AppRoute.unitEdit, extra: _unit);
  }

  void _handleMenuAction(BuildContext context, String action) {
    switch (action) {
      case 'assign_tenant':
        _showAssignTenantDialog();
        break;
      case 'move_out':
        _moveOut();
        break;
      case 'unassign_tenant':
        _showUnassignTenantDialog();
        break;
      case 'reserve_unit':
        _showReserveUnitDialog();
        break;
      case 'maintenance':
        _showMaintenanceDialog();
        break;
      case 'transfer':
        _handleTransfer();
        break;
      case 'apply_fee':
        _showApplyFeeDialog();
        break;
      case 'set_lockout':
        _setLockout();
        break;
      case 'remove_lockout':
        _removeLockout();
        break;
    }
  }

  void _showAssignTenantDialog() async {
    // Check if unit is already occupied
    if (_unit!.isOccupied) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Unit ${_unit!.unitNumber} is already occupied by ${_unit!.tenantName ?? 'a tenant'}'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }

    // Check if unit is available for assignment
    if (_unit!.status != UnitStatus.available) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Unit ${_unit!.unitNumber} is ${_unit!.statusDisplayName.toLowerCase()} and cannot be assigned'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
      return;
    }

    // Show tenant selection dialog
    final selectedTenant = await showDialog<TenantModel>(
      context: context,
      builder: (context) => Consumer(
        builder: (context, ref, _) {
          final tenantsAsync = ref.watch(activeTenantsProvider(widget.facilityId));
          
          return AlertDialog(
            title: const Text('Assign Tenant to Unit'),
            content: SizedBox(
              width: 400,
              child: tenantsAsync.when(
                data: (tenants) {
                  if (tenants.isEmpty) {
                    return const Padding(
                      padding: EdgeInsets.all(16.0),
                      child: Text('No active tenants available. Please create a tenant first.'),
                    );
                  }
                  
                  return _TenantSelectionDialogContent(
                    facilityId: widget.facilityId,
                    tenants: tenants,
                    unitNumber: _unit!.unitNumber,
                  );
                },
                loading: () => const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24.0),
                    child: CircularProgressIndicator(),
                  ),
                ),
                error: (error, stack) => Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Text('Error loading tenants: $error'),
                ),
              ),
            ),
          );
        },
      ),
    );

    if (selectedTenant != null && mounted) {
      // Check DNR before assignment
      await _checkDNRAndAssignTenant(selectedTenant);
    }
  }

  Future<void> _checkDNRAndAssignTenant(TenantModel tenant) async {
    try {
      // Check for DNR matches
      final dnrMatches = await DNRService.findDNRMatches(
        facilityId: widget.facilityId,
        name: tenant.name,
        email: tenant.email,
        phone: tenant.phone,
      );

      if (dnrMatches.isNotEmpty) {
        if (!mounted) return;
        // Show DNR warning dialog
        final override = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('DNR Match Found'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'This tenant matches ${dnrMatches.length} DNR entr${dnrMatches.length == 1 ? 'y' : 'ies'}. Assigning this tenant may violate facility policy.',
                ),
                const SizedBox(height: 16),
                ...dnrMatches.take(3).map((dnr) => Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: Text(
                    '• ${dnr.name} - ${dnr.reason}',
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                )),
                if (dnrMatches.length > 3)
                  Text('... and ${dnrMatches.length - 3} more'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.warning,
                  foregroundColor: Colors.white,
                ),
                child: const Text('Override & Assign'),
              ),
            ],
          ),
        );

        if (override != true) {
          return; // User cancelled
        }

        // Log override action
        await AuditService.logDNRAction(
          facilityId: widget.facilityId,
          action: 'dnr.override',
          targetId: dnrMatches.first.id,
          details: {
            'unitNumber': _unit!.unitNumber,
            'unitId': widget.unitId,
            'tenantId': tenant.id,
            'tenantName': tenant.name,
            'dnrMatches': dnrMatches.length,
          },
        );
      }

      // Assign tenant to unit
      setState(() => _isLoading = true);
      
      // Adds the unit's rate to the tenant's rent too; the notice says what
      // it is now, or asks the owner to check it.
      final notice = await UnitService.assignTenantToUnit(
        facilityId: widget.facilityId,
        unitId: widget.unitId,
        tenantId: tenant.id,
        tenantName: tenant.name,
        moveInDate: DateTime.now(),
      );

      // Refresh unit data
      await _loadUnit();

      if (mounted) {
        ref.invalidate(facilityTenantsProvider(widget.facilityId));
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${tenant.name} assigned to Unit ${_unit!.unitNumber}'
                '${notice == null ? '' : '. $notice'}'),
            backgroundColor: AppTheme.success,
            duration: Duration(seconds: notice == null ? 4 : 10),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error assigning tenant: ${ErrorMessageHelper.getUserFriendlyMessage(e)}'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  /// Move out: the move-out screen for the tenant's contract, vacating this
  /// unit. A tenant given the unit by Assign Tenant has no contract to move
  /// out from; Unassign Tenant frees it.
  Future<void> _moveOut() async {
    final tenantId = (_unit!.tenantId ?? '').trim();
    if (tenantId.isEmpty) return;
    final tenantName = _tenant?.name ?? _unit!.tenantName ?? 'This tenant';
    List<ContractModel> contracts;
    try {
      contracts = await ref
          .read(unitDetailActionsProvider)
          .contracts(widget.facilityId, tenantId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Couldn't load $tenantName's contracts: "
                '${ErrorMessageHelper.getUserFriendlyMessage(e)}'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
      return;
    }
    if (!mounted) return;
    if (contractsOpenForMoveOut(contracts).isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('$tenantName has no active contract to move out from. '
              'To free the unit without one, use Unassign Tenant.'),
          backgroundColor: AppTheme.warning,
          duration: const Duration(seconds: 8),
        ),
      );
      return;
    }
    final finished = await startMoveOut(
      context,
      facilityId: widget.facilityId,
      contracts: contracts,
      unitId: widget.unitId,
    );
    if (!finished || !mounted) return;
    ref.invalidate(facilityUnitsProvider(widget.facilityId));
    ref.invalidate(facilityTenantsProvider(widget.facilityId));
    unawaited(_loadUnit());
  }

  void _showUnassignTenantDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Unassign Tenant'),
        content: Text('Are you sure you want to unassign the tenant from unit ${_unit!.unitNumber}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error, foregroundColor: Colors.white),
            child: const Text('Unassign'),
          ),
        ],
      ),
    );

    if (confirmed == true && _unit!.tenantId != null) {
      try {
        final notice = await UnitService.removeTenantFromUnit(
          facilityId: widget.facilityId,
          unitId: widget.unitId,
          moveOutDate: DateTime.now(),
        );

        if (mounted) {
          ref.invalidate(facilityUnitsProvider(widget.facilityId));
          ref.invalidate(facilityTenantsProvider(widget.facilityId));
          // The tenant's new rent, or a request to check it.
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(notice == null
                  ? 'Tenant unassigned successfully'
                  : 'Tenant unassigned. $notice'),
              backgroundColor: AppTheme.success,
              duration: Duration(seconds: notice == null ? 4 : 10),
            ),
          );
          unawaited(_loadUnit());
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error unassigning tenant: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  void _showReserveUnitDialog() {
    // Implementation for reserving unit
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Reserve unit feature - to be implemented'),
        ),
      );
    }
  }

  void _showMaintenanceDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark for Maintenance'),
        content: Text('Mark unit ${_unit!.unitNumber} as needing maintenance?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Mark for Maintenance'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await UnitService.updateUnit(
          facilityId: widget.facilityId,
          unitId: widget.unitId,
          status: UnitStatus.maintenance,
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Unit marked for maintenance'),
              backgroundColor: AppTheme.success,
            ),
          );
          unawaited(_loadUnit()); // Refresh
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error updating unit: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  void _handleTransfer() {
    if (_unit!.tenantId != null && _unit!.tenantId!.isNotEmpty) {
      context.push(
        '${AppRoute.transfer}?tenantId=${_unit!.tenantId}&facilityId=${widget.facilityId}',
      );
    }
  }

  void _showApplyFeeDialog() async {
    if (_unit!.tenantId == null || _unit!.tenantId!.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Unit must have a tenant to apply fees'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
      return;
    }

    final feeController = TextEditingController();
    final descriptionController = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Apply Fee'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: feeController,
              decoration: const InputDecoration(
                labelText: 'Fee Amount',
                prefixText: '\$',
              ),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description',
              ),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final amount = double.tryParse(feeController.text);
              if (amount == null || amount <= 0) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Please enter a valid fee amount'),
                    backgroundColor: AppTheme.error,
                  ),
                );
                return;
              }
              Navigator.pop(context, true);
            },
            child: const Text('Apply Fee'),
          ),
        ],
      ),
    );

    if (result == true) {
      try {
        await LedgerService.createLedgerEntry(
          tenantId: _unit!.tenantId!,
          facilityId: widget.facilityId,
          type: LedgerEntryType.otherCharge,
          amount: double.parse(feeController.text),
          description: descriptionController.text.trim().isEmpty
              ? 'Additional fee'
              : descriptionController.text.trim(),
        );

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Fee applied successfully'),
              backgroundColor: AppTheme.success,
            ),
          );
          unawaited(_loadUnit()); // Refresh balance
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error applying fee: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  Future<void> _setLockout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Set Lockout'),
        content: const Text(
          'This will set the unit status to "Lockout" and disable gate access. Continue?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: Colors.white,
            ),
            child: const Text('Set Lockout'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await UnitService.updateUnit(
        facilityId: widget.facilityId,
        unitId: widget.unitId,
        status: UnitStatus.lockout,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Lockout set successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
        unawaited(_loadUnit()); // Refresh
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error setting lockout: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _removeLockout() async {
    try {
      await ref.read(unitDetailActionsProvider).setStatus(
            widget.facilityId,
            widget.unitId,
            statusAfterRemovingLockout(_unit!),
          );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Lockout removed successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
        unawaited(_loadUnit()); // Refresh
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error removing lockout: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }
}

/// Dialog content widget for tenant selection
class _TenantSelectionDialogContent extends StatefulWidget {
  final String facilityId;
  final List<TenantModel> tenants;
  final String unitNumber;

  const _TenantSelectionDialogContent({
    required this.facilityId,
    required this.tenants,
    required this.unitNumber,
  });

  @override
  State<_TenantSelectionDialogContent> createState() => _TenantSelectionDialogContentState();
}

class _TenantSelectionDialogContentState extends State<_TenantSelectionDialogContent> {
  String? _selectedTenantId;
  final _searchController = TextEditingController();
  List<TenantModel> _filteredTenants = [];

  @override
  void initState() {
    super.initState();
    _filteredTenants = widget.tenants;
    _searchController.addListener(_filterTenants);
  }

  @override
  void dispose() {
    _searchController.removeListener(_filterTenants);
    _searchController.dispose();
    super.dispose();
  }

  void _filterTenants() {
    final query = _searchController.text.toLowerCase();
    setState(() {
      if (query.isEmpty) {
        _filteredTenants = widget.tenants;
      } else {
        _filteredTenants = widget.tenants.where((tenant) {
          return tenant.name.toLowerCase().contains(query) ||
              tenant.email.toLowerCase().contains(query) ||
              tenant.phone.contains(query);
        }).toList();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'Select a tenant to assign to Unit ${widget.unitNumber}',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _searchController,
          decoration: const InputDecoration(
            labelText: 'Search tenants',
            prefixIcon: Icon(Icons.search),
            border: OutlineInputBorder(),
          ),
        ),
        const SizedBox(height: 16),
        Flexible(
          child: _filteredTenants.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(16.0),
                  child: Text('No tenants match your search.'),
                )
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: _filteredTenants.length,
                  itemBuilder: (context, index) {
                    final tenant = _filteredTenants[index];
                    final isSelected = _selectedTenantId == tenant.id;
                    
                    return RadioListTile<String>(
                      title: Text(tenant.name),
                      subtitle: Text('${tenant.email} • ${tenant.phone}'),
                      value: tenant.id,
                      groupValue: _selectedTenantId,
                      onChanged: (value) {
                        setState(() {
                          _selectedTenantId = value;
                        });
                      },
                      selected: isSelected,
                    );
                  },
                ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: _selectedTenantId == null
                  ? null
                  : () {
                      final selectedTenant = widget.tenants.firstWhere(
                        (t) => t.id == _selectedTenantId,
                      );
                      Navigator.of(context).pop(selectedTenant);
                    },
              child: const Text('Assign'),
            ),
          ],
        ),
      ],
    );
  }
}

