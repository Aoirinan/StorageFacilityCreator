import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import '../models/reservation_model.dart';
import '../services/public_rental_service.dart';
import '../models/unit_model.dart';
import '../models/facility_model.dart';
import '../services/public_rental_service.dart';
import '../services/move_in_service.dart';
import '../services/unit_service.dart';
import '../services/facility_service.dart';
import '../services/stripe_service.dart';
import '../models/invoice_line_item_model.dart';
import '../theme/app_theme.dart';
import '../router/app_router.dart';
import 'package:url_launcher/url_launcher.dart';

/// Public-facing move-in wizard for completing reservations
class PublicMoveInScreen extends ConsumerStatefulWidget {
  final String? token;

  const PublicMoveInScreen({
    super.key,
    this.token,
  });

  @override
  ConsumerState<PublicMoveInScreen> createState() => _PublicMoveInScreenState();
}

class _PublicMoveInScreenState extends ConsumerState<PublicMoveInScreen> {
  int _currentStep = 0;
  Reservation? _reservation;
  UnitModel? _unit;
  FacilityModel? _facility;
  bool _isLoading = true;
  String? _error;

  // Form fields
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _addressController = TextEditingController();
  final _emergencyContactController = TextEditingController();
  final _emergencyPhoneController = TextEditingController();

  bool _agreeToTerms = false;
  bool _isSubmitting = false;
  
  // Move-in charges
  List<InvoiceLineItem> _lineItems = [];
  double _totalAmount = 0.0;
  bool _chargesCalculated = false;
  String? _paymentIntentId;

  @override
  void initState() {
    super.initState();
    _loadReservation();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _addressController.dispose();
    _emergencyContactController.dispose();
    _emergencyPhoneController.dispose();
    super.dispose();
  }

  Future<void> _loadReservation() async {
    final token = widget.token;
    if (token == null || token.isEmpty) {
      setState(() {
        _error = 'Invalid move-in link';
        _isLoading = false;
      });
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final reservation = await PublicRentalService.getReservationByToken(token);
      
      if (reservation == null) {
        setState(() {
          _error = 'Reservation not found or has expired';
          _isLoading = false;
        });
        return;
      }

      // Load unit and facility
      if (reservation.unitId == null) {
        setState(() {
          _error = 'Reservation does not have a unit assigned';
          _isLoading = false;
        });
        return;
      }

      final unit = await UnitService.getUnit(
        reservation.facilityId,
        reservation.unitId!,
      );
      
      final facility = await FacilityService.getFacility(reservation.facilityId);

      if (unit == null || facility == null) {
        setState(() {
          _error = 'Unit or facility not found';
          _isLoading = false;
        });
        return;
      }

      // Pre-fill form with reservation data
      if (reservation.name != null) {
        _nameController.text = reservation.name!;
      }
      _emailController.text = reservation.email;
      if (reservation.phone != null) {
        _phoneController.text = reservation.phone!;
      }

      // Calculate move-in charges
      await _calculateCharges();

      setState(() {
        _reservation = reservation;
        _unit = unit;
        _facility = facility;
        _isLoading = false;
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error loading reservation: $e');
      }
      setState(() {
        _error = 'Error loading reservation: $e';
        _isLoading = false;
      });
    }
  }

  Future<void> _calculateCharges() async {
    if (_unit == null || _facility == null || _reservation == null) return;
    
    try {
      final moveInDate = _reservation!.moveInDate ?? DateTime.now();
      
      // Calculate move-in charges
      _lineItems = await MoveInService.calculateMoveInCharges(
        facilityId: _facility!.id,
        unitId: _unit!.id,
        monthlyRent: _unit!.monthlyRate,
        moveInDate: moveInDate,
        prorateRent: true,
        // Note: These fees would typically come from facility settings
        // For now, we'll use defaults or zero
        adminFee: 0.0,
        moveInFee: 0.0,
        securityDeposit: 0.0,
      );
      
      _totalAmount = _lineItems.fold(0.0, (sum, item) => sum + item.amount);
      _chargesCalculated = true;
      
      if (mounted) {
        setState(() {});
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error calculating charges: $e');
      }
      // Continue without charges if calculation fails
      _chargesCalculated = true;
    }
  }

  Future<void> _processPayment() async {
    if (_totalAmount <= 0) {
      // No payment needed, proceed to complete move-in
      await _completeMoveIn();
      return;
    }

    try {
      // Create a public payment checkout session
      // Note: This would need a Cloud Function that creates a payment link for the reservation
      // For now, we'll show a message that payment will be processed
      
      if (mounted) {
        final proceed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Payment Required'),
            content: Text(
              'Total amount due: \$${_totalAmount.toStringAsFixed(2)}\n\n'
              'Payment processing will be integrated with Stripe Connect. '
              'For now, you can proceed and payment will be collected separately.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              ElevatedButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Proceed'),
              ),
            ],
          ),
        );
        
