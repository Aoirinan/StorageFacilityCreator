import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/tenant_model.dart';
import '../models/dnr_model.dart';
import '../models/payment_model.dart';
import '../services/dnr_service.dart';
import '../services/audit_service.dart';
import '../services/tenant_service.dart';
import '../services/reminder_service.dart';
import '../services/gate_access_service.dart';
import '../models/reminder_model.dart';
import '../models/gate_access_model.dart';
import '../providers/payment_provider.dart';
import '../providers/tenant_provider.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import '../widgets/keyboard_scrollable.dart';
import 'tenant_edit_screen.dart';
import 'ledger_screen.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' as material;

class ClientDetailScreen extends ConsumerStatefulWidget {
  final TenantModel tenant;

  const ClientDetailScreen({
    super.key,
    required this.tenant,
  });

  @override
  ConsumerState<ClientDetailScreen> createState() => _ClientDetailScreenState();
}

class _ClientDetailScreenState extends ConsumerState<ClientDetailScreen> {
  List<DNRModel>? _dnrMatches;
  bool _isCheckingDNR = false;
  bool _dnrOverride = false;
  GateAccessModel? _gateAccess;
  bool _isLoadingGateAccess = false;

  @override
  void initState() {
    super.initState();
    _checkDNRMatches();
    _loadGateAccess();
  }

