import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/foundation.dart';
import '../models/tenant_model.dart';
import '../models/unit_model.dart';
import '../models/contract_model.dart';
import '../models/invoice_line_item_model.dart';
import '../services/move_in_service.dart';
import '../services/prorate_service.dart';
import '../services/tenant_service.dart';
import '../services/unit_service.dart';
import '../services/contract_service.dart';
import '../services/facility_service.dart';
import '../providers/tenant_provider.dart';
import '../providers/unit_provider.dart';
import '../models/facility_model.dart';
import '../theme/app_theme.dart';

class MoveInWizardScreen extends ConsumerStatefulWidget {
  final String facilityId;
  final String? unitId;
  final String? tenantId; // Pre-selected tenant

  const MoveInWizardScreen({
    super.key,
    required this.facilityId,
    this.unitId,
    this.tenantId,
  });

  @override
  ConsumerState<MoveInWizardScreen> createState() => _MoveInWizardScreenState();
}

class _MoveInWizardScreenState extends ConsumerState<MoveInWizardScreen> {
  int _currentStep = 0;
  final _formKey = GlobalKey<FormState>();

  // Step 1: Tenant & Unit
  TenantModel? _selectedTenant;
  UnitModel? _selectedUnit;
  DateTime _moveInDate = DateTime.now();

  // Step 2: Financial
  double _monthlyRent = 0.0;
  String? _insuranceSelection; // 'tpp', 'own', 'none'
  double? _insuranceAmount;
  double? _adminFee;
  double? _moveInFee;
  double? _securityDeposit;
  bool _prorateRent = true;
  String? _couponCode;
  List<InvoiceLineItem> _lineItems = [];
  double _totalAmount = 0.0;
  FacilityModel? _facility;

  // Step 3: Contract
  ContractModel? _contract;
  bool _contractSigned = false;

  // Step 4: Payment
  String? _paymentMethod; // 'cash', 'check', 'creditCard', 'ach'
  bool _skipPayment = false;

  bool _isLoading = false;
  String? _errorMessage;

