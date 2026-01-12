import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/foundation.dart';
import '../services/public_rental_service.dart';
import '../models/unit_model.dart';
import '../models/facility_model.dart';
import '../theme/app_theme.dart';
import 'package:intl/intl.dart';

/// Public rental portal screen - shows available units for a facility
/// Accessible via /rental?facilityId=...
class PublicRentalPortalScreen extends StatefulWidget {
  final String? facilityId;

  const PublicRentalPortalScreen({
    super.key,
    this.facilityId,
  });

  @override
  State<PublicRentalPortalScreen> createState() => _PublicRentalPortalScreenState();
}

class _PublicRentalPortalScreenState extends State<PublicRentalPortalScreen> {
  FacilityModel? _facility;
  List<UnitModel> _availableUnits = [];
  bool _isLoading = true;
  String? _error;
  String _searchQuery = '';
  UnitType? _selectedType;
  double? _maxPrice;

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    final facilityId = widget.facilityId ?? _getFacilityIdFromUrl();
    if (facilityId == null || facilityId.isEmpty) {
      setState(() {
        _error = 'Facility ID is required';
        _isLoading = false;
      });
      return;
    }

    try {
      final facility = await PublicRentalService.getFacility(facilityId);
      final units = await PublicRentalService.getAvailableUnits(facilityId);

      setState(() {
        _facility = facility;
        _availableUnits = units;
        _isLoading = false;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error loading rental portal data: $e');
      }
      setState(() {
        _error = 'Error loading facility information';
        _isLoading = false;
      });
    }
  }

  String? _getFacilityIdFromUrl() {
    final uri = Uri.base;
    return uri.queryParameters['facilityId'];
  }

  List<UnitModel> get _filteredUnits {
    var filtered = _availableUnits;

    // Search filter
    if (_searchQuery.isNotEmpty) {
      filtered = filtered.where((unit) {
        return unit.unitNumber.toLowerCase().contains(_searchQuery.toLowerCase()) ||
            (unit.description?.toLowerCase().contains(_searchQuery.toLowerCase()) ?? false);
      }).toList();
    }

    // Type filter
    if (_selectedType != null) {
      filtered = filtered.where((unit) => unit.unitType == _selectedType!.name).toList();
    }

    // Price filter
    if (_maxPrice != null) {
      filtered = filtered.where((unit) => unit.monthlyRate <= _maxPrice!).toList();
    }

    return filtered;
  }

  Future<void> _reserveUnit(UnitModel unit) async {
    // Show reservation dialog
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (context) => _ReservationDialog(unit: unit),
    );