        if (proceed == true) {
          await _completeMoveIn();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error processing payment: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _completeMoveIn() async {
    // Validate required fields
    if (_nameController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter your full name'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }
    
    if (_phoneController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter your phone number'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }
    
    if (_addressController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter your mailing address'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }
    
    if (_emergencyContactController.text.trim().isEmpty || 
        _emergencyPhoneController.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter emergency contact information'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    if (!_agreeToTerms) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please agree to the terms and conditions'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      // Convert line items to map format for Cloud Function
      final lineItemsMap = _lineItems.map((item) => {
        'id': item.id,
        'type': item.type.name,
        'description': item.description,
        'amount': item.amount,
        'isProrated': item.isProrated,
        'dueDate': item.dueDate?.toIso8601String(),
        'metadata': item.metadata,
      }).toList();

      // Call Cloud Function to complete move-in
      final result = await PublicRentalService.completePublicMoveIn(
        reservationId: _reservation!.id,
        token: widget.token ?? '',
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        phone: _phoneController.text.trim(),
        address: _addressController.text.trim(),
        emergencyContactName: _emergencyContactController.text.trim(),
        emergencyContactPhone: _emergencyPhoneController.text.trim(),
        paymentIntentId: _paymentIntentId,
        totalAmount: _totalAmount,
        lineItems: lineItemsMap,
        skipPayment: _totalAmount <= 0,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(result['message'] ?? 'Move-in completed successfully!'),
            backgroundColor: AppTheme.success,
            duration: const Duration(seconds: 5),
          ),
        );
        
        // Navigate to confirmation page
        await Future.delayed(const Duration(seconds: 2));
        if (mounted) {
          context.go('/');
        }
      }
    } catch (e) {
      setState(() {
        _isSubmitting = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error completing move-in: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Complete Your Move-In'),
        backgroundColor: AppTheme.primaryBlueDark,
        foregroundColor: AppTheme.textOnDark,
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline, size: 64, color: AppTheme.error),
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          style: TextStyle(color: AppTheme.error, fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed: () => context.go('/'),
                          child: const Text('Return Home'),
                        ),
                      ],
                    ),
                  ),
                )
              : _reservation == null || _unit == null || _facility == null
                  ? const Center(child: Text('Invalid reservation'))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // Reservation Summary Card
                          Card(
                            color: AppTheme.primaryBlueDark,
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Reservation Summary',
                                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                          color: Colors.white,
                                          fontWeight: FontWeight.bold,
                                        ),
                                  ),
                                  const SizedBox(height: 16),
                                  _buildSummaryRow('Unit', _reservation!.unitNumber ?? _unit!.unitNumber),
                                  _buildSummaryRow('Monthly Rate', '\$${(_reservation!.metadata?['monthlyRate'] as num?)?.toDouble() ?? _unit!.monthlyRate}'),
                                  if (_reservation!.moveInDate != null)
                                    _buildSummaryRow('Desired Move-In', DateFormat('MMM d, y').format(_reservation!.moveInDate!)),
                                  _buildSummaryRow('Facility', _facility!.name),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          // Contact Information Form
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    'Contact Information',
                                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.bold,
                                        ),
                                  ),
                                  const SizedBox(height: 16),
                                  TextFormField(
                                    controller: _nameController,
                                    decoration: const InputDecoration(
                                      labelText: 'Full Name *',
                                      border: OutlineInputBorder(),
                                    ),
                                    readOnly: true, // Pre-filled from reservation
                                  ),
                                  const SizedBox(height: 16),
                                  TextFormField(
                                    controller: _emailController,
                                    decoration: const InputDecoration(
                                      labelText: 'Email Address *',
                                      border: OutlineInputBorder(),
                                    ),
                                    keyboardType: TextInputType.emailAddress,
                                    readOnly: true, // Pre-filled from reservation
                                  ),
                                  const SizedBox(height: 16),
                                  TextFormField(
                                    controller: _phoneController,
                                    decoration: const InputDecoration(
                                      labelText: 'Phone Number *',
                                      border: OutlineInputBorder(),
                                    ),
                                    keyboardType: TextInputType.phone,
                                  ),
                                  const SizedBox(height: 16),
                                  TextFormField(
                                    controller: _addressController,
                                    decoration: const InputDecoration(
                                      labelText: 'Mailing Address *',
                                      border: OutlineInputBorder(),
                                      helperText: 'Where should we send your documents?',
                                    ),
                                    maxLines: 2,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          // Emergency Contact
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    'Emergency Contact',
                                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                          fontWeight: FontWeight.bold,
                                        ),
                                  ),
                                  const SizedBox(height: 16),
                                  TextFormField(
                                    controller: _emergencyContactController,
                                    decoration: const InputDecoration(
                                      labelText: 'Emergency Contact Name *',
                                      border: OutlineInputBorder(),
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  TextFormField(
                                    controller: _emergencyPhoneController,
                                    decoration: const InputDecoration(
                                      labelText: 'Emergency Contact Phone *',
                                      border: OutlineInputBorder(),
                                    ),
                                    keyboardType: TextInputType.phone,
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          // Terms and Conditions
                          Card(
                            child: Padding(
                              padding: const EdgeInsets.all(16),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  CheckboxListTile(
                                    title: const Text('I agree to the terms and conditions'),
                                    subtitle: TextButton(
                                      onPressed: () {
                                        showDialog(
                                          context: context,
                                          builder: (context) => AlertDialog(
                                            title: const Text('Terms and Conditions'),
                                            content: SingleChildScrollView(
                                              child: Column(
                                                crossAxisAlignment: CrossAxisAlignment.start,
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  Text(
                                                    'By completing this move-in, you agree to the following terms and conditions:',
                                                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                                      fontWeight: FontWeight.bold,
                                                    ),
                                                  ),
                                                  const SizedBox(height: 16),
                                                  _buildTermItem('1. Payment Obligations', 'You agree to pay monthly rent on time as specified in your lease agreement. Late fees may apply for overdue payments.'),
                                                  _buildTermItem('2. Insurance Requirements', 'You must maintain appropriate insurance coverage for your stored items. The facility may require proof of insurance.'),
                                                  _buildTermItem('3. Facility Rules', 'You agree to follow all facility rules and regulations, including access hours, prohibited items, and safety requirements.'),
                                                  _buildTermItem('4. Accurate Information', 'You must provide and maintain accurate contact information, including email, phone, and mailing address.'),
                                                  _buildTermItem('5. Access and Security', 'You are responsible for maintaining the security of your unit and access codes. Report any security concerns immediately.'),
                                                  _buildTermItem('6. Prohibited Items', 'You may not store hazardous materials, perishable items, or illegal substances. Violations may result in immediate termination.'),
                                                  _buildTermItem('7. Liability', 'The facility is not responsible for damage to stored items. You are encouraged to maintain your own insurance coverage.'),
                                                  const SizedBox(height: 16),
                                                  Text(
                                                    'Please review the full lease agreement before signing. By proceeding, you acknowledge that you have read and agree to these terms.',
                                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                                      fontStyle: FontStyle.italic,
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.of(context).pop(),
                                                child: const Text('I Understand'),
                                              ),
                                            ],
                                          ),
                                        );
                                      },
                                      child: const Text('View Terms'),
                                    ),
                                    value: _agreeToTerms,
                                    onChanged: (value) {
                                      setState(() {
                                        _agreeToTerms = value ?? false;
                                      });
                                    },
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 24),
                          // Submit Button
                          SizedBox(
                            height: 50,
                            child: ElevatedButton(
                              onPressed: _isSubmitting ? null : _completeMoveIn,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: AppTheme.primaryBlueDark,
                                foregroundColor: Colors.white,
                              ),
                              child: _isSubmitting
                                  ? const SizedBox(
                                      width: 20,
                                      height: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                      ),
                                    )
                                  : const Text(
                                      'Submit Move-In Request',
                                      style: TextStyle(fontSize: 16),
                                    ),
                            ),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            'Note: After submission, our team will review your information and contact you to complete the contract signing and payment process.',
                            style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
    );
  }

  Widget _buildSummaryRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white70),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTermItem(String title, String content) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            content,
            style: const TextStyle(fontSize: 13),
          ),
        ],
      ),
    );
  }
}

