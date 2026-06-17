import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/foundation.dart';
import 'package:intl/intl.dart';
import 'package:signature/signature.dart';
import '../models/reservation_model.dart';
import '../services/public_rental_service.dart';
import '../models/unit_model.dart';
import '../models/facility_model.dart';
import '../services/move_in_service.dart';
import '../services/unit_service.dart';
import '../services/facility_service.dart';
import '../services/facility_public_service.dart';
import '../models/invoice_line_item_model.dart';
import '../theme/app_theme.dart';
import '../router/app_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:cloud_functions/cloud_functions.dart';

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
  final _addressLine2Controller = TextEditingController();
  final _cityController = TextEditingController();
  final _stateController = TextEditingController();
  final _zipCodeController = TextEditingController();
  final _countryController = TextEditingController(text: 'US');
  final _emergencyContactController = TextEditingController();
  final _emergencyRelationshipController = TextEditingController();
  final _emergencyPhoneController = TextEditingController();
  final _emergencyEmailController = TextEditingController();
  final _governmentIdNumberController = TextEditingController();
  final _governmentIdStateController = TextEditingController();
  final _governmentIdCountryController = TextEditingController(text: 'US');
  final _notesController = TextEditingController();
  String _governmentIdType = 'none';
  final SignatureController _signatureController = SignatureController(
    penStrokeWidth: 2,
    penColor: AppTheme.textPrimary,
  );

  bool _agreeToTerms = false;
  bool _enrollAutopayInterest = false;
  bool _isSubmitting = false;
  bool _isLaunchingCheckout = false;
  bool _isVerifyingCheckout = false;
  bool _stripePaymentRequired = false;
  bool _chargeNextMonthAfterMidMonthMoveIn = false;
  bool _chargeInsuranceAtMoveIn = false;
  double? _publicInsuranceAmount;
  bool _chargeSecurityDepositAtMoveIn = false;
  double? _publicSecurityDepositAmount;

  // Move-in charges
  List<InvoiceLineItem> _lineItems = [];
  double _totalAmount = 0.0;
  bool _chargesCalculated = false;
  String? _paymentIntentId;

  double get _effectiveMonthlyRate {
    final reservationRate =
        (_reservation?.metadata?['monthlyRate'] as num?)?.toDouble();
    if (reservationRate != null && reservationRate > 0) {
      return reservationRate;
    }
    return _unit?.monthlyRate ?? 0;
  }

  double _numberFromMap(Map<String, dynamic>? map, List<String> keys) {
    if (map == null) return 0;
    for (final key in keys) {
      final value = map[key];
      if (value is num) return value.toDouble();
      if (value is String) {
        final parsed = double.tryParse(value);
        if (parsed != null) return parsed;
      }
    }
    return 0;
  }

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
    _addressLine2Controller.dispose();
    _cityController.dispose();
    _stateController.dispose();
    _zipCodeController.dispose();
    _countryController.dispose();
    _emergencyContactController.dispose();
    _emergencyRelationshipController.dispose();
    _emergencyPhoneController.dispose();
    _emergencyEmailController.dispose();
    _governmentIdNumberController.dispose();
    _governmentIdStateController.dispose();
    _governmentIdCountryController.dispose();
    _notesController.dispose();
    _signatureController.dispose();
    super.dispose();
  }

  Future<String?> _exportSignaturePngBase64() async {
    final signatureBytes = await _signatureController.toPngBytes();
    if (signatureBytes == null || signatureBytes.isEmpty) {
      return null;
    }
    return base64Encode(signatureBytes);
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
      final reservation =
          await PublicRentalService.getReservationByToken(token);

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

      final facility =
          await FacilityService.getFacility(reservation.facilityId);
      final publicSettings =
          await FacilityPublicService.getPublicSettings(reservation.facilityId);

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

      setState(() {
        _reservation = reservation;
        _unit = unit;
        _facility = facility;
        _chargeNextMonthAfterMidMonthMoveIn =
            publicSettings?.chargeNextMonthAfterMidMonthMoveIn ?? false;
        _chargeInsuranceAtMoveIn =
            publicSettings?.chargeInsuranceAtMoveIn ?? false;
        _publicInsuranceAmount = publicSettings?.publicInsuranceAmount;
        _chargeSecurityDepositAtMoveIn =
            publicSettings?.chargeSecurityDepositAtMoveIn ?? false;
        _publicSecurityDepositAmount =
            publicSettings?.publicSecurityDepositAmount;
      });
      await _calculateCharges();
      await _handleCheckoutReturnIfPresent();

      setState(() {
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
      final billing = _facility?.billingSettings;
      final adminFee = _numberFromMap(
        billing,
        const ['adminFee', 'admin_fee', 'newTenantAdminFee'],
      );
      final moveInFee = _numberFromMap(
        billing,
        const ['moveInFee', 'move_in_fee'],
      );
      final fallbackDeposit = (_unit?.securityDeposit ?? 0) > 0
          ? (_unit?.securityDeposit ?? 0)
          : _numberFromMap(
              billing,
              const ['securityDeposit', 'security_deposit', 'depositAmount'],
            );
      final securityDeposit = _chargeSecurityDepositAtMoveIn
          ? ((_publicSecurityDepositAmount ?? 0) > 0
              ? (_publicSecurityDepositAmount ?? 0)
              : fallbackDeposit)
          : 0.0;
      final insuranceAmount =
          _chargeInsuranceAtMoveIn && (_publicInsuranceAmount ?? 0) > 0
              ? (_publicInsuranceAmount ?? 0)
              : 0.0;

      // Calculate move-in charges
      _lineItems = await MoveInService.calculateMoveInCharges(
        facilityId: _facility!.id,
        unitId: _unit!.id,
        monthlyRent: _effectiveMonthlyRate,
        moveInDate: moveInDate,
        prorateRent: true,
        insuranceAmount: insuranceAmount > 0 ? insuranceAmount : null,
        adminFee: adminFee > 0 ? adminFee : 0.0,
        moveInFee: moveInFee > 0 ? moveInFee : 0.0,
        securityDeposit: securityDeposit > 0 ? securityDeposit : 0.0,
      );

      // Optional pricing rule: if move-in is after mid-month, charge next month too.
      if (_chargeNextMonthAfterMidMonthMoveIn && _effectiveMonthlyRate > 0) {
        final daysInMonth =
            DateTime(moveInDate.year, moveInDate.month + 1, 0).day;
        final isAfterHalfway = moveInDate.day > (daysInMonth / 2).floor();
        if (isAfterHalfway) {
          final nextMonth = DateTime(moveInDate.year, moveInDate.month + 1, 1);
          _lineItems.add(
            InvoiceLineItem(
              id: 'next_month_rent_${DateTime.now().millisecondsSinceEpoch}',
              type: InvoiceLineItemType.rent,
              description:
                  'Next Month Rent (${DateFormat('MMM yyyy').format(nextMonth)})',
              amount: _effectiveMonthlyRate,
              isProrated: false,
              dueDate: nextMonth,
            ),
          );
        }
      }

      _totalAmount = _lineItems.fold(0.0, (sum, item) => sum + item.amount);
      _chargesCalculated = true;
      _stripePaymentRequired =
          (_facility?.stripeConnectAccountId?.isNotEmpty ?? false) &&
              (_facility?.canAcceptTenantPayments ?? false) &&
              _totalAmount > 0;

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

  Future<void> _handleCheckoutReturnIfPresent() async {
    final reservation = _reservation;
    final token = widget.token;
    if (reservation == null || token == null || token.isEmpty) return;
    final qp = <String, String>{
      ...Uri.base.queryParameters,
    };
    final fragment = Uri.base.fragment;
    if (fragment.contains('?')) {
      final queryPart = fragment.split('?').last;
      qp.addAll(Uri.splitQueryString(queryPart));
    }
    final checkoutState = qp['checkout'];
    final sessionId = qp['session_id'];
    final reservationIdParam = qp['reservationId'];
    if (reservationIdParam != null &&
        reservationIdParam.isNotEmpty &&
        reservationIdParam != reservation.id) {
      return;
    }
    if (checkoutState == 'cancel') {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Payment was canceled. You can try again.'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }
    if (checkoutState != 'success' ||
        sessionId == null ||
        sessionId.trim().isEmpty) {
      return;
    }
    try {
      setState(() => _isVerifyingCheckout = true);
      final result = await PublicRentalService.confirmPublicMoveInCheckout(
        reservationId: reservation.id,
        token: token,
        sessionId: sessionId,
      );
      final paymentIntentId = result['paymentIntentId']?.toString();
      if (paymentIntentId == null || paymentIntentId.isEmpty) {
        throw Exception('Payment intent missing from checkout confirmation.');
      }
      if (!mounted) return;
      setState(() {
        _paymentIntentId = paymentIntentId;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Payment verified. You can now submit move-in.'),
          backgroundColor: AppTheme.success,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Payment verification failed: $e'),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isVerifyingCheckout = false);
      }
    }
  }

  Future<void> _startCheckout() async {
    final reservation = _reservation;
    final token = widget.token;
    if (reservation == null || token == null || token.isEmpty) return;
    try {
      setState(() => _isLaunchingCheckout = true);
      final result = await PublicRentalService.createPublicMoveInCheckout(
        reservationId: reservation.id,
        token: token,
        amount: _totalAmount,
        description: 'Move-in payment for ${_facility?.name ?? 'Facility'}',
      );
      final checkoutUrl = result['checkoutUrl']?.toString();
      if (checkoutUrl == null || checkoutUrl.isEmpty) {
        throw Exception('Checkout URL not returned.');
      }
      final uri = Uri.parse(checkoutUrl);
      final launched = await launchUrl(uri);
      if (!launched) {
        throw Exception('Unable to open Stripe Checkout.');
      }
    } catch (e) {
      if (!mounted) return;
      final detail = e is FirebaseFunctionsException &&
              e.message != null &&
              e.message!.trim().isNotEmpty
          ? e.message!.trim()
          : e.toString();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to start payment: $detail'),
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _isLaunchingCheckout = false);
      }
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

    if (_signatureController.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please provide your electronic signature'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    if (_stripePaymentRequired &&
        _totalAmount > 0 &&
        _paymentIntentId == null) {
      await _startCheckout();
      return;
    }

    setState(() {
      _isSubmitting = true;
    });

    try {
      final signaturePngBase64 = await _exportSignaturePngBase64();
      if (signaturePngBase64 == null || signaturePngBase64.isEmpty) {
        throw Exception('Unable to capture signature. Please sign again.');
      }

      // Convert line items to map format for Cloud Function
      final lineItemsMap = _lineItems
          .map((item) => {
                'id': item.id,
                'type': item.type.name,
                'description': item.description,
                'amount': item.amount,
                'isProrated': item.isProrated,
                'dueDate': item.dueDate?.toIso8601String(),
                'metadata': item.metadata,
              })
          .toList();

      // Call Cloud Function to complete move-in
      final result = await PublicRentalService.completePublicMoveIn(
        reservationId: _reservation!.id,
        token: widget.token ?? '',
        name: _nameController.text.trim(),
        email: _emailController.text.trim(),
        phone: _phoneController.text.trim(),
        address: _addressController.text.trim(),
        addressLine2: _addressLine2Controller.text.trim(),
        city: _cityController.text.trim(),
        state: _stateController.text.trim(),
        zipCode: _zipCodeController.text.trim(),
        country: _countryController.text.trim(),
        emergencyContactName: _emergencyContactController.text.trim(),
        emergencyContactRelationship:
            _emergencyRelationshipController.text.trim(),
        emergencyContactPhone: _emergencyPhoneController.text.trim(),
        emergencyContactEmail: _emergencyEmailController.text.trim(),
        governmentIdType:
            _governmentIdType == 'none' ? null : _governmentIdType,
        governmentIdNumber: _governmentIdNumberController.text.trim(),
        governmentIdState: _governmentIdStateController.text.trim(),
        governmentIdCountry: _governmentIdCountryController.text.trim(),
        notes: _notesController.text.trim(),
        paymentIntentId: _paymentIntentId,
        totalAmount: _totalAmount,
        lineItems: lineItemsMap,
        skipPayment: !(_stripePaymentRequired && _totalAmount > 0),
        signaturePngBase64: signaturePngBase64,
        signatureSignedAt: DateTime.now().toIso8601String(),
        enrollAutopayInterest: _enrollAutopayInterest,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(result['message'] ?? 'Move-in completed successfully!'),
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
            content: Text(_moveInSubmitErrorMessage(e)),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  String _moveInSubmitErrorMessage(Object e) {
    if (e is FirebaseFunctionsException) {
      final msg = (e.message ?? '').toLowerCase();
      if (e.code == 'failed-precondition' &&
          (msg.contains('no longer available') ||
              msg.contains('not currently available'))) {
        return 'That unit is no longer available for online move-in. '
            'Return to the facility rental page, refresh, and choose another unit, or call the facility for help.';
      }
      if (e.message != null && e.message!.trim().isNotEmpty) {
        return e.message!;
      }
    }
    return 'Error completing move-in: $e';
  }

  @override
  Widget build(BuildContext context) {
    const teal = Color(0xFF0F7669);
    const inkDark = Color(0xFF0F172A);
    const muted = Color(0xFF64748B);
    const lineBorder = Color(0xFFE2E8F0);
    const bgPage = Color(0xFFF4F6F8);

    final inputDecor = InputDecoration(
      filled: true,
      fillColor: Colors.white,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: lineBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: lineBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: const BorderSide(color: teal, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );

    return Scaffold(
      backgroundColor: bgPage,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: teal))
          : _error != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.error_outline,
                            size: 64, color: AppTheme.error),
                        const SizedBox(height: 16),
                        Text(
                          _error!,
                          style: TextStyle(color: AppTheme.error, fontSize: 16),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 24),
                        ElevatedButton(
                          onPressed: () => context.go('/'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: teal,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(999),
                            ),
                          ),
                          child: const Text('Return Home'),
                        ),
                      ],
                    ),
                  ),
                )
              : _reservation == null || _unit == null || _facility == null
                  ? const Center(child: Text('Invalid reservation'))
                  : Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 720),
                        child: SingleChildScrollView(
                          padding: const EdgeInsets.fromLTRB(22, 32, 22, 40),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Complete Your Move-In',
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w800,
                                  color: inkDark,
                                  letterSpacing: -0.6,
                                ),
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Review your reservation and fill in the details below.',
                                style: TextStyle(color: muted, fontSize: 15, height: 1.4),
                              ),
                              const SizedBox(height: 22),
                              Container(
                                padding: const EdgeInsets.all(18),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    begin: Alignment.topLeft,
                                    end: Alignment.bottomRight,
                                    colors: [Color(0xFF134E4A), teal],
                                  ),
                                  borderRadius: BorderRadius.circular(16),
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Color(0x280F172A),
                                      blurRadius: 24,
                                      offset: Offset(0, 8),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    const Text(
                                      'Reservation Summary',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 17,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                    const SizedBox(height: 14),
                                    _buildSummaryRow(
                                        'Unit',
                                        _reservation!.unitNumber ??
                                            _unit!.unitNumber),
                                    _buildSummaryRow('Monthly Rate',
                                        '\$${_effectiveMonthlyRate.toStringAsFixed(2)}'),
                                    if (_reservation!.moveInDate != null)
                                      _buildSummaryRow(
                                          'Desired Move-In',
                                          DateFormat('MMM d, y').format(
                                              _reservation!.moveInDate!)),
                                    _buildSummaryRow(
                                        'Facility', _facility!.name),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                              _buildChargesCard(),
                              const SizedBox(height: 22),
                              _buildFormSection(
                                title: 'Contact Information',
                                children: [
                                  TextFormField(
                                    controller: _nameController,
                                    decoration: inputDecor.copyWith(
                                      labelText: 'Full Name *',
                                    ),
                                    readOnly: true,
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _emailController,
                                    decoration: inputDecor.copyWith(
                                      labelText: 'Email Address *',
                                    ),
                                    keyboardType: TextInputType.emailAddress,
                                    readOnly: true,
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _phoneController,
                                    decoration: inputDecor.copyWith(
                                      labelText: 'Phone Number *',
                                    ),
                                    keyboardType: TextInputType.phone,
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _addressController,
                                    decoration: inputDecor.copyWith(
                                      labelText: 'Mailing Address *',
                                      helperText: 'Where should we send your documents?',
                                    ),
                                    maxLines: 2,
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _addressLine2Controller,
                                    decoration: inputDecor.copyWith(
                                      labelText: 'Address Line 2',
                                    ),
                                  ),
                                  const SizedBox(height: 14),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextFormField(
                                          controller: _cityController,
                                          decoration: inputDecor.copyWith(
                                            labelText: 'City',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: TextFormField(
                                          controller: _stateController,
                                          decoration: inputDecor.copyWith(
                                            labelText: 'State',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 14),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextFormField(
                                          controller: _zipCodeController,
                                          decoration: inputDecor.copyWith(
                                            labelText: 'ZIP Code',
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: TextFormField(
                                          controller: _countryController,
                                          decoration: inputDecor.copyWith(
                                            labelText: 'Country',
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              _buildFormSection(
                                title: 'Government ID (optional)',
                                children: [
                                  DropdownButtonFormField<String>(
                                    value: _governmentIdType,
                                    decoration: inputDecor.copyWith(
                                      labelText: 'ID Type',
                                    ),
                                    borderRadius: BorderRadius.circular(12),
                                    items: const [
                                      DropdownMenuItem(value: 'none', child: Text('None')),
                                      DropdownMenuItem(value: 'driversLicense', child: Text('Driver License')),
                                      DropdownMenuItem(value: 'stateId', child: Text('State ID')),
                                      DropdownMenuItem(value: 'passport', child: Text('Passport')),
                                      DropdownMenuItem(value: 'other', child: Text('Other')),
                                    ],
                                    onChanged: (value) {
                                      setState(() => _governmentIdType = value ?? 'none');
                                    },
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _governmentIdNumberController,
                                    decoration: inputDecor.copyWith(labelText: 'ID Number'),
                                  ),
                                  const SizedBox(height: 14),
                                  Row(
                                    children: [
                                      Expanded(
                                        child: TextFormField(
                                          controller: _governmentIdStateController,
                                          decoration: inputDecor.copyWith(labelText: 'ID Issuing State'),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: TextFormField(
                                          controller: _governmentIdCountryController,
                                          decoration: inputDecor.copyWith(labelText: 'ID Issuing Country'),
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              _buildFormSection(
                                title: 'Emergency Contact',
                                children: [
                                  TextFormField(
                                    controller: _emergencyContactController,
                                    decoration: inputDecor.copyWith(labelText: 'Emergency Contact Name *'),
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _emergencyRelationshipController,
                                    decoration: inputDecor.copyWith(labelText: 'Emergency Contact Relationship'),
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _emergencyPhoneController,
                                    decoration: inputDecor.copyWith(labelText: 'Emergency Contact Phone *'),
                                    keyboardType: TextInputType.phone,
                                  ),
                                  const SizedBox(height: 14),
                                  TextFormField(
                                    controller: _emergencyEmailController,
                                    decoration: inputDecor.copyWith(labelText: 'Emergency Contact Email'),
                                    keyboardType: TextInputType.emailAddress,
                                  ),
                                ],
                              ),
                              _buildFormSection(
                                title: 'Additional Notes (optional)',
                                children: [
                                  TextFormField(
                                    controller: _notesController,
                                    decoration: inputDecor.copyWith(labelText: 'Notes'),
                                    maxLines: 3,
                                  ),
                                ],
                              ),
                              _buildFormSection(
                                title: 'Electronic Signature',
                                children: [
                                  if (_reservation?.onlineMoveInLeaseUrl != null &&
                                      _reservation!.onlineMoveInLeaseUrl!.isNotEmpty) ...[
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: TextButton.icon(
                                        onPressed: () async {
                                          final raw =
                                              _reservation!.onlineMoveInLeaseUrl!;
                                          final uri = Uri.tryParse(raw);
                                          if (uri != null &&
                                              await canLaunchUrl(uri)) {
                                            await launchUrl(
                                              uri,
                                              mode: LaunchMode
                                                  .externalApplication,
                                            );
                                          }
                                        },
                                        icon: const Icon(
                                          Icons.picture_as_pdf_outlined,
                                          size: 18,
                                        ),
                                        label: Text(
                                          'Review ${_reservation!.onlineMoveInLeaseTitle ?? 'lease agreement'} (PDF)',
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                  ],
                                  Text(
                                    _reservation?.onlineMoveInLeaseUrl != null &&
                                            _reservation!
                                                .onlineMoveInLeaseUrl!.isNotEmpty
                                        ? 'Sign below to acknowledge the lease you reviewed and complete your move-in.'
                                        : 'Sign below to acknowledge and sign your move-in agreement.',
                                    style: const TextStyle(
                                        color: muted, fontSize: 14, height: 1.4),
                                  ),
                                  const SizedBox(height: 12),
                                  Container(
                                    decoration: BoxDecoration(
                                      color: Colors.white,
                                      border: Border.all(color: lineBorder),
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(12),
                                      child: Signature(
                                        controller: _signatureController,
                                        height: 180,
                                        backgroundColor: Colors.white,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Align(
                                    alignment: Alignment.centerRight,
                                    child: TextButton.icon(
                                      onPressed: () => setState(() => _signatureController.clear()),
                                      icon: const Icon(Icons.clear, size: 16),
                                      label: const Text('Clear Signature'),
                                      style: TextButton.styleFrom(foregroundColor: muted),
                                    ),
                                  ),
                                ],
                              ),
                              _buildFormSection(
                                title: 'Terms & Conditions',
                                children: [
                                  CheckboxListTile(
                                    title: const Text('I agree to the terms and conditions'),
                                    subtitle: TextButton(
                                      onPressed: () {
                                            showDialog(
                                              context: context,
                                              builder: (context) => AlertDialog(
                                                title: const Text(
                                                    'Terms and Conditions'),
                                                content: SingleChildScrollView(
                                                  child: Column(
                                                    crossAxisAlignment:
                                                        CrossAxisAlignment
                                                            .start,
                                                    mainAxisSize:
                                                        MainAxisSize.min,
                                                    children: [
                                                      Text(
                                                        'By completing this move-in, you agree to the following terms and conditions:',
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .titleSmall
                                                            ?.copyWith(
                                                              fontWeight:
                                                                  FontWeight
                                                                      .bold,
                                                            ),
                                                      ),
                                                      const SizedBox(
                                                          height: 16),
                                                      _buildTermItem(
                                                          '1. Payment Obligations',
                                                          'You agree to pay monthly rent on time as specified in your lease agreement. Late fees may apply for overdue payments.'),
                                                      _buildTermItem(
                                                          '2. Insurance Requirements',
                                                          'You must maintain appropriate insurance coverage for your stored items. The facility may require proof of insurance.'),
                                                      _buildTermItem(
                                                          '3. Facility Rules',
                                                          'You agree to follow all facility rules and regulations, including access hours, prohibited items, and safety requirements.'),
                                                      _buildTermItem(
                                                          '4. Accurate Information',
                                                          'You must provide and maintain accurate contact information, including email, phone, and mailing address.'),
                                                      _buildTermItem(
                                                          '5. Access and Security',
                                                          'You are responsible for maintaining the security of your unit and access codes. Report any security concerns immediately.'),
                                                      _buildTermItem(
                                                          '6. Prohibited Items',
                                                          'You may not store hazardous materials, perishable items, or illegal substances. Violations may result in immediate termination.'),
                                                      _buildTermItem(
                                                          '7. Liability',
                                                          'The facility is not responsible for damage to stored items. You are encouraged to maintain your own insurance coverage.'),
                                                      const SizedBox(
                                                          height: 16),
                                                      Text(
                                                        'Please review the full lease agreement before signing. By proceeding, you acknowledge that you have read and agree to these terms.',
                                                        style: Theme.of(context)
                                                            .textTheme
                                                            .bodySmall
                                                            ?.copyWith(
                                                              fontStyle:
                                                                  FontStyle
                                                                      .italic,
                                                            ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                                actions: [
                                                  TextButton(
                                                    onPressed: () =>
                                                        Navigator.of(context)
                                                            .pop(),
                                                    child: const Text(
                                                        'I Understand'),
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
                                  CheckboxListTile(
                                    title: const Text(
                                      'Sign me up for automatic monthly draft (autopay)',
                                    ),
                                    subtitle: const Text(
                                      'We will request autopay on your account. The facility may contact you to confirm your card on file before charges run.',
                                      style: TextStyle(color: muted, fontSize: 12),
                                    ),
                                    value: _enrollAutopayInterest,
                                    onChanged: (value) {
                                      setState(() => _enrollAutopayInterest = value ?? false);
                                    },
                                  ),
                                ],
                              ),
                              const SizedBox(height: 24),
                              SizedBox(
                                height: 52,
                                child: ElevatedButton(
                                  onPressed: (_isSubmitting ||
                                          _isLaunchingCheckout ||
                                          _isVerifyingCheckout)
                                      ? null
                                      : _completeMoveIn,
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: inkDark,
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    elevation: 0,
                                  ),
                                  child: (_isSubmitting ||
                                          _isLaunchingCheckout ||
                                          _isVerifyingCheckout)
                                      ? const SizedBox(
                                          width: 20,
                                          height: 20,
                                          child: CircularProgressIndicator(
                                            strokeWidth: 2,
                                            valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                                          ),
                                        )
                                      : Text(
                                          (_stripePaymentRequired &&
                                                  _totalAmount > 0 &&
                                                  _paymentIntentId == null)
                                              ? 'Pay and Submit Move-In'
                                              : 'Submit Move-In Request',
                                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                                        ),
                                ),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                (_stripePaymentRequired && _totalAmount > 0)
                                    ? 'Payment is required today to complete this move-in.'
                                    : 'After submission, our team will review your information and finalize your move-in.',
                                style: const TextStyle(
                                  color: muted,
                                  fontSize: 13,
                                  fontStyle: FontStyle.italic,
                                ),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
    );
  }

  Widget _buildFormSection({required String title, required List<Widget> children}) {
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x080F172A),
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: Color(0xFF0F172A),
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 14),
          ...children,
        ],
      ),
    );
  }

  Widget _buildChargesCard() {
    final currency = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFFE2E8F0)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x080F172A),
            blurRadius: 14,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.receipt_long_outlined,
                  size: 18, color: Color(0xFF0F7669)),
              const SizedBox(width: 8),
              const Text(
                'Due Today',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 17,
                  color: Color(0xFF0F172A),
                ),
              ),
              const Spacer(),
              Text(
                currency.format(_totalAmount),
                style: const TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 20,
                  color: Color(0xFF0F172A),
                  letterSpacing: -0.3,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (_lineItems.isEmpty)
            const Text(
              'No charges were calculated.',
              style: TextStyle(color: Color(0xFF64748B), fontSize: 14),
            )
          else
            ..._lineItems.map(
              (item) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.description,
                        style: const TextStyle(fontSize: 14, color: Color(0xFF334155)),
                      ),
                    ),
                    Text(
                      currency.format(item.amount),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF0F172A),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
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