    if (result != null && mounted) {
      // Create reservation
      try {
        final reservation = await PublicRentalService.createReservation(
          facilityId: unit.facilityId,
          unitId: unit.id,
          unitNumber: unit.unitNumber,
          email: result['email']!,
          phone: result['phone'],
          name: result['name'],
          moveInDate: result['moveInDate'] != null ? DateTime.parse(result['moveInDate']!) : null,
        );

        // Navigate to move-in wizard
        if (mounted) {
          context.push('/public-move-in?token=${reservation.moveInToken}');
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error creating reservation: $e'),
              backgroundColor: AppTheme.error,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(_facility?.name ?? 'Storage Facility'),
        backgroundColor: AppTheme.primaryBlueDark,
        foregroundColor: AppTheme.textOnDark,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline, size: 64, color: AppTheme.error),
                      const SizedBox(height: 16),
                      Text(_error!, style: const TextStyle(fontSize: 16)),
                      const SizedBox(height: 16),
                      ElevatedButton(
                        onPressed: () => context.pop(),
                        child: const Text('Go Back'),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Facility info banner
                    if (_facility != null) _buildFacilityBanner(_facility!),

                    // Filters
                    _buildFilters(),

                    // Unit list
                    Expanded(
                      child: _filteredUnits.isEmpty
                          ? Center(
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.inbox_outlined, size: 64, color: AppTheme.textTertiary),
                                  const SizedBox(height: 16),
                                  Text(
                                    'No available units found',
                                    style: TextStyle(color: AppTheme.textTertiary),
                                  ),
                                ],
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.all(16),
                              itemCount: _filteredUnits.length,
                              itemBuilder: (context, index) {
                                return _buildUnitCard(_filteredUnits[index]);
                              },
                            ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildFacilityBanner(FacilityModel facility) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: AppTheme.primaryBlueLight,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (facility.description != null) ...[
            Text(
              facility.description!,
              style: const TextStyle(fontSize: 14, color: Colors.white70),
            ),
            const SizedBox(height: 8),
          ],
          if (facility.address != null)
            Row(
              children: [
                const Icon(Icons.location_on, size: 16, color: Colors.white70),
                const SizedBox(width: 4),
                Text(
                  facility.address!,
                  style: const TextStyle(fontSize: 14, color: Colors.white70),
                ),
              ],
            ),
          if (facility.phone != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                const Icon(Icons.phone, size: 16, color: Colors.white70),
                const SizedBox(width: 4),
                Text(
                  facility.phone!,
                  style: const TextStyle(fontSize: 14, color: Colors.white70),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        children: [
          // Search
          TextField(
            decoration: InputDecoration(
              labelText: 'Search units',
              prefixIcon: const Icon(Icons.search),
              border: OutlineInputBorder(),
              filled: true,
              fillColor: Colors.grey[100],
            ),
            onChanged: (value) {
              setState(() {
                _searchQuery = value;
              });
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              // Type filter
              Expanded(
                child: DropdownButtonFormField<UnitType>(
                  value: _selectedType,
                  decoration: const InputDecoration(
                    labelText: 'Unit Type',
                    border: OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.grey,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  items: UnitType.values.map((type) {
                    return DropdownMenuItem(
                      value: type,
                      child: Text(type.name),
                    );
                  }).toList(),
                  onChanged: (value) {
                    setState(() {
                      _selectedType = value;
                    });
                  },
                ),
              ),
              const SizedBox(width: 12),
              // Price filter
              Expanded(
                child: TextField(
                  decoration: const InputDecoration(
                    labelText: 'Max Price',
                    prefixText: '\$',
                    border: OutlineInputBorder(),
                    filled: true,
                    fillColor: Colors.grey,
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  keyboardType: TextInputType.number,
                  onChanged: (value) {
                    setState(() {
                      _maxPrice = double.tryParse(value);
                    });
                  },
                ),
              ),
              const SizedBox(width: 12),
              // Clear filters
              IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  setState(() {
                    _selectedType = null;
                    _maxPrice = null;
                    _searchQuery = '';
                  });
                },
                tooltip: 'Clear filters',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${_filteredUnits.length} unit${_filteredUnits.length != 1 ? 's' : ''} available',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildUnitCard(UnitModel unit) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        title: Text(
          'Unit ${unit.unitNumber}',
          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text('Type: ${unit.unitType}'),
            if (unit.description != null) ...[
              const SizedBox(height: 4),
              Text(unit.description!),
            ],
            if (unit.dimensions != null) ...[
              const SizedBox(height: 4),
              Text(
                'Dimensions: ${_formatDimensions(unit.dimensions!)}',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
            ],
          ],
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '\$${unit.monthlyRate.toStringAsFixed(2)}/mo',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 18,
                color: AppTheme.primaryBlueDark,
              ),
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => _reserveUnit(unit),
              child: const Text('Reserve'),
            ),
          ],
        ),
        isThreeLine: true,
      ),
    );
  }

  String _formatDimensions(Map<String, dynamic> dimensions) {
    final width = dimensions['width'];
    final height = dimensions['height'];
    final depth = dimensions['depth'];
    final parts = <String>[];
    if (width != null) parts.add('${width}"W');
    if (height != null) parts.add('${height}"H');
    if (depth != null) parts.add('${depth}"D');
    return parts.join(' × ');
  }
}

class _ReservationDialog extends StatefulWidget {
  final UnitModel unit;

  const _ReservationDialog({required this.unit});

  @override
  State<_ReservationDialog> createState() => _ReservationDialogState();
}

class _ReservationDialogState extends State<_ReservationDialog> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _nameController = TextEditingController();
  final _phoneController = TextEditingController();
  DateTime? _moveInDate;

  @override
  void dispose() {
    _emailController.dispose();
    _nameController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  Future<void> _selectMoveInDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _moveInDate ?? DateTime.now(),
      firstDate: DateTime.now(),
      lastDate: DateTime.now().add(const Duration(days: 365)),
    );
    if (picked != null) {
      setState(() {
        _moveInDate = picked;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Reserve Unit ${widget.unit.unitNumber}'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '\$${widget.unit.monthlyRate.toStringAsFixed(2)}/month',
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email),
                ),
                keyboardType: TextInputType.emailAddress,
                validator: (value) {
                  if (value == null || value.isEmpty) {
                    return 'Email is required';
                  }
                  if (!value.contains('@')) {
                    return 'Please enter a valid email';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _phoneController,
                decoration: const InputDecoration(
                  labelText: 'Phone',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.phone),
                ),
                keyboardType: TextInputType.phone,
              ),
              const SizedBox(height: 16),
              InkWell(
                onTap: _selectMoveInDate,
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Preferred Move-In Date',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.calendar_today),
                  ),
                  child: Text(
                    _moveInDate == null
                        ? 'Select date'
                        : DateFormat.yMMMd().format(_moveInDate!),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            if (_formKey.currentState!.validate()) {
              Navigator.of(context).pop({
                'email': _emailController.text.trim(),
                'name': _nameController.text.trim().isEmpty ? null : _nameController.text.trim(),
                'phone': _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim(),
                'moveInDate': _moveInDate?.toIso8601String(),
              });
            }
          },
          child: const Text('Reserve'),
        ),
      ],
    );
  }
}

