import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../models/coupon_model.dart';
import '../services/coupon_service.dart';
import '../providers/facility_provider.dart';
import '../providers/auth_provider.dart';
import '../services/modern_navigation_service.dart';

/// Screen for managing coupons/specials
class CouponManagementScreen extends ConsumerStatefulWidget {
  final String? facilityId;

  const CouponManagementScreen({
    super.key,
    this.facilityId,
  });

  @override
  ConsumerState<CouponManagementScreen> createState() => _CouponManagementScreenState();
}

class _CouponManagementScreenState extends ConsumerState<CouponManagementScreen> {
  List<CouponModel> _coupons = [];
  bool _isLoading = true;
  String? _selectedFacilityId;
  String? _statusFilter; // 'all', 'active', 'inactive', 'expired', 'usedUp'

  @override
  void initState() {
    super.initState();
    _selectedFacilityId = widget.facilityId;
    _statusFilter = 'all';
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_selectedFacilityId != null) {
      _loadCoupons();
    } else {
      _loadUserFacilities();
    }
  }

  Future<void> _loadUserFacilities() async {
    final authState = ref.read(authStateProvider);
    authState.whenData((user) {
      if (user != null && mounted) {
        ref.read(userFacilitiesProvider(user.uid).future).then((facilities) {
          if (facilities.isNotEmpty && mounted) {
            setState(() {
              _selectedFacilityId = facilities.first.id;
            });
            _loadCoupons();
          }
        });
      }
    });
  }

  Future<void> _loadCoupons() async {
    if (_selectedFacilityId == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final coupons = await CouponService.getCouponsForFacility(_selectedFacilityId!);
      setState(() {
        _coupons = coupons;
        _isLoading = false;
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading coupons: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  List<CouponModel> get _filteredCoupons {
    if (_statusFilter == 'all') {
      return _coupons;
    }
    return _coupons.where((coupon) {
      switch (_statusFilter) {
        case 'active':
          return coupon.status == CouponStatus.active && coupon.isValid;
        case 'inactive':
          return coupon.status == CouponStatus.inactive;
        case 'expired':
          return coupon.status == CouponStatus.expired;
        case 'usedUp':
          return coupon.status == CouponStatus.usedUp;
        default:
          return true;
      }
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/coupons';
    
    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'Coupons & Specials',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        IconButton(
          icon: const Icon(Icons.add),
          onPressed: () => _showCreateCouponDialog(),
          tooltip: 'Create Coupon',
        ),
        IconButton(
          icon: const Icon(Icons.refresh),
          onPressed: _loadCoupons,
          tooltip: 'Refresh',
        ),
      ],
      child: Column(
        children: [
          // Facility Selector
          if (widget.facilityId == null) _buildFacilitySelector(),
          // Status Filter
          _buildStatusFilter(),
          const Divider(),
          // Coupons List
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredCoupons.isEmpty
                    ? _buildEmptyState()
                    : _buildCouponsList(),
          ),
        ],
      ),
    );
  }

  Widget _buildFacilitySelector() {
    final authState = ref.watch(authStateProvider);
    return authState.when(
      data: (user) {
        if (user == null) return const SizedBox.shrink();
        
        final facilitiesAsync = ref.watch(userFacilitiesProvider(user.uid));
        return facilitiesAsync.when(
          data: (facilities) {
            if (facilities.isEmpty) return const SizedBox.shrink();
            
            return Container(
              padding: const EdgeInsets.all(16),
              child: DropdownButtonFormField<String>(
                value: _selectedFacilityId,
                decoration: const InputDecoration(
                  labelText: 'Facility',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.business),
                ),
                items: facilities.map((facility) {
                  return DropdownMenuItem<String>(
                    value: facility.id,
                    child: Text(facility.name),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null && value != _selectedFacilityId) {
                    setState(() {
                      _selectedFacilityId = value;
                    });
                    _loadCoupons();
                  }
                },
              ),
            );
          },
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
          error: (_, __) => const SizedBox.shrink(),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildStatusFilter() {
    return Container(
      padding: const EdgeInsets.all(16),
      child: SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'all', label: Text('All')),
          ButtonSegment(value: 'active', label: Text('Active')),
          ButtonSegment(value: 'inactive', label: Text('Inactive')),
          ButtonSegment(value: 'expired', label: Text('Expired')),
          ButtonSegment(value: 'usedUp', label: Text('Used Up')),
        ],
        selected: {_statusFilter ?? 'all'},
        onSelectionChanged: (Set<String> selected) {
          setState(() {
            _statusFilter = selected.first;
          });
        },
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.local_offer_outlined, size: 64, color: AppTheme.textTertiary),
          const SizedBox(height: 16),
          Text(
            'No coupons found',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: _showCreateCouponDialog,
            icon: const Icon(Icons.add),
            label: const Text('Create First Coupon'),
          ),
        ],
      ),
    );
  }

  Widget _buildCouponsList() {
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _filteredCoupons.length,
      itemBuilder: (context, index) {
        final coupon = _filteredCoupons[index];
        return _buildCouponCard(coupon);
      },
    );
  }

  Widget _buildCouponCard(CouponModel coupon) {
    final statusColor = _getStatusColor(coupon.status);
    final isValid = coupon.isValid;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: statusColor.withOpacity(0.1),
          child: Icon(
            Icons.local_offer,
            color: statusColor,
          ),
        ),
        title: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    coupon.code,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  Text(
                    coupon.name,
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            ),
            Chip(
              label: Text(
                coupon.statusDisplayName,
                style: TextStyle(
                  fontSize: 11,
                  color: statusColor,
                  fontWeight: FontWeight.bold,
                ),
              ),
              backgroundColor: statusColor.withOpacity(0.1),
            ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.discount, size: 16, color: AppTheme.primaryBlue),
                const SizedBox(width: 4),
                Text(
                  coupon.formattedValue,
                  style: TextStyle(
                    color: AppTheme.primaryBlue,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            if (coupon.description != null && coupon.description!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                coupon.description!,
                style: TextStyle(color: AppTheme.textTertiary, fontSize: 12),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 4,
              children: [
                if (coupon.validFrom != null)
                  _buildInfoChip(
                    Icons.calendar_today,
                    'From: ${DateFormat('MM/dd/yyyy').format(coupon.validFrom!)}',
                  ),
                if (coupon.validUntil != null)
                  _buildInfoChip(
                    Icons.event,
                    'Until: ${DateFormat('MM/dd/yyyy').format(coupon.validUntil!)}',
                  ),
                if (coupon.maxUses != null)
                  _buildInfoChip(
                    Icons.people,
                    '${coupon.currentUses}/${coupon.maxUses} uses',
                  ),
              ],
            ),
          ],
        ),
        trailing: PopupMenuButton(
          itemBuilder: (context) => [
            const PopupMenuItem(
              value: 'edit',
              child: Row(
                children: [
                  Icon(Icons.edit, size: 18),
                  SizedBox(width: 8),
                  Text('Edit'),
                ],
              ),
            ),
            if (coupon.status == CouponStatus.active)
              const PopupMenuItem(
                value: 'deactivate',
                child: Row(
                  children: [
                    Icon(Icons.block, size: 18),
                    SizedBox(width: 8),
                    Text('Deactivate'),
                  ],
                ),
              ),
            if (coupon.status == CouponStatus.inactive)
              const PopupMenuItem(
                value: 'activate',
                child: Row(
                  children: [
                    Icon(Icons.check_circle, size: 18),
                    SizedBox(width: 8),
                    Text('Activate'),
                  ],
                ),
              ),
            const PopupMenuItem(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete, color: AppTheme.error, size: 18),
                  SizedBox(width: 8),
                  Text('Delete', style: TextStyle(color: AppTheme.error)),
                ],
              ),
            ),
          ],
          onSelected: (value) {
            switch (value) {
              case 'edit':
                _showEditCouponDialog(coupon);
                break;
              case 'activate':
                _activateCoupon(coupon);
                break;
              case 'deactivate':
                _deactivateCoupon(coupon);
                break;
              case 'delete':
                _deleteCoupon(coupon);
                break;
            }
          },
        ),
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String label) {
    return Chip(
      avatar: Icon(icon, size: 14, color: AppTheme.textSecondary),
      label: Text(
        label,
        style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
      ),
      backgroundColor: AppTheme.backgroundLight,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
    );
  }

  Color _getStatusColor(CouponStatus status) {
    switch (status) {
      case CouponStatus.active:
        return AppTheme.success;
      case CouponStatus.inactive:
        return AppTheme.textTertiary;
      case CouponStatus.expired:
        return AppTheme.warning;
      case CouponStatus.usedUp:
        return AppTheme.error;
    }
  }

  void _showCreateCouponDialog() {
    if (_selectedFacilityId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select a facility first')),
      );
      return;
    }

    showDialog(
      context: context,
      builder: (context) => _CouponDialog(
        facilityId: _selectedFacilityId!,
        onSaved: () {
          _loadCoupons();
          Navigator.of(context).pop();
        },
      ),
    );
  }

  void _showEditCouponDialog(CouponModel coupon) {
    showDialog(
      context: context,
      builder: (context) => _CouponDialog(
        facilityId: coupon.facilityId,
        coupon: coupon,
        onSaved: () {
          _loadCoupons();
          Navigator.of(context).pop();
        },
      ),
    );
  }

  Future<void> _activateCoupon(CouponModel coupon) async {
    try {
      await CouponService.updateCoupon(
        facilityId: coupon.facilityId,
        couponId: coupon.id,
        status: CouponStatus.active,
      );
      _loadCoupons();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Coupon activated'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error activating coupon: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  Future<void> _deactivateCoupon(CouponModel coupon) async {
    try {
      await CouponService.updateCoupon(
        facilityId: coupon.facilityId,
        couponId: coupon.id,
        status: CouponStatus.inactive,
      );
      _loadCoupons();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Coupon deactivated'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Error deactivating coupon: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    }
  }

  Future<void> _deleteCoupon(CouponModel coupon) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Coupon'),
        content: Text('Are you sure you want to delete coupon "${coupon.code}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await CouponService.deleteCoupon(
          facilityId: coupon.facilityId,
          couponId: coupon.id,
        );
        _loadCoupons();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Coupon deleted'),
            backgroundColor: AppTheme.success,
          ),
        );
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting coupon: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }
}

