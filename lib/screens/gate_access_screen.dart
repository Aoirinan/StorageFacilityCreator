import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/gate_access_model.dart';
import '../models/tenant_model.dart';
import '../models/permission_model.dart';
import '../providers/gate_access_provider.dart';
import '../providers/tenant_provider.dart';
import '../services/permission_service.dart';
import '../services/facility_service.dart';
import '../services/gate_access_service.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/modern_navigation_service.dart';

class GateAccessScreen extends ConsumerStatefulWidget {
  final String facilityId;
  final String facilityName;

  const GateAccessScreen({
    super.key,
    required this.facilityId,
    required this.facilityName,
  });

  @override
  ConsumerState<GateAccessScreen> createState() => _GateAccessScreenState();
}

class _GateAccessScreenState extends ConsumerState<GateAccessScreen> {
  String _searchQuery = '';
  bool _loadingPermission = true;
  bool _canManageAccess = false;
  String? _permissionReason;

  @override
  void initState() {
    super.initState();
    _checkPermissions();
  }

  Future<void> _checkPermissions() async {
    setState(() {
      _loadingPermission = true;
    });
    
    // First check if user is facility owner
    try {
      final facility = await FacilityService.getFacility(widget.facilityId);
      final user = FirebaseAuth.instance.currentUser;
      
      if (facility != null && user != null && facility.ownerUid == user.uid) {
        // Facility owner has full access
        if (!mounted) return;
        setState(() {
          _loadingPermission = false;
          _canManageAccess = true;
          _permissionReason = null;
        });
        return;
      }
    } catch (e) {
      // Continue to permission check if facility check fails
    }
    
    // Check role-based permissions
    final check = await PermissionService.hasPermission(
      permission: PermissionType.editUnit,
      facilityId: widget.facilityId,
    );
    if (!mounted) return;
    setState(() {
      _loadingPermission = false;
      _canManageAccess = check.hasPermission;
      _permissionReason = check.reason;
    });
  }