  Future<TenantModel?> _pickTenant() async {
    final tenants = await TenantService.getTenantsForFacility(widget.facilityId);
    if (!mounted) return null;
    return showModalBottomSheet<TenantModel>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: 480,
          child: Column(
            children: [
              const ListTile(
                title: Text('Select Tenant'),
                subtitle: Text('Choose the tenant for this move-in'),
              ),
              const Divider(height: 1),
              Expanded(
                child: ListView.builder(
                  itemCount: tenants.length,
                  itemBuilder: (context, index) {
                    final tenant = tenants[index];
                    return ListTile(
                      leading: const Icon(Icons.person),
                      title: Text(tenant.name),
                      subtitle: Text(tenant.email),
                      onTap: () => Navigator.of(context).pop(tenant),
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

  Future<UnitModel?> _pickUnit() async {
    final units = await UnitService.getUnitsForFacility(widget.facilityId);
    final availableUnits = units.where((u) => u.status == UnitStatus.available).toList()
      ..sort((a, b) => a.unitNumber.compareTo(b.unitNumber));
    if (!mounted) return null;
    return showModalBottomSheet<UnitModel>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SizedBox(
          height: 520,
          child: Column(
            children: [
              const ListTile(
                title: Text('Select Unit'),
                subtitle: Text('Only currently available units are shown'),
              ),
              const Divider(height: 1),
              if (availableUnits.isEmpty)
                const Expanded(
                  child: Center(
                    child: Text('No available units found for this facility.'),
                  ),
                )
              else
                Expanded(
                  child: ListView.builder(
                    itemCount: availableUnits.length,
                    itemBuilder: (context, index) {
                      final unit = availableUnits[index];
                      return ListTile(
                        leading: const Icon(Icons.home),
                        title: Text('Unit ${unit.unitNumber}'),
                        subtitle: Text('\$${unit.monthlyRate.toStringAsFixed(2)}/month'),
                        onTap: () => Navigator.of(context).pop(unit),
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

  @override
  void initState() {
    super.initState();
    _loadInitialData();
  }

  Future<void> _loadInitialData() async {
    // Load facility settings for insurance options
    try {
      final facility = await FacilityService.getFacility(widget.facilityId);
      if (facility != null) {
        setState(() {
          _facility = facility;
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error loading facility: $e');
      }
    }

    // Load pre-selected unit if provided
    if (widget.unitId != null) {
      try {
        final units = await UnitService.getUnitsForFacility(widget.facilityId);
        final unit = units.firstWhere(
          (u) => u.id == widget.unitId,
          orElse: () => units.first,
        );
        if (unit.id == widget.unitId) {
          setState(() {
            _selectedUnit = unit;
            _monthlyRent = unit.monthlyRate;
          });
        }
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Error loading unit: $e');
        }
      }
    }

    // Load pre-selected tenant if provided
    if (widget.tenantId != null) {
      try {
        final tenants = await TenantService.getTenantsForFacility(widget.facilityId);
        final tenant = tenants.firstWhere(
          (t) => t.id == widget.tenantId,
          orElse: () => tenants.first,
        );
        if (tenant.id == widget.tenantId) {
          setState(() {
            _selectedTenant = tenant;
          });
        }
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Error loading tenant: $e');
        }
      }
    }
  }

  Future<void> _calculateCharges() async {
    if (_selectedUnit == null || _monthlyRent <= 0) {
      setState(() {
        _lineItems = [];
        _totalAmount = 0.0;
      });
      return;
    }

    try {
      final lineItems = await MoveInService.calculateMoveInCharges(
        facilityId: widget.facilityId,
        unitId: _selectedUnit!.id,
        monthlyRent: _monthlyRent,
        moveInDate: _moveInDate,
        insuranceAmount: _insuranceAmount,
        adminFee: _adminFee,
        moveInFee: _moveInFee,
        securityDeposit: _securityDeposit,
        couponCode: _couponCode,
        prorateRent: _prorateRent,
      );

      final total = lineItems.fold(0.0, (sum, item) => sum + item.amount);

      setState(() {
        _lineItems = lineItems;
        _totalAmount = total;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error calculating charges: $e');
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error calculating charges: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _completeMoveIn() async {
    if (_selectedTenant == null || _selectedUnit == null) {
      setState(() {
        _errorMessage = 'Please select tenant and unit';
      });
      return;
    }

    if (_lineItems.isEmpty) {
      setState(() {
        _errorMessage = 'Please calculate charges first';
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // Create contract if not already created
      if (_contract == null) {
        final contractId = await ContractService.createContract(
          facilityId: widget.facilityId,
          tenantId: _selectedTenant!.id,
          title: 'Storage Lease - ${_selectedUnit!.unitNumber}',
          description: 'Move-in contract for unit ${_selectedUnit!.unitNumber}',
          type: ContractType.lease,
        );
        final createdContract = await ContractService.getContract(widget.facilityId, contractId);
        if (createdContract == null) {
          throw Exception('Failed to retrieve created contract');
        }
        _contract = createdContract;
      }

      // Update tenant insurance status before completing move-in
      if (_insuranceSelection != null && _selectedTenant != null) {
        InsuranceStatus? insuranceStatus;
        double? coverageAmount;
        String? tppCoverageLevel;
        DateTime? tppEnrollmentDate;
        
        if (_insuranceSelection == 'tpp' && _facility?.insuranceSettings != null) {
          insuranceStatus = InsuranceStatus.enrolledInTPP;
          final settings = _facility!.insuranceSettings!;
          coverageAmount = (settings['defaultCoverageAmount'] ?? 5000.0).toDouble();
          tppCoverageLevel = settings['defaultCoverageLevel'] ?? 'minimum';
          tppEnrollmentDate = DateTime.now();
        } else if (_insuranceSelection == 'own') {
          insuranceStatus = InsuranceStatus.pendingProof;
        } else {
          insuranceStatus = InsuranceStatus.none;
        }
        
        await TenantService.updateTenant(
          tenantId: _selectedTenant!.id,
          facilityId: widget.facilityId,
          insuranceStatus: insuranceStatus,
          coverageAmount: coverageAmount,
          tppCoverageLevel: tppCoverageLevel,
          tppEnrollmentDate: tppEnrollmentDate,
        );
      }

      // Prepare move-in data
      final moveInData = MoveInData(
        existingTenant: _selectedTenant,
        unit: _selectedUnit!,
        contract: _contract!,
        lineItems: _lineItems,
        totalAmount: _totalAmount,
        moveInDate: _moveInDate,
        requiresSignature: !_contractSigned,
        requiresPayment: !_skipPayment,
      );

      // Generate payment reference ID if payment is being processed
      String? paymentReferenceId;
      if (!_skipPayment && _paymentMethod != null && _totalAmount > 0) {
        // Generate a reference ID based on payment method
        // For Stripe payments, this would be the payment intent ID
        // For cash/check, we use a formatted reference
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        switch (_paymentMethod) {
          case 'cash':
            paymentReferenceId = 'CASH-$timestamp';
            break;
          case 'check':
            paymentReferenceId = 'CHECK-$timestamp';
            break;
          case 'creditCard':
          case 'ach':
            // For Stripe payments, this should be set from payment processing
            // For now, use a placeholder that indicates it needs processing
            paymentReferenceId = 'STRIPE-$timestamp';
            break;
          default:
            paymentReferenceId = 'PAY-$timestamp';
        }
      }

      // Complete move-in
      final result = await MoveInService.completeMoveIn(
        moveInData: moveInData,
        paymentMethod: _skipPayment ? null : _paymentMethod,
        paymentReferenceId: paymentReferenceId,
        skipPayment: _skipPayment,
      );

      if (result.success) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Move-in completed successfully!'),
              backgroundColor: AppTheme.success,
            ),
          );
          context.pop(true); // Return success
        }
      } else {
        setState(() {
          _errorMessage = result.error ?? 'Failed to complete move-in';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error completing move-in: $e');
      }
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Move-In Wizard'),
        backgroundColor: AppTheme.primaryBlueDark,
        foregroundColor: AppTheme.textOnDark,
      ),
      body: Form(
        key: _formKey,
        child: Stepper(
          currentStep: _currentStep,
          onStepContinue: () {
            if (_currentStep < 4) {
              if (_validateCurrentStep()) {
                setState(() {
                  _currentStep += 1;
                  if (_currentStep == 2) {
                    // Calculate charges when entering financial step
                    _calculateCharges();
                  }
                });
              }
            } else {
              _completeMoveIn();
            }
          },
          onStepCancel: () {
            if (_currentStep > 0) {
              setState(() {
                _currentStep -= 1;
              });
            } else {
              context.pop();
            }
          },
          onStepTapped: (step) {
            if (step < _currentStep) {
              setState(() {
                _currentStep = step;
              });
            }
          },
          steps: [
            _buildStep1TenantUnit(),
            _buildStep2Financial(),
            _buildStep3Contract(),
            _buildStep4Payment(),
            _buildStep5Complete(),
          ],
        ),
      ),
    );
  }

  bool _validateCurrentStep() {
    switch (_currentStep) {
      case 0:
        if (_selectedTenant == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please select a tenant')),
          );
          return false;
        }
        if (_selectedUnit == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please select a unit')),
          );
          return false;
        }
        return true;
      case 1:
        if (_monthlyRent <= 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Please enter a valid monthly rent')),
          );
          return false;
        }
        return true;
      case 2:
        // Contract step - can skip if not required
        return true;
      case 3:
        // Payment step - can skip
        return true;
      default:
        return true;
    }
  }

  Step _buildStep1TenantUnit() {
    return Step(
      title: const Text('Tenant & Unit'),
      subtitle: const Text('Select tenant and unit for move-in'),
      isActive: _currentStep >= 0,
      state: _selectedTenant != null && _selectedUnit != null
          ? StepState.complete
          : _currentStep == 0
              ? StepState.indexed
              : StepState.indexed,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tenant Selection
          const Text(
            'Select Tenant',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          _selectedTenant == null
              ? ElevatedButton.icon(
                  onPressed: () async {
                    final tenant = await _pickTenant();
                    if (tenant != null) {
                      setState(() {
                        _selectedTenant = tenant;
                      });
                    }
                  },
                  icon: const Icon(Icons.person_add),
                  label: const Text('Select Tenant'),
                )
              : Card(
                  child: ListTile(
                    leading: const Icon(Icons.person),
                    title: Text(_selectedTenant!.name),
                    subtitle: Text(_selectedTenant!.email),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit),
                      onPressed: () async {
                        final tenant = await _pickTenant();
                        if (tenant != null) {
                          setState(() {
                            _selectedTenant = tenant;
                          });
                        }
                      },
                    ),
                  ),
                ),
          const SizedBox(height: 24),
          // Unit Selection
          const Text(
            'Select Unit',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          _selectedUnit == null
              ? ElevatedButton.icon(
                  onPressed: () async {
                    final unit = await _pickUnit();
                    if (unit != null) {
                      setState(() {
                        _selectedUnit = unit;
                        _monthlyRent = unit.monthlyRate;
                      });
                    }
                  },
                  icon: const Icon(Icons.home),
                  label: const Text('Select Unit'),
                )
              : Card(
                  child: ListTile(
                    leading: const Icon(Icons.home),
                    title: Text('Unit ${_selectedUnit!.unitNumber}'),
                    subtitle: Text(
                        '\$${_selectedUnit!.monthlyRate.toStringAsFixed(2)}/month'),
                    trailing: IconButton(
                      icon: const Icon(Icons.edit),
                      onPressed: () async {
                        final unit = await _pickUnit();
                        if (unit != null) {
                          setState(() {
                            _selectedUnit = unit;
                            _monthlyRent = unit.monthlyRate;
                          });
                        }
                      },
                    ),
                  ),
                ),
          const SizedBox(height: 24),
          // Move-in Date
          const Text(
            'Move-in Date',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          InkWell(
            onTap: () async {
              final date = await showDatePicker(
                context: context,
                initialDate: _moveInDate,
                firstDate: DateTime.now().subtract(const Duration(days: 30)),
                lastDate: DateTime.now().add(const Duration(days: 365)),
              );
              if (date != null) {
                setState(() {
                  _moveInDate = date;
                });
              }
            },
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Move-in Date',
                suffixIcon: Icon(Icons.calendar_today),
                border: OutlineInputBorder(),
              ),
              child: Text(
                '${_moveInDate.month}/${_moveInDate.day}/${_moveInDate.year}',
              ),
            ),
          ),
        ],
      ),
    );
  }

  Step _buildStep2Financial() {
    return Step(
      title: const Text('Financial Setup'),
      subtitle: const Text('Configure charges and fees'),
      isActive: _currentStep >= 1,
      state: _lineItems.isNotEmpty
          ? StepState.complete
          : _currentStep == 1
              ? StepState.indexed
              : StepState.indexed,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Monthly Rent
          TextFormField(
            initialValue: _monthlyRent.toStringAsFixed(2),
            decoration: const InputDecoration(
              labelText: 'Monthly Rent',
              prefixText: '\$',
              border: OutlineInputBorder(),
            ),
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (value) {
              setState(() {
                _monthlyRent = double.tryParse(value) ?? 0.0;
              });
              _calculateCharges();
            },
          ),
          const SizedBox(height: 16),
          // Prorate Rent Toggle
          CheckboxListTile(
            title: const Text('Prorate Rent'),
            subtitle: const Text(
                'Calculate prorated rent based on move-in date'),
            value: _prorateRent,
            onChanged: (value) {
              setState(() {
                _prorateRent = value ?? true;
              });
              _calculateCharges();
            },
          ),
          const SizedBox(height: 24),
          // Insurance Selection
          const Text(
            'Insurance',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Card(
            child: Column(
              children: [
                RadioListTile<String>(
                  title: _facility?.insuranceSettings != null
                      ? Text('Enroll in Tenant Protection Plan')
                      : const Text('Enroll in Tenant Protection Plan (not configured)'),
                  subtitle: _facility?.insuranceSettings != null
                      ? Text(
                          'Coverage: \$${(_facility!.insuranceSettings!['defaultCoverageAmount'] ?? 5000.0).toStringAsFixed(0)} / Monthly: \$${(_facility!.insuranceSettings!['defaultMonthlyFee'] ?? 15.0).toStringAsFixed(2)}',
                        )
                      : const Text('Please configure TPP settings first'),
                  value: 'tpp',
                  groupValue: _insuranceSelection,
                  onChanged: _facility?.insuranceSettings != null
                      ? (value) {
                          setState(() {
                            _insuranceSelection = value;
                            final settings = _facility!.insuranceSettings!;
                            _insuranceAmount = (settings['defaultMonthlyFee'] ?? 15.0).toDouble();
                          });
                          _calculateCharges();
                        }
                      : null,
                ),
                RadioListTile<String>(
                  title: const Text('I have my own insurance'),
                  subtitle: const Text('Provide proof of insurance later'),
                  value: 'own',
                  groupValue: _insuranceSelection,
                  onChanged: (value) {
                    setState(() {
                      _insuranceSelection = value;
                      _insuranceAmount = null;
                    });
                    _calculateCharges();
                  },
                ),
                RadioListTile<String>(
                  title: const Text('No insurance (auto-enroll later)'),
                  subtitle: const Text('Will be auto-enrolled if Auto-Protect is enabled'),
                  value: 'none',
                  groupValue: _insuranceSelection,
                  onChanged: (value) {
                    setState(() {
                      _insuranceSelection = value;
                      _insuranceAmount = null;
                    });
                    _calculateCharges();
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Optional Fees
          ExpansionTile(
            title: const Text('Optional Fees'),
            children: [
              const SizedBox(height: 16),
              TextFormField(
                initialValue: _adminFee?.toStringAsFixed(2) ?? '',
                decoration: const InputDecoration(
                  labelText: 'Admin Fee',
                  prefixText: '\$',
                  border: OutlineInputBorder(),
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (value) {
                  setState(() {
                    _adminFee = double.tryParse(value);
                  });
                  _calculateCharges();
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                initialValue: _moveInFee?.toStringAsFixed(2) ?? '',
                decoration: const InputDecoration(
                  labelText: 'Move-in Fee',
                  prefixText: '\$',
                  border: OutlineInputBorder(),
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (value) {
                  setState(() {
                    _moveInFee = double.tryParse(value);
                  });
                  _calculateCharges();
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                initialValue: _securityDeposit?.toStringAsFixed(2) ?? '',
                decoration: const InputDecoration(
                  labelText: 'Security Deposit',
                  prefixText: '\$',
                  border: OutlineInputBorder(),
                ),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                onChanged: (value) {
                  setState(() {
                    _securityDeposit = double.tryParse(value);
                  });
                  _calculateCharges();
                },
              ),
            ],
          ),
          const SizedBox(height: 16),
          // Coupon Code
          Row(
            children: [
              Expanded(
                child: TextFormField(
                  initialValue: _couponCode,
                  decoration: InputDecoration(
                    labelText: 'Coupon Code (Optional)',
                    hintText: 'Enter coupon code',
                    border: const OutlineInputBorder(),
                    suffixIcon: _couponCode != null && _couponCode!.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              setState(() {
                                _couponCode = null;
                              });
                              _calculateCharges();
                            },
                          )
                        : null,
                  ),
                  textCapitalization: TextCapitalization.characters,
                  onChanged: (value) {
                    setState(() {
                      _couponCode = value.isEmpty ? null : value.toUpperCase();
                    });
                  },
                  onFieldSubmitted: (value) {
                    if (value.isNotEmpty) {
                      _calculateCharges();
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: () {
                  if (_couponCode != null && _couponCode!.isNotEmpty) {
                    _calculateCharges();
                  }
                },
                child: const Text('Apply'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          // Line Items Summary
          if (_lineItems.isNotEmpty) ...[
            const Text(
              'Charges Summary',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Card(
              child: Column(
                children: [
                  ..._lineItems.map((item) => ListTile(
                        title: Text(item.description),
                        trailing: Text(
                          item.formattedAmount,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: item.amount < 0
                                ? AppTheme.error
                                : AppTheme.textPrimary,
                          ),
                        ),
                        subtitle: item.isProrated
                            ? const Text('Prorated')
                            : null,
                      )),
                  const Divider(),
                  ListTile(
                    title: const Text(
                      'Total',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    trailing: Text(
                      '\$${_totalAmount.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: AppTheme.success,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Step _buildStep3Contract() {
    return Step(
      title: const Text('Contract'),
      subtitle: const Text('Create and sign lease agreement'),
      isActive: _currentStep >= 2,
      state: _contractSigned
          ? StepState.complete
          : _currentStep == 2
              ? StepState.indexed
              : StepState.indexed,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_contract == null)
            ElevatedButton.icon(
              onPressed: () async {
                // Create contract
                try {
                  final contractId = await ContractService.createContract(
                    facilityId: widget.facilityId,
                    tenantId: _selectedTenant!.id,
                    title: 'Storage Lease - ${_selectedUnit!.unitNumber}',
                    description: 'Move-in contract for unit ${_selectedUnit!.unitNumber}',
                    type: ContractType.lease,
                  );
                  final createdContract = await ContractService.getContract(widget.facilityId, contractId);
                  setState(() {
                    _contract = createdContract;
                  });
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Error creating contract: $e'),
                        backgroundColor: AppTheme.error,
                      ),
                    );
                  }
                }
              },
              icon: const Icon(Icons.description),
              label: const Text('Create Contract'),
            )
          else ...[
            Card(
              child: ListTile(
                leading: const Icon(Icons.description),
                title: Text(_contract!.title),
                subtitle: Text('Status: ${_contract!.status.name}'),
                trailing: _contractSigned
                    ? const Icon(Icons.check_circle, color: AppTheme.success)
                    : IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () async {
                          // Navigate to contract signing
                          final signed = await context.push<bool>(
                            '/contracts/sign?contractId=${_contract!.id}',
                          );
                          if (signed == true) {
                            setState(() {
                              _contractSigned = true;
                            });
                          }
                        },
                      ),
              ),
            ),
            const SizedBox(height: 16),
            CheckboxListTile(
              title: const Text('Contract Signed'),
              value: _contractSigned,
              onChanged: (value) {
                setState(() {
                  _contractSigned = value ?? false;
                });
              },
            ),
          ],
        ],
      ),
    );
  }

  Step _buildStep4Payment() {
    return Step(
      title: const Text('Payment'),
      subtitle: const Text('Process move-in payment'),
      isActive: _currentStep >= 3,
      state: _skipPayment || _paymentMethod != null
          ? StepState.complete
          : _currentStep == 3
              ? StepState.indexed
              : StepState.indexed,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Total Amount: \$${_totalAmount.toStringAsFixed(2)}',
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 24),
          // Payment Method Selection
          const Text(
            'Payment Method',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          ...['cash', 'check', 'creditCard', 'ach'].map((method) {
            return RadioListTile<String>(
              title: Text(method == 'creditCard'
                  ? 'Credit Card'
                  : method == 'ach'
                      ? 'ACH/Bank Transfer'
                      : method.toUpperCase()),
              value: method,
              groupValue: _paymentMethod,
              onChanged: (value) {
                setState(() {
                  _paymentMethod = value;
                  _skipPayment = false;
                });
              },
            );
          }),
          const SizedBox(height: 16),
          CheckboxListTile(
            title: const Text('Skip Payment (Process Later)'),
            value: _skipPayment,
            onChanged: (value) {
              setState(() {
                _skipPayment = value ?? false;
                if (_skipPayment) {
                  _paymentMethod = null;
                }
              });
            },
          ),
        ],
      ),
    );
  }

  Step _buildStep5Complete() {
    return Step(
      title: const Text('Complete'),
      subtitle: const Text('Review and finalize move-in'),
      isActive: _currentStep >= 4,
      state: _currentStep == 4 ? StepState.indexed : StepState.indexed,
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_errorMessage != null)
            Card(
              color: AppTheme.error.withOpacity(0.1),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    const Icon(Icons.error, color: AppTheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: AppTheme.error),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          const Text(
            'Review Move-in Details',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.person),
                  title: const Text('Tenant'),
                  trailing: Text(_selectedTenant?.name ?? 'Not selected'),
                ),
                ListTile(
                  leading: const Icon(Icons.home),
                  title: const Text('Unit'),
                  trailing: Text(_selectedUnit?.unitNumber ?? 'Not selected'),
                ),
                ListTile(
                  leading: const Icon(Icons.calendar_today),
                  title: const Text('Move-in Date'),
                  trailing: Text(
                      '${_moveInDate.month}/${_moveInDate.day}/${_moveInDate.year}'),
                ),
                ListTile(
                  leading: const Icon(Icons.attach_money),
                  title: const Text('Total Amount'),
                  trailing: Text(
                    '\$${_totalAmount.toStringAsFixed(2)}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.payment),
                  title: const Text('Payment Method'),
                  trailing: Text(_skipPayment
                      ? 'Skipped'
                      : _paymentMethod?.toUpperCase() ?? 'Not selected'),
                ),
              ],
            ),
          ),
          if (_isLoading) ...[
            const SizedBox(height: 24),
            const Center(child: CircularProgressIndicator()),
          ],
        ],
      ),
    );
  }
}