/// Dialog for creating/editing coupons
class _CouponDialog extends StatefulWidget {
  final String facilityId;
  final CouponModel? coupon;
  final VoidCallback onSaved;

  const _CouponDialog({
    required this.facilityId,
    this.coupon,
    required this.onSaved,
  });

  @override
  State<_CouponDialog> createState() => _CouponDialogState();
}

class _CouponDialogState extends State<_CouponDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _codeController;
  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late TextEditingController _valueController;
  late TextEditingController _minPurchaseController;
  late TextEditingController _maxUsesController;

  CouponType _selectedType = CouponType.percentage;
  DateTime? _validFrom;
  DateTime? _validUntil;
  bool _appliesToRent = true;
  bool _appliesToFees = true;
  bool _appliesToInsurance = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final coupon = widget.coupon;
    _codeController = TextEditingController(text: coupon?.code ?? '');
    _nameController = TextEditingController(text: coupon?.name ?? '');
    _descriptionController = TextEditingController(text: coupon?.description ?? '');
    _valueController = TextEditingController(
      text: coupon != null ? coupon.value.toStringAsFixed(2) : '',
    );
    _minPurchaseController = TextEditingController(
      text: coupon?.minPurchaseAmount?.toStringAsFixed(2) ?? '',
    );
    _maxUsesController = TextEditingController(
      text: coupon?.maxUses?.toString() ?? '',
    );

    if (coupon != null) {
      _selectedType = coupon.type;
      _validFrom = coupon.validFrom;
      _validUntil = coupon.validUntil;
      _appliesToRent = coupon.appliesToRent;
      _appliesToFees = coupon.appliesToFees;
      _appliesToInsurance = coupon.appliesToInsurance;
    }
  }

  @override
  void dispose() {
    _codeController.dispose();
    _nameController.dispose();
    _descriptionController.dispose();
    _valueController.dispose();
    _minPurchaseController.dispose();
    _maxUsesController.dispose();
    super.dispose();
  }

  Future<void> _saveCoupon() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSaving = true;
    });

    try {
      final value = double.parse(_valueController.text);
      final minPurchase = _minPurchaseController.text.isNotEmpty
          ? double.tryParse(_minPurchaseController.text)
          : null;
      final maxUses = _maxUsesController.text.isNotEmpty
          ? int.tryParse(_maxUsesController.text)
          : null;

      if (widget.coupon == null) {
        // Create new coupon
        await CouponService.createCoupon(
          facilityId: widget.facilityId,
          code: _codeController.text.trim(),
          name: _nameController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          type: _selectedType,
          value: value,
          validFrom: _validFrom,
          validUntil: _validUntil,
          maxUses: maxUses,
          minPurchaseAmount: minPurchase,
          appliesToRent: _appliesToRent,
          appliesToFees: _appliesToFees,
          appliesToInsurance: _appliesToInsurance,
        );
      } else {
        // Update existing coupon
        await CouponService.updateCoupon(
          facilityId: widget.facilityId,
          couponId: widget.coupon!.id,
          name: _nameController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          type: _selectedType,
          value: value,
          validFrom: _validFrom,
          validUntil: _validUntil,
          maxUses: maxUses,
          minPurchaseAmount: minPurchase,
          appliesToRent: _appliesToRent,
          appliesToFees: _appliesToFees,
          appliesToInsurance: _appliesToInsurance,
        );
      }

      widget.onSaved();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving coupon: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _selectDate(bool isFromDate) async {
    final selected = await showDatePicker(
      context: context,
      initialDate: isFromDate
          ? (_validFrom ?? DateTime.now())
          : (_validUntil ?? DateTime.now().add(const Duration(days: 30))),
      firstDate: DateTime.now().subtract(const Duration(days: 365)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );

    if (selected != null) {
      setState(() {
        if (isFromDate) {
          _validFrom = selected;
        } else {
          _validUntil = selected;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.coupon != null;

    return Dialog(
      child: Container(
        width: 600,
        constraints: const BoxConstraints(maxHeight: 800),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.primaryBlue,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                ),
              ),
              child: Row(
                children: [
                  const Icon(Icons.local_offer, color: AppTheme.textOnDark),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      isEdit ? 'Edit Coupon' : 'Create Coupon',
                      style: const TextStyle(
                        color: AppTheme.textOnDark,
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: AppTheme.textOnDark),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            // Form
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Code (disabled if editing)
                      if (isEdit)
                        TextFormField(
                          controller: _codeController,
                          decoration: const InputDecoration(
                            labelText: 'Coupon Code',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.tag),
                          ),
                          enabled: false,
                        )
                      else
                        TextFormField(
                          controller: _codeController,
                          decoration: const InputDecoration(
                            labelText: 'Coupon Code *',
                            border: OutlineInputBorder(),
                            prefixIcon: Icon(Icons.tag),
                            hintText: 'e.g., SUMMER2025',
                          ),
                          textCapitalization: TextCapitalization.characters,
                          validator: (value) {
                            if (value == null || value.trim().isEmpty) {
                              return 'Coupon code is required';
                            }
                            return null;
                          },
                        ),
                      const SizedBox(height: 16),
                      // Name
                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Name *',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.title),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Name is required';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      // Description
                      TextFormField(
                        controller: _descriptionController,
                        decoration: const InputDecoration(
                          labelText: 'Description (optional)',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.description),
                        ),
                        maxLines: 2,
                      ),
                      const SizedBox(height: 16),
                      // Type
                      DropdownButtonFormField<CouponType>(
                        value: _selectedType,
                        decoration: const InputDecoration(
                          labelText: 'Discount Type *',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.category),
                        ),
                        items: CouponType.values.map((type) {
                          String label;
                          switch (type) {
                            case CouponType.percentage:
                              label = 'Percentage (%)';
                              break;
                            case CouponType.fixedAmount:
                              label = 'Fixed Amount (\$)';
                              break;
                            case CouponType.freeMonth:
                              label = 'Free Month';
                              break;
                          }
                          return DropdownMenuItem(
                            value: type,
                            child: Text(label),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _selectedType = value;
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      // Value
                      TextFormField(
                        controller: _valueController,
                        decoration: InputDecoration(
                          labelText: _selectedType == CouponType.percentage
                              ? 'Percentage (0-100) *'
                              : _selectedType == CouponType.fixedAmount
                                  ? 'Amount (\$) *'
                                  : 'Value *',
                          border: const OutlineInputBorder(),
                          prefixIcon: const Icon(Icons.attach_money),
                        ),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Value is required';
                          }
                          final numValue = double.tryParse(value);
                          if (numValue == null) {
                            return 'Invalid number';
                          }
                          if (_selectedType == CouponType.percentage &&
                              (numValue < 0 || numValue > 100)) {
                            return 'Percentage must be between 0 and 100';
                          }
                          if ((_selectedType == CouponType.fixedAmount ||
                                  _selectedType == CouponType.freeMonth) &&
                              numValue < 0) {
                            return 'Value must be positive';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      // Date Range
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _selectDate(true),
                              icon: const Icon(Icons.calendar_today),
                              label: Text(
                                _validFrom != null
                                    ? 'From: ${DateFormat('MM/dd/yyyy').format(_validFrom!)}'
                                    : 'Valid From (optional)',
                              ),
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: () => _selectDate(false),
                              icon: const Icon(Icons.event),
                              label: Text(
                                _validUntil != null
                                    ? 'Until: ${DateFormat('MM/dd/yyyy').format(_validUntil!)}'
                                    : 'Valid Until (optional)',
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Max Uses
                      TextFormField(
                        controller: _maxUsesController,
                        decoration: const InputDecoration(
                          labelText: 'Max Uses (optional)',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.people),
                          hintText: 'Leave empty for unlimited',
                        ),
                        keyboardType: TextInputType.number,
                        validator: (value) {
                          if (value != null && value.trim().isNotEmpty) {
                            final intValue = int.tryParse(value);
                            if (intValue == null || intValue < 1) {
                              return 'Must be a positive number';
                            }
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      // Min Purchase
                      TextFormField(
                        controller: _minPurchaseController,
                        decoration: const InputDecoration(
                          labelText: 'Minimum Purchase Amount (optional)',
                          border: OutlineInputBorder(),
                          prefixIcon: Icon(Icons.shopping_cart),
                          hintText: '\$0.00',
                        ),
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        validator: (value) {
                          if (value != null && value.trim().isNotEmpty) {
                            final numValue = double.tryParse(value);
                            if (numValue == null || numValue < 0) {
                              return 'Must be a valid positive number';
                            }
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 24),
                      // Applies To
                      const Text(
                        'Applies To:',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      CheckboxListTile(
                        title: const Text('Rent'),
                        value: _appliesToRent,
                        onChanged: (value) {
                          setState(() {
                            _appliesToRent = value ?? false;
                          });
                        },
                      ),
                      CheckboxListTile(
                        title: const Text('Fees'),
                        value: _appliesToFees,
                        onChanged: (value) {
                          setState(() {
                            _appliesToFees = value ?? false;
                          });
                        },
                      ),
                      CheckboxListTile(
                        title: const Text('Insurance'),
                        value: _appliesToInsurance,
                        onChanged: (value) {
                          setState(() {
                            _appliesToInsurance = value ?? false;
                          });
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // Actions
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.backgroundLight,
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(8),
                  bottomRight: Radius.circular(8),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: _isSaving ? null : () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _isSaving ? null : _saveCoupon,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                      foregroundColor: AppTheme.textOnDark,
                    ),
                    child: _isSaving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(isEdit ? 'Update' : 'Create'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