  @override
  Widget build(BuildContext context) {
    final entriesAsync = ref.watch(gateAccessProvider(widget.facilityId));

    if (_loadingPermission) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return entriesAsync.when(
        data: (entries) {
          final filtered = entries.where((entry) {
            if (_searchQuery.isEmpty) return true;
            final query = _searchQuery.toLowerCase();
            return entry.accessCode.toLowerCase().contains(query) ||
                (entry.tenantName ?? '').toLowerCase().contains(query);
          }).toList();

          filtered.sort((a, b) {
            if (a.isActive != b.isActive) {
              return a.isActive ? -1 : 1;
            }
            return a.accessCode.compareTo(b.accessCode);
          });

          return Column(
            children: [
              if (!_canManageAccess)
                MaterialBanner(
                  content: Text(
                    _permissionReason ?? 'You have read-only access to access codes for this facility.',
                  ),
                  backgroundColor: AppTheme.warning.withOpacity(0.1),
                  leading: Icon(Icons.lock_outline, color: AppTheme.warning),
                  actions: const [SizedBox.shrink()],
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'Search access codes or tenants',
                    prefixIcon: Icon(Icons.search),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) => setState(() => _searchQuery = value.trim()),
                ),
              ),
              const SizedBox(height: 12),
              Expanded(
                child: filtered.isEmpty
                    ? _buildEmptyState()
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 0, 16, 100),
                        itemCount: filtered.length,
                        itemBuilder: (context, index) {
                          final entry = filtered[index];
                          return _buildAccessCard(entry);
                        },
                      ),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stackTrace) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, color: AppTheme.error, size: 48),
                const SizedBox(height: 12),
                Text(
                        'Unable to load access code records.',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text(
                  error.toString(),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
        ),
      );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.qr_code_2,
              size: 64,
              color: AppTheme.primaryBlue.withOpacity(0.5),
            ),
            const SizedBox(height: 16),
            Text(
              'No access codes yet',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Generate and manage access codes for your tenants. '
              'Each code can be limited to specific dates and daily time windows.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _canManageAccess ? () => _showEditor() : null,
              icon: const Icon(Icons.add),
              label: const Text('Create Access Code'),
            ),
            if (!_canManageAccess) ...[
              const SizedBox(height: 12),
              Text(
                _permissionReason ?? 'You do not have permission to create access codes.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAccessCard(GateAccessModel entry) {
    final theme = Theme.of(context);
    final validity = _validitySummary(entry);

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: entry.isActive ? AppTheme.success : AppTheme.textTertiary,
          child: Icon(
            entry.isActive ? Icons.lock_open : Icons.lock_outline,
            color: AppTheme.textOnDark,
          ),
        ),
        title: Text(
          entry.accessCode,
          style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
        ),
        subtitle: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (entry.tenantName != null && entry.tenantName!.isNotEmpty)
                Text('Tenant: ${entry.tenantName}'),
              Text(entry.scheduleSummary),
              if (validity != null) Text(validity),
              if (entry.notes?.isNotEmpty == true)
                Text(
                  entry.notes!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                ),
            ],
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Switch(
              value: entry.isActive,
              onChanged: _canManageAccess ? (value) => _toggleActive(entry, value) : null,
            ),
            const SizedBox(width: 8),
            Text(
              entry.isActive ? 'Active' : 'Disabled',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
        onTap: _canManageAccess ? () => _showEditor(entry: entry) : null,
      ),
    );
  }

  Future<void> _toggleActive(GateAccessModel entry, bool isActive) async {
    if (!_canManageAccess) return;
    try {
      await ref.read(gateAccessOperationsProvider.notifier).updateGateAccess(
            facilityId: widget.facilityId,
            accessId: entry.id,
            isActive: isActive,
            notes: entry.notes,
          );
      ref.invalidate(gateAccessProvider(widget.facilityId));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to update access code: $e')),
      );
    }
  }

  String? _validitySummary(GateAccessModel entry) {
    if (entry.validFrom == null && entry.validUntil == null) return null;
    final buffer = StringBuffer('Valid ');
    if (entry.validFrom != null) {
      buffer.write('from ${_formatDate(entry.validFrom!)} ');
    }
    if (entry.validUntil != null) {
      buffer.write('until ${_formatDate(entry.validUntil!)}');
    }
    return buffer.toString().trim();
  }

  Future<void> _showEditor({GateAccessModel? entry}) async {
    if (!_canManageAccess) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
                    _permissionReason ?? 'You do not have permission to manage access codes.',
          ),
        ),
      );
      return;
    }
    final isEditing = entry != null;
    final tenantsAsync = await ref.read(
      facilityTenantsProvider(widget.facilityId).future,
    );

    TenantModel? selectedTenant;
    if (isEditing && entry!.tenantId != null) {
      for (final tenant in tenantsAsync) {
        if (tenant.id == entry.tenantId) {
          selectedTenant = tenant;
          break;
        }
      }
    }

    final tenantOptions = tenantsAsync;
    
    // Generate unique code for new entries before showing dialog
    String initialCode = entry?.accessCode ?? '';
    if (!isEditing && initialCode.isEmpty) {
      try {
        initialCode = await GateAccessService.generateUniqueAccessCode(
          facilityId: widget.facilityId,
        );
      } catch (e) {
        // Fallback to random code if service fails
        initialCode = _generateCode();
      }
    }
    
    final codeController = TextEditingController(text: initialCode);
    final notesController = TextEditingController(text: entry?.notes ?? '');
    DateTime? validFrom = entry?.validFrom;
    DateTime? validUntil = entry?.validUntil;
    final allowedDays = <String>{
      ...entry?.allowedDays ?? const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
    };
    TimeOfDay? startTime = entry?.allowedStartTime != null
        ? _parseTime(entry!.allowedStartTime!)
        : null;
    TimeOfDay? endTime = entry?.allowedEndTime != null
        ? _parseTime(entry!.allowedEndTime!)
        : null;
    bool isActive = entry?.isActive ?? true;

    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 24,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: StatefulBuilder(
          builder: (context, setState) {
            return SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    isEditing ? 'Edit Access Code' : 'New Access Code',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<TenantModel?>(
                    value: selectedTenant,
                    decoration: const InputDecoration(
                      labelText: 'Tenant (optional)',
                      border: OutlineInputBorder(),
                    ),
                    isExpanded: true,
                    items: [
                      const DropdownMenuItem(
                        value: null,
                        child: Text('Not assigned'),
                      ),
                      ...tenantOptions.map(
                        (tenant) => DropdownMenuItem(
                          value: tenant,
                          child: Text(tenant.name),
                        ),
                      ),
                    ],
                    onChanged: (value) => setState(() {
                      selectedTenant = value;
                    }),
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: codeController,
                    decoration: InputDecoration(
                      labelText: 'Access code',
                      border: const OutlineInputBorder(),
                      suffixIcon: IconButton(
                        icon: const Icon(Icons.refresh),
                        tooltip: 'Generate unique code',
                        onPressed: () async {
                          try {
                            final newCode = await GateAccessService.generateUniqueAccessCode(
                              facilityId: widget.facilityId,
                            );
                            setState(() {
                              codeController.text = newCode;
                            });
                          } catch (e) {
                            // Fallback to random code
                            setState(() {
                              codeController.text = _generateCode();
                            });
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  SwitchListTile.adaptive(
                    value: isActive,
                    onChanged: (value) => setState(() => isActive = value),
                    title: const Text('Active'),
                    subtitle: const Text('Disable to revoke access without deleting the code.'),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Allowed days',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: _weekdays.map((day) {
                      final selected = allowedDays.contains(day);
                      return FilterChip(
                        label: Text(day),
                        selected: selected,
                        onSelected: (value) => setState(() {
                          if (value) {
                            allowedDays.add(day);
                          } else {
                            allowedDays.remove(day);
                          }
                        }),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Daily access window',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final time = await showTimePicker(
                              context: context,
                              initialTime: startTime ?? const TimeOfDay(hour: 6, minute: 0),
                            );
                            if (time != null) {
                              setState(() => startTime = time);
                            }
                          },
                          icon: const Icon(Icons.play_arrow),
                          label: Text(
                            startTime != null
                                ? _timeDisplay(_timeString(startTime!))
                                : 'Start (all day)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final time = await showTimePicker(
                              context: context,
                              initialTime: endTime ?? const TimeOfDay(hour: 21, minute: 0),
                            );
                            if (time != null) {
                              setState(() => endTime = time);
                            }
                          },
                          icon: const Icon(Icons.stop),
                          label: Text(
                            endTime != null
                                ? _timeDisplay(_timeString(endTime!))
                                : 'End (all day)',
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: 'Clear window',
                        onPressed: () => setState(() {
                          startTime = null;
                          endTime = null;
                        }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Validity dates',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final date = await showDatePicker(
                              context: context,
                              initialDate: validFrom ?? DateTime.now(),
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2100),
                            );
                            if (date != null) {
                              setState(() => validFrom = date);
                            }
                          },
                          icon: const Icon(Icons.calendar_today),
                          label: Text(
                            validFrom != null ? _formatDate(validFrom!) : 'Start (optional)',
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () async {
                            final date = await showDatePicker(
                              context: context,
                              initialDate: validUntil ?? DateTime.now().add(const Duration(days: 30)),
                              firstDate: DateTime(2020),
                              lastDate: DateTime(2100),
                            );
                            if (date != null) {
                              setState(() => validUntil = date);
                            }
                          },
                          icon: const Icon(Icons.calendar_today),
                          label: Text(
                            validUntil != null ? _formatDate(validUntil!) : 'End (optional)',
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.clear),
                        tooltip: 'Clear dates',
                        onPressed: () => setState(() {
                          validFrom = null;
                          validUntil = null;
                        }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    controller: notesController,
                    maxLines: 3,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (isEditing)
                        TextButton(
                          onPressed: () {
                            Navigator.of(context).pop();
                            _confirmDelete(entry!);
                          },
                          child: const Text('Delete'),
                        ),
                      const SizedBox(width: 12),
                      ElevatedButton(
                        onPressed: () async {
                          if (codeController.text.trim().isEmpty) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('Access code is required.')),
                            );
                            return;
                          }

                          try {
                            if (isEditing) {
                              await ref
                                  .read(gateAccessOperationsProvider.notifier)
                                  .updateGateAccess(
                                    facilityId: widget.facilityId,
                                    accessId: entry!.id,
                                    accessCode: codeController.text.trim(),
                                    tenantId: selectedTenant?.id,
                                    tenantName: selectedTenant?.name,
                                    isActive: isActive,
                                    validFrom: validFrom,
                                    validUntil: validUntil,
                                    allowedDays: allowedDays.toList(),
                                    allowedStartTime: _timeStringOrNull(startTime),
                                    allowedEndTime: _timeStringOrNull(endTime),
                                    notes: notesController.text.trim(),
                                  );
                            } else {
                              await ref
                                  .read(gateAccessOperationsProvider.notifier)
                                  .createGateAccess(
                                    facilityId: widget.facilityId,
                                    accessCode: codeController.text.trim(),
                                    tenantId: selectedTenant?.id,
                                    tenantName: selectedTenant?.name,
                                    isActive: isActive,
                                    validFrom: validFrom,
                                    validUntil: validUntil,
                                    allowedDays: allowedDays.toList(),
                                    allowedStartTime: _timeStringOrNull(startTime),
                                    allowedEndTime: _timeStringOrNull(endTime),
                                    notes: notesController.text.trim(),
                                  );
                            }

                            if (!mounted) return;
                            Navigator.of(context).pop();
                            ref.invalidate(gateAccessProvider(widget.facilityId));
                          } catch (e) {
                            if (!mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('Unable to save access code: $e')),
                            );
                          }
                        },
                        child: Text(isEditing ? 'Save Changes' : 'Create Access Code'),
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  static const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  Future<void> _confirmDelete(GateAccessModel entry) async {
    if (!_canManageAccess) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete access code?'),
        content: Text(
          'This will remove access code "${entry.accessCode}". This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    try {
      await ref
          .read(gateAccessOperationsProvider.notifier)
          .deleteGateAccess(facilityId: widget.facilityId, accessId: entry.id);
      if (!mounted) return;
      ref.invalidate(gateAccessProvider(widget.facilityId));
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Access code ${entry.accessCode} deleted')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Unable to delete access code: $e')),
      );
    }
  }

  String _generateCode() {
    const chars = '0123456789';
    final random = Random.secure();
    return List.generate(6, (index) => chars[random.nextInt(chars.length)]).join();
  }

  TimeOfDay _parseTime(String value) {
    final parts = value.split(':');
    if (parts.length != 2) return const TimeOfDay(hour: 9, minute: 0);
    final hour = int.tryParse(parts[0]) ?? 9;
    final minute = int.tryParse(parts[1]) ?? 0;
    return TimeOfDay(hour: hour.clamp(0, 23), minute: minute.clamp(0, 59));
  }

  String _timeString(TimeOfDay time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  String? _timeStringOrNull(TimeOfDay? time) {
    return time == null ? null : _timeString(time);
  }

  String _timeDisplay(String time) {
    final parts = time.split(':');
    if (parts.length != 2) return time;
    final hour = int.tryParse(parts[0]) ?? 0;
    final minute = int.tryParse(parts[1]) ?? 0;
    final period = hour >= 12 ? 'PM' : 'AM';
    final normalizedHour = hour % 12 == 0 ? 12 : hour % 12;
    return '$normalizedHour:${minute.toString().padLeft(2, '0')} $period';
  }

  String _formatDate(DateTime date) {
    return '${date.month.toString().padLeft(2, '0')}/'
        '${date.day.toString().padLeft(2, '0')}/'
        '${date.year}';
  }
}