  Future<void> _loadGateAccess() async {
    setState(() {
      _isLoadingGateAccess = true;
    });

    try {
      final gateAccess = await GateAccessService.getGateAccessForTenant(
        facilityId: widget.tenant.facilityId,
        tenantId: widget.tenant.id,
      );

      if (mounted) {
        setState(() {
          _gateAccess = gateAccess;
          _isLoadingGateAccess = false;
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error loading gate access: $e');
      }
      if (mounted) {
        setState(() {
          _isLoadingGateAccess = false;
        });
      }
    }
  }

  Future<void> _toggleGateAccess() async {
    if (_gateAccess == null) return;

    final newStatus = !_gateAccess!.isActive;

    try {
      await GateAccessService.updateGateAccess(
        facilityId: widget.tenant.facilityId,
        accessId: _gateAccess!.id,
        isActive: newStatus,
      );

      // Reload gate access
      await _loadGateAccess();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              newStatus ? 'Gate access enabled' : 'Gate access disabled',
            ),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error updating gate access: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _checkDNRMatches() async {
    if (_dnrOverride) return; // Skip if already overridden
    
    setState(() {
      _isCheckingDNR = true;
    });

    try {
      final matches = await DNRService.findDNRMatches(
        facilityId: widget.tenant.facilityId,
        name: widget.tenant.name,
        email: widget.tenant.email,
        phone: widget.tenant.phone,
      );

      if (mounted) {
        setState(() {
          _dnrMatches = matches;
          _isCheckingDNR = false;
        });

        // Show blocking dialog if matches found
        if (matches.isNotEmpty) {
          _showDNRBlockingDialog(context, matches);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('Error checking DNR matches: $e');
      }
      if (mounted) {
        setState(() {
          _isCheckingDNR = false;
        });
      }
    }
  }

  void _showDNRBlockingDialog(BuildContext context, List<DNRModel> matches) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Row(
            children: [
              Icon(Icons.warning, color: AppTheme.error),
              const SizedBox(width: 8),
              const Text('DNR Alert'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'This tenant matches ${matches.length} active DNR entr${matches.length == 1 ? 'y' : 'ies'}:',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              ...matches.map((match) => Card(
                color: AppTheme.error.withOpacity(0.1),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Name: ${match.name}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      if (match.email.isNotEmpty)
                        Text('Email: ${match.email}'),
                      if (match.phone.isNotEmpty)
                        Text('Phone: ${match.phone}'),
                      Text('Reason: ${match.reason}'),
                      if (match.addedByName != null && match.addedByEmail != null)
                        Text(
                          'Added by: ${match.addedByName} (${match.addedByEmail})',
                          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                        ),
                      if (match.facilityName != null)
                        Text(
                          'Facility: ${match.facilityName}',
                          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                        ),
                      if (match.expiresAt != null)
                        Text('Expires: ${match.expiresAt!.toLocal().toString().split(' ')[0]}'),
                    ],
                  ),
                ),
              )),
              const SizedBox(height: 16),
              const Text(
                'Do you want to override and continue?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.of(context).pop(); // Close dialog
                Navigator.of(context).pop(); // Go back to tenant list
              },
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                setState(() {
                  _dnrOverride = true;
                });
                Navigator.of(context).pop(); // Close dialog
                _logDNROverride(matches);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.error,
                foregroundColor: AppTheme.textOnDark,
              ),
              child: const Text('Override & Continue'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _logDNROverride(List<DNRModel> matches) async {
    try {
      // Log the override action for audit purposes
      await AuditService.logDNRAction(
        facilityId: widget.tenant.facilityId,
        action: 'dnr.override',
        targetId: widget.tenant.id,
        details: {
          'tenantName': widget.tenant.name,
          'tenantEmail': widget.tenant.email,
          'matchedDnrIds': matches.map((m) => m.id).toList(),
          'matchedDnrNames': matches.map((m) => m.name).toList(),
        },
      );

      if (kDebugMode) {
        print('✅ DNR override logged for tenant: ${widget.tenant.name}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error logging DNR override: $e');
      }
      // Don't rethrow - logging is non-critical
    }
  }

  String _formatDateTime(DateTime? date) {
    if (date == null) return 'Not specified';
    final month = date.month.toString().padLeft(2, '0');
    final day = date.day.toString().padLeft(2, '0');
    final year = date.year;
    final hour = date.hour % 12 == 0 ? 12 : date.hour % 12;
    final minute = date.minute.toString().padLeft(2, '0');
    final period = date.hour >= 12 ? 'PM' : 'AM';
    return '$month/$day/$year $hour:$minute $period';
  }

  String _formatDate(DateTime? date) {
    if (date == null) return 'Not specified';
    return '${date.month}/${date.day}/${date.year}';
  }

  String _displayIdType(String? type) {
    switch (type) {
      case 'drivers_license':
        return 'Driver\'s License';
      case 'state_id':
        return 'State ID';
      case 'passport':
        return 'Passport';
      case 'military_id':
        return 'Military ID';
      case 'other':
        return 'Other';
      default:
        return 'Not specified';
    }
  }

  @override
  Widget build(BuildContext context) {
    final tenantsAsync = ref.watch(facilityTenantsProvider(widget.tenant.facilityId));
    final tenant = tenantsAsync.maybeWhen(
      data: (tenants) {
        try {
          return tenants.firstWhere((t) => t.id == widget.tenant.id);
        } catch (_) {
          return widget.tenant;
        }
      },
      orElse: () => widget.tenant,
    );

    return ModernPageWrapper(
      currentRoute: '/tenants',
      title: tenant.name,
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        // Quick multi-channel message
        IconButton(
          onPressed: () => _showQuickMessageSheet(tenant),
          icon: const Icon(Icons.flash_on),
          tooltip: 'Quick message (SMS / Email)',
        ),
        IconButton(
          onPressed: () {
            context.push(
              AppRoute.legacyScreen,
              extra: TenantEditScreen(
                  tenant: tenant,
                  facilityIdOverride: tenant.facilityId.isNotEmpty ? tenant.facilityId : widget.tenant.facilityId,
              ),
            );
          },
          icon: const Icon(Icons.edit),
          tooltip: 'Edit Tenant',
        ),
        PopupMenuButton<String>(
          onSelected: (value) {
            switch (value) {
              case 'mark_paid':
                _showMarkPaidDialog(context, tenant);
                break;
              case 'mark_late':
                _showMarkLateDialog(context, tenant);
                break;
              case 'archive':
                _showArchiveDialog(context, tenant);
                break;
              case 'delete':
                _showDeleteDialog(context, tenant);
                break;
            }
          },
          itemBuilder: (context) => [
            if (tenant.isLate)
              const PopupMenuItem(
                value: 'mark_paid',
                child: Row(
                  children: [
                    Icon(Icons.payment, color: AppTheme.success),
                    SizedBox(width: 8),
                    Text('Mark Paid'),
                  ],
                ),
              ),
            if (!tenant.isLate)
              const PopupMenuItem(
                value: 'mark_late',
                child: Row(
                  children: [
                    Icon(Icons.warning, color: AppTheme.warning),
                    SizedBox(width: 8),
                    Text('Mark as Late'),
                  ],
                ),
              ),
            const PopupMenuItem(
              value: 'archive',
              child: Row(
                children: [
                  Icon(Icons.archive),
                  SizedBox(width: 8),
                  Text('Archive'),
                ],
              ),
            ),
            const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete, color: AppTheme.error),
                  SizedBox(width: 8),
                  Text('Delete', style: TextStyle(color: AppTheme.error)),
                ],
              ),
            ),
          ],
        ),
      ],
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_dnrMatches != null && _dnrMatches!.isNotEmpty && !_dnrOverride)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withOpacity(0.1),
                    border: Border.all(color: AppTheme.error),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.warning, color: AppTheme.error),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'DNR ALERT: ${_dnrMatches!.length} Active DNR Matches Found',
                              style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: AppTheme.error,
                                fontSize: 16,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'This tenant matches active Do Not Rent entries. Review carefully before proceeding.',
                              style: TextStyle(color: AppTheme.error),
                            ),
                            if (_dnrMatches!.isNotEmpty && _dnrMatches!.first.addedByName != null && _dnrMatches!.first.addedByEmail != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  'DNR entries added by: ${_dnrMatches!.first.addedByName} (${_dnrMatches!.first.addedByEmail})',
                                  style: TextStyle(fontSize: 12, color: AppTheme.error),
                                ),
                              ),
                            if (_dnrMatches!.isNotEmpty && _dnrMatches!.first.facilityName != null)
                              Text(
                                'Facility: ${_dnrMatches!.first.facilityName}',
                                style: TextStyle(fontSize: 12, color: AppTheme.error),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              if (_dnrOverride)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.warning.withOpacity(0.1),
                    border: Border.all(color: AppTheme.warning),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.check_circle, color: AppTheme.warning),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'DNR Override Active: Proceeding with caution',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: AppTheme.warning,
                            fontSize: 16,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      CircleAvatar(
                        radius: 30,
                        backgroundColor: tenant.isActive ? AppTheme.success : AppTheme.textTertiary,
                        child: Text(
                          tenant.name.isNotEmpty ? tenant.name[0].toUpperCase() : '?',
                          style: const TextStyle(
                            color: AppTheme.textOnDark,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              tenant.name,
                              style: const TextStyle(
                                fontSize: 24,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Unit ${tenant.unitNumber}',
                              style: TextStyle(
                                fontSize: 16,
                                color: AppTheme.textSecondary,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: tenant.isActive ? AppTheme.success.withOpacity(0.1) : AppTheme.backgroundLight,
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Text(
                                tenant.isActive ? 'Active' : 'Inactive',
                                style: TextStyle(
                                  color: tenant.isActive ? AppTheme.success : AppTheme.textTertiary,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(context, Icons.contact_mail_outlined, 'Contact Information'),
                      _buildInfoItem(context,
                          icon: Icons.email_outlined, label: 'Email', value: _valueOrPlaceholder(tenant.email)),
                      _buildInfoItem(context,
                          icon: Icons.phone_outlined, label: 'Phone', value: _valueOrPlaceholder(tenant.phone)),
                      _buildInfoItem(context,
                          icon: Icons.home_work_outlined,
                          label: 'Unit Assignment',
                          value: _valueOrPlaceholder(tenant.unitNumber, fallback: 'No unit assigned')),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(context, Icons.badge_outlined, 'Identification'),
                      _buildInfoItem(context,
                          icon: Icons.assignment_ind_outlined,
                          label: 'ID Type',
                          value: _displayIdType(tenant.governmentIdType)),
                      _buildInfoItem(
                        context,
                        icon: Icons.confirmation_number_outlined,
                        label: 'ID Number',
                        value: _valueOrPlaceholder(tenant.governmentIdNumber),
                      ),
                      _buildInfoItem(
                        context,
                        icon: Icons.flag_outlined,
                        label: 'Issuing State',
                        value: _valueOrPlaceholder(tenant.governmentIdState),
                      ),
                      _buildInfoItem(
                        context,
                        icon: Icons.public_outlined,
                        label: 'Issuing Country',
                        value: _valueOrPlaceholder(tenant.governmentIdCountry),
                      ),
                      _buildInfoItem(
                        context,
                        icon: Icons.calendar_month_outlined,
                        label: 'Issued',
                        value: _formatDate(tenant.governmentIdIssuedAt),
                      ),
                      _buildInfoItem(
                        context,
                        icon: Icons.event_outlined,
                        label: 'Expires',
                        value: _formatDate(tenant.governmentIdExpiresAt),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(context, Icons.group_outlined, 'Emergency Contacts'),
                      if (tenant.emergencyContacts.isEmpty)
                        _buildPlaceholder(context, 'No emergency contacts on file.')
                      else
                        ...tenant.emergencyContacts.map(
                          (contact) {
                            final details = <String>[];
                            if (contact.relationship?.isNotEmpty == true) {
                              details.add(contact.relationship!);
                            }
                            if (contact.phone?.isNotEmpty == true) {
                              details.add(contact.phone!);
                            }
                            if (contact.email?.isNotEmpty == true) {
                              details.add(contact.email!);
                            }
                            if (contact.isPrimary) {
                              details.add('Primary');
                            }
                            if (contact.isEmergency) {
                              details.add('Emergency Ready');
                            }
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: Icon(
                                contact.isEmergency ? Icons.warning_amber_outlined : Icons.contact_page_outlined,
                                color: contact.isEmergency ? AppTheme.error : AppTheme.textSecondary,
                              ),
                              title: Text(contact.name),
                              subtitle: Text(details.isNotEmpty ? details.join(' • ') : 'No additional details'),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(context, Icons.directions_car_filled_outlined, 'Vehicles'),
                      if (tenant.vehicles.isEmpty)
                        _buildPlaceholder(context, 'No vehicles registered.')
                      else
                        ...tenant.vehicles.map(
                          (vehicle) {
                            final details = <String>[];
                            if (vehicle.licensePlate?.isNotEmpty == true) {
                              details.add('Plate: ${vehicle.licensePlate}');
                            }
                            if (vehicle.state?.isNotEmpty == true) {
                              details.add('State: ${vehicle.state}');
                            }
                            if (vehicle.color?.isNotEmpty == true) {
                              details.add(vehicle.color!);
                            }
                            if (vehicle.notes?.isNotEmpty == true) {
                              details.add(vehicle.notes!);
                            }
                            return ListTile(
                              contentPadding: EdgeInsets.zero,
                              leading: const Icon(Icons.directions_car),
                              title: Text(
                                [vehicle.make, vehicle.model]
                                    .where((value) => value.trim().isNotEmpty)
                                    .join(' ')
                                    .trim()
                                    .isNotEmpty
                                    ? '${vehicle.make} ${vehicle.model}'.trim()
                                    : 'Vehicle',
                              ),
                              subtitle: Text(details.isNotEmpty ? details.join(' • ') : 'No additional details'),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(context, Icons.lock_outline, 'Tenant Portal'),
                      _buildInfoItem(
                        context,
                        icon: Icons.toggle_on_outlined,
                        label: 'Portal Access',
                        value: tenant.portalEnabled ? 'Enabled' : 'Disabled',
                      ),
                      _buildInfoItem(
                        context,
                        icon: Icons.key_outlined,
                        label: 'Access Code',
                        value: tenant.portalEnabled
                            ? _valueOrPlaceholder(tenant.portalAccessCode, fallback: 'Not set')
                            : 'Not applicable',
                      ),
                      _buildInfoItem(
                        context,
                        icon: Icons.message_outlined,
                        label: 'Welcome Message',
                        value: tenant.portalEnabled
                            ? _valueOrPlaceholder(tenant.portalWelcomeMessage)
                            : 'Not applicable',
                      ),
                      _buildInfoItem(
                        context,
                        icon: Icons.history,
                        label: 'Last Accessed',
                        value: tenant.portalEnabled ? _formatDateTime(tenant.portalLastAccessAt) : 'Not applicable',
                      ),
                      if (tenant.portalEnabled)
                        _buildInfoItem(
                          context,
                          icon: Icons.bar_chart_outlined,
                          label: 'Portal Visits',
                          value: tenant.portalVisitCount.toString(),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(context, Icons.info_outline, 'Account Status'),
                      _buildInfoItem(
                        context,
                        icon: Icons.warning_amber_outlined,
                        label: 'DNR Flag',
                        value: tenant.isOnDNR ? 'On Do Not Rent list' : 'Cleared',
                      ),
                      _buildInfoItem(
                        context,
                        icon: Icons.person_outline,
                        label: 'Active Status',
                        value: tenant.isActive ? 'Active' : 'Inactive',
                      ),
                      _buildInfoItem(
                        context,
                        icon: Icons.calendar_today_outlined,
                        label: 'Created At',
                        value: _formatDateTime(tenant.createdAt),
                      ),
                      _buildInfoItem(
                        context,
                        icon: Icons.update,
                        label: 'Updated At',
                        value: _formatDateTime(tenant.updatedAt),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildSectionHeader(context, Icons.attach_money_outlined, 'Financial Summary'),
                      _buildInfoItem(
                        context,
                        icon: Icons.attach_money,
                        label: 'Monthly Rate',
                        value: _formatCurrency(tenant.monthlyRate),
                      ),
                      _buildInfoItem(
                        context,
                        icon: Icons.calendar_today_outlined,
                        label: 'Paid Through',
                        value: tenant.paidThrough != null
                            ? '${tenant.paidThrough!.month}/${tenant.paidThrough!.year}'
                            : 'Not paid',
                      ),
                      _buildInfoItem(
                        context,
                        icon: Icons.warning_amber,
                        label: 'Payment Status',
                        value: tenant.isLate ? 'Late' : 'Current',
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: () {
                            context.push(
                              '/tenants/${tenant.id}/ledger',
                              extra: tenant,
                            );
                          },
                          icon: const Icon(Icons.receipt_long),
                          label: const Text('View Ledger'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryBlue,
                            foregroundColor: AppTheme.textOnDark,
                            padding: const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Gate Access Section
              const SizedBox(height: 16),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.lock_outline, color: AppTheme.textTertiary),
                          const SizedBox(width: 8),
                          Text(
                            'Gate Access',
                            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const Spacer(),
                          if (_isLoadingGateAccess)
                            const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      if (_gateAccess != null) ...[
                        _buildInfoItem(
                          context,
                          icon: Icons.key,
                          label: 'Access Code',
                          value: _gateAccess!.accessCode,
                        ),
                        _buildInfoItem(
                          context,
                          icon: _gateAccess!.isActive ? Icons.check_circle : Icons.cancel,
                          label: 'Status',
                          value: _gateAccess!.isActive ? 'Enabled' : 'Disabled',
                          valueColor: _gateAccess!.isActive ? AppTheme.success : AppTheme.error,
                        ),
                        if (_gateAccess!.createdAt != null)
                          _buildInfoItem(
                            context,
                            icon: Icons.calendar_today_outlined,
                            label: 'Created',
                            value: _formatDateTime(_gateAccess!.createdAt),
                          ),
                        if (_gateAccess!.updatedAt != null)
                          _buildInfoItem(
                            context,
                            icon: Icons.update,
                            label: 'Last Updated',
                            value: _formatDateTime(_gateAccess!.updatedAt),
                          ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: _toggleGateAccess,
                            icon: Icon(_gateAccess!.isActive ? Icons.block : Icons.check),
                            label: Text(_gateAccess!.isActive ? 'Disable Access' : 'Enable Access'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _gateAccess!.isActive ? AppTheme.error : AppTheme.success,
                              foregroundColor: AppTheme.textOnDark,
                              padding: const EdgeInsets.symmetric(vertical: 12),
                            ),
                          ),
                        ),
                      ] else ...[
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            'No gate access code assigned',
                            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              if (tenant.notes != null && tenant.notes!.isNotEmpty) ...[
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSectionHeader(context, Icons.notes_outlined, 'Notes'),
                        const SizedBox(height: 8),
                        Text(tenant.notes ?? ''),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              Row(
                children: [
                  Expanded(
                    child: ElevatedButton.icon(
                      onPressed: () {
                      context.push(
                        AppRoute.legacyScreen,
                        extra: TenantEditScreen(
                              tenant: tenant,
                              facilityIdOverride: tenant.facilityId.isNotEmpty
                                  ? tenant.facilityId
                                  : widget.tenant.facilityId,
                          ),
                        );
                      },
                      icon: const Icon(Icons.edit),
                      label: const Text('Edit Tenant'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlue,
                        foregroundColor: AppTheme.textOnDark,
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('Back to List'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 12),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
    );
  }

  static void _showArchiveDialog(BuildContext context, TenantModel tenant) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Archive Tenant'),
        content: Text('Are you sure you want to archive ${tenant.name}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              
              try {
                await TenantService.archiveTenant(
                  facilityId: tenant.facilityId,
                  tenantId: tenant.id!,
                );
                
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Tenant archived successfully'),
                      backgroundColor: AppTheme.success,
                    ),
                  );
                  // Navigate back to avoid showing archived tenant
                  Navigator.of(context).pop();
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error archiving tenant: $e'),
                      backgroundColor: AppTheme.error,
                    ),
                  );
                }
              }
            },
            child: const Text('Archive'),
          ),
        ],
      ),
    );
  }

  static void _showDeleteDialog(BuildContext context, TenantModel tenant) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Tenant'),
        content: Text('Are you sure you want to permanently delete ${tenant.name}? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              
              try {
                await TenantService.deleteTenant(
                  facilityId: tenant.facilityId,
                  tenantId: tenant.id!,
                );
                
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Tenant deleted successfully'),
                      backgroundColor: AppTheme.success,
                    ),
                  );
                  // Navigate back since tenant no longer exists
                  Navigator.of(context).pop();
                }
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text('Error deleting tenant: $e'),
                      backgroundColor: AppTheme.error,
                    ),
                  );
                }
              }
            },
            child: Text('Delete', style: TextStyle(color: AppTheme.error)),
          ),
        ],
      ),
    );
  }

  void _showMarkPaidDialog(BuildContext context, TenantModel tenant) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark Payment as Paid'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Mark ${tenant.name} as paid through the end of this month?'),
            const SizedBox(height: 16),
            const Text(
              'This will:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Text('• Create a payment record'),
            const Text('• Update paidThrough date'),
            const Text('• Clear the late status'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await _markTenantAsPaid(context, tenant);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.success,
              foregroundColor: AppTheme.textOnDark,
            ),
            child: const Text('Mark Paid'),
          ),
        ],
      ),
    );
  }

  Future<void> _markTenantAsPaid(BuildContext context, TenantModel tenant) async {
    try {
      // Use the PaymentService to mark tenant as paid
      await ref.read(paymentOperationsProvider.notifier).markTenantAsPaid(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        amount: tenant.monthlyRate,
        method: PaymentMethod.cash,
        notes: 'Marked as paid manually',
      );

      // Invalidate providers to refresh UI immediately
      ref.invalidate(facilityTenantsProvider(tenant.facilityId));
      ref.invalidate(paymentListProvider(tenant.facilityId));
      ref.invalidate(paymentStatsProvider(tenant.facilityId));

      // Calculate end of month for display
      final now = DateTime.now();
      final endOfMonth = DateTime(now.year, now.month + 1, 0);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${tenant.name} marked as paid through ${endOfMonth.month}/${endOfMonth.year}'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error marking payment: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  void _showMarkLateDialog(BuildContext context, TenantModel tenant) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Mark Tenant as Late'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Mark ${tenant.name} as late?'),
            const SizedBox(height: 16),
            const Text(
              'This will:',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
            const Text('• Clear the paidThrough date'),
            const Text('• Mark tenant as late on payments'),
            const Text('• Tenant will appear in late payment reports'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await _markTenantAsLate(context, tenant);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.warning,
              foregroundColor: AppTheme.textOnDark,
            ),
            child: const Text('Mark as Late'),
          ),
        ],
      ),
    );
  }

  Future<void> _markTenantAsLate(BuildContext context, TenantModel tenant) async {
    try {
      await TenantService.markTenantAsLate(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        paidThroughDate: null, // Set to null to make tenant late
      );

      // Invalidate providers to refresh UI immediately
      ref.invalidate(facilityTenantsProvider(tenant.facilityId));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${tenant.name} marked as late'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error marking tenant as late: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _sendQuickReminder(TenantModel tenant) async {
    try {
      if (tenant.email == null || tenant.email!.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Tenant has no email address on file'),
              backgroundColor: AppTheme.warning,
            ),
          );
        }
        return;
      }

      // Create a reminder
      final reminder = await ReminderService.createReminder(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        type: ReminderType.custom,
        title: 'Payment Reminder',
        message: 'This is a reminder about your storage unit. Please contact us if you have any questions.',
        scheduledFor: DateTime.now(),
        channels: [ReminderChannel.email],
        tenantEmail: tenant.email,
        tenantPhone: tenant.phone,
      );

      // Send reminder immediately
      final sent = await ReminderService.sendReminder(
        facilityId: tenant.facilityId,
        reminderId: reminder.id,
        tenantEmail: tenant.email ?? '',
        tenantPhone: tenant.phone ?? '',
        message: 'This is a reminder about your storage unit. Please contact us if you have any questions.',
        channels: [ReminderChannel.email],
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(sent ? 'Reminder email sent successfully' : 'Failed to send reminder email'),
            backgroundColor: sent ? AppTheme.success : AppTheme.error,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error sending reminder: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  void _showQuickMessageSheet(TenantModel tenant) {
    final smsAvailable = tenant.phone.isNotEmpty;
    final emailAvailable = tenant.email.isNotEmpty;
    bool sendSMS = smsAvailable;
    bool sendEmail = emailAvailable && !smsAvailable; // default: pick one channel
    final messageController = TextEditingController(text: 'This is a quick message regarding your unit.');

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(ctx).viewInsets.bottom + 16,
            left: 16,
            right: 16,
            top: 16,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.flash_on),
                  const SizedBox(width: 8),
                  Text(
                    'Quick Message',
                    style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              material.SwitchListTile.adaptive(
                value: sendSMS,
                onChanged: smsAvailable
                        ? (v) => setModalState(() {
                          sendSMS = v;
                        })
                    : null,
                title: const Text('Send SMS'),
                subtitle: Text(smsAvailable ? 'To ${tenant.phone}' : 'No phone on file'),
              ),
              material.SwitchListTile.adaptive(
                value: sendEmail,
                onChanged: emailAvailable
                        ? (v) => setModalState(() {
                          sendEmail = v;
                        })
                    : null,
                title: const Text('Send Email'),
                subtitle: Text(emailAvailable ? 'To ${tenant.email}' : 'No email on file'),
              ),
              const SizedBox(height: 8),
              TextField(
                controller: messageController,
                maxLines: 3,
                decoration: const InputDecoration(
                  labelText: 'Message',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: (!sendSMS && !sendEmail)
                        ? null
                        : () async {
                            Navigator.of(ctx).pop();
                            await _sendQuickMessage(tenant, messageController.text.trim(), sendSMS, sendEmail);
                          },
                    icon: const Icon(Icons.send),
                    label: const Text('Send'),
                  ),
                ],
              ),
            ],
          ),
            );
          },
        );
      },
    );
  }

  Future<void> _sendQuickMessage(
    TenantModel tenant,
    String message,
    bool sendSMS,
    bool sendEmail,
  ) async {
    if (message.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Please enter a message'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }

    // Show loading
    ScaffoldMessengerState? messenger;
    if (mounted) {
      messenger = ScaffoldMessenger.of(context);
      messenger.showSnackBar(
        const SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.textOnDark),
              ),
              SizedBox(width: 16),
              Text('Sending message...'),
            ],
          ),
          duration: Duration(seconds: 30),
        ),
      );
    }

    final channels = <ReminderChannel>[];
    if (sendSMS && tenant.phone.isNotEmpty) channels.add(ReminderChannel.sms);
    if (sendEmail && tenant.email.isNotEmpty) channels.add(ReminderChannel.email);

    if (channels.isEmpty) {
      if (mounted && messenger != null) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('No valid contact method selected'),
            backgroundColor: AppTheme.warning,
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }

    try {
      final reminder = await ReminderService.createReminder(
        facilityId: tenant.facilityId,
        tenantId: tenant.id,
        type: ReminderType.custom,
        title: 'Quick Message',
        message: message,
        scheduledFor: DateTime.now(),
        channels: channels,
        tenantEmail: tenant.email,
        tenantPhone: tenant.phone,
      );

      final sent = await ReminderService.sendReminder(
        facilityId: tenant.facilityId,
        reminderId: reminder.id,
        tenantEmail: tenant.email ?? '',
        tenantPhone: tenant.phone ?? '',
        message: message,
        channels: channels,
      );

      if (mounted && messenger != null) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text(sent ? 'Message sent successfully' : 'Failed to send message'),
            backgroundColor: sent ? AppTheme.success : AppTheme.error,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted && messenger != null) {
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text('Error sending message: ${e.toString()}'),
            backgroundColor: AppTheme.error,
            duration: const Duration(seconds: 5),
          ),
        );
      }
      if (kDebugMode) {
        print('❌ Error sending quick message: $e');
      }
    }
  }

  Widget _buildSectionHeader(BuildContext context, IconData icon, String title) {
    final color = Theme.of(context).colorScheme.primary;
    return Row(
      children: [
        Icon(icon, color: color),
        const SizedBox(width: 12),
        Text(
          title,
          style: Theme.of(context)
              .textTheme
              .titleMedium
              ?.copyWith(fontWeight: FontWeight.bold, color: color),
        ),
      ],
    );
  }

  Widget _buildInfoItem(BuildContext context,
      {required IconData icon, required String label, required String value, Color? valueColor}) {
    final textTheme = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 20, color: AppTheme.textSecondary),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: textTheme.bodyMedium?.copyWith(
                    color: valueColor ?? AppTheme.textTertiary,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlaceholder(BuildContext context, String message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Text(
        message,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
      ),
    );
  }

  String _valueOrPlaceholder(String? value, {String fallback = 'Not provided'}) {
    if (value == null || value.trim().isEmpty) {
      return fallback;
    }
    return value.trim();
  }

  String _formatCurrency(double amount) {
    return '\$${amount.toStringAsFixed(2)}';
  }
}
