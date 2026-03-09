import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'dart:math';
import '../models/dnr_model.dart';
import '../providers/auth_provider.dart';
import '../providers/dnr_provider.dart';
import '../services/dnr_service.dart';
import '../services/facility_service.dart';
import '../providers/facility_provider.dart';
import '../providers/tenant_provider.dart';
import '../models/tenant_model.dart';
import '../services/email_service.dart';
import '../theme/app_theme.dart';
import 'package:flutter/foundation.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';

class DNREntryScreen extends ConsumerStatefulWidget {
  final DNRModel? dnrEntry;
  final String? facilityId;
  
  const DNREntryScreen({super.key, this.dnrEntry, this.facilityId});

  @override
  ConsumerState<DNREntryScreen> createState() => _DNREntryScreenState();
}

class _DNREntryScreenState extends ConsumerState<DNREntryScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _reasonController = TextEditingController();
  final _notesController = TextEditingController();

  // Removed DNRSeverity and DNRScope - using simple boolean for active status
  bool _isActive = true;
  bool _isLoading = false;
  String? _errorMessage;
  String? _selectedFacilityId;
  DateTime? _expiresAt;
  String? _selectedTenantId;
  String? _linkedTenantName;
  
  // New required fields for DNR
  String? _facilityName;
  String? _ownerEmail;
  String? _facilityPhone;
  String? _addedByName;
  String? _addedByEmail;
  bool _isSendingVerification = false;
  bool _verificationSent = false;
  bool _verificationSuccessful = false;
  String? _generatedVerificationCode;
  String? _verificationError;
  final TextEditingController _verificationCodeController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selectedFacilityId = widget.facilityId;
    if (widget.dnrEntry != null) {
      _populateFields();
    }
    _loadFacilityInfo(facilityId: _selectedFacilityId);
  }
  
  Future<void> _loadFacilityInfo({String? facilityId}) async {
    final targetFacilityId = facilityId ?? _selectedFacilityId;
    if (targetFacilityId == null || targetFacilityId.isEmpty) {
      if (mounted) {
        setState(() {
          _facilityName = null;
          _ownerEmail = null;
          _facilityPhone = null;
        });
      }
      return;
    }

    try {
      final facilities = await FacilityService.getUserFacilities();
      final facility = facilities.firstWhere(
        (f) => f.id == targetFacilityId,
        orElse: () => throw Exception('Facility not found: $targetFacilityId'),
      );

      final authState = ref.read(authStateProvider);
      await authState.whenData((user) async {
        if (user != null) {
          final userEmail = user.email ?? 'No email available';
          final userDisplayName = await DNRService.getUserDisplayName(user.uid, userEmail);
          if (kDebugMode) {
            print('🔄 Loading facility info:');
            print('  Facility Name: ${facility.name}');
            print('  Facility Email: ${facility.email}');
            print('  Facility Phone: ${facility.phone}');
            print('  User Email: $userEmail');
            print('  User Display Name: $userDisplayName');
          }
          if (mounted) {
            setState(() {
              _selectedFacilityId = targetFacilityId;
              _facilityName = facility.name;
              _ownerEmail = facility.email ?? '';
              _facilityPhone = facility.phone ?? 'No phone available';
              _addedByName = userDisplayName;
              _addedByEmail = userEmail;
            });
            if (kDebugMode) {
              print('✅ Facility info loaded successfully');
            }
          }
        }
      });
    } catch (e) {
      if (kDebugMode) {
        print('Error loading facility info: $e');
      }
    }
  }

  Future<void> _sendVerificationCode() async {
    // Validate form first to ensure all details are filled
    if (!_formKey.currentState!.validate()) {
      setState(() {
        _verificationError = 'Please fill in all required fields before sending verification.';
      });
      return;
    }

    final facilityId = _selectedFacilityId;
    if (facilityId == null || facilityId.isEmpty) {
      setState(() {
        _verificationError = 'Select a facility before sending verification.';
      });
      return;
    }

    final facilityEmail = _ownerEmail;
    if (facilityEmail == null || facilityEmail.isEmpty) {
      setState(() {
        _verificationError = 'Facility email is missing. Update facility details before continuing.';
      });
      return;
    }

    setState(() {
      _isSendingVerification = true;
      _verificationError = null;
    });

    final code = (Random.secure().nextInt(900000) + 100000).toString();
    
    // Get all DNR details from form
    final dnrName = _nameController.text.trim();
    final dnrEmail = _emailController.text.trim();
    final dnrPhone = _phoneController.text.trim();
    final reason = _reasonController.text.trim();
    final facilityName = _facilityName ?? 'Unknown Facility';
    final expiresText = _expiresAt != null
        ? _expiresAt!.toLocal().toString().split(' ')[0]
        : 'No expiration';
    final activeStatus = _isActive ? 'Active' : 'Inactive';

    try {
      final subject = 'DNR Verification Code - $dnrName';
      
      final text = '''
A Do Not Rent (DNR) entry has been requested for your facility.

VERIFICATION CODE: $code

Please enter this code in the application to confirm the DNR entry.

---
DNR ENTRY DETAILS:
---
Name: $dnrName
Email: ${dnrEmail.isNotEmpty ? dnrEmail : 'Not provided'}
Phone: ${dnrPhone.isNotEmpty ? dnrPhone : 'Not provided'}
Reason: $reason
Status: $activeStatus
Expires: $expiresText

---
FACILITY INFORMATION:
---
Facility: $facilityName
Facility Email: $facilityEmail

---
VERIFICATION CODE: $code

Enter this code in the SFC App to complete the DNR entry creation.
''';

      final html = '''
<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>DNR Verification Code</title>
</head>
<body style="font-family: Arial, sans-serif; line-height: 1.6; color: #333; max-width: 600px; margin: 0 auto; padding: 20px;">
  <div style="background-color: #f8f9fa; padding: 20px; border-radius: 8px; margin-bottom: 20px;">
    <h2 style="color: #dc3545; margin-top: 0;">🚫 DNR Verification Required</h2>
    <p>A <strong>Do Not Rent (DNR)</strong> entry has been requested for your facility.</p>
  </div>

  <div style="background-color: #fff3cd; border-left: 4px solid #ffc107; padding: 20px; margin-bottom: 20px; text-align: center;">
    <h1 style="color: #856404; margin: 0; font-size: 36px; letter-spacing: 5px;">$code</h1>
    <p style="color: #856404; margin: 10px 0 0 0; font-weight: bold;">Enter this code in the application to confirm the DNR entry.</p>
  </div>

  <div style="background-color: #ffffff; border: 1px solid #dee2e6; padding: 20px; border-radius: 8px; margin-bottom: 20px;">
    <h3 style="color: #495057; margin-top: 0; border-bottom: 2px solid #dee2e6; padding-bottom: 10px;">DNR Entry Details</h3>
    <table style="width: 100%; border-collapse: collapse;">
      <tr>
        <td style="padding: 8px 0; font-weight: bold; width: 140px;">Name:</td>
        <td style="padding: 8px 0;">$dnrName</td>
      </tr>
      ${dnrEmail.isNotEmpty ? '<tr><td style="padding: 8px 0; font-weight: bold;">Email:</td><td style="padding: 8px 0;">$dnrEmail</td></tr>' : ''}
      ${dnrPhone.isNotEmpty ? '<tr><td style="padding: 8px 0; font-weight: bold;">Phone:</td><td style="padding: 8px 0;">$dnrPhone</td></tr>' : ''}
      <tr>
        <td style="padding: 8px 0; font-weight: bold; vertical-align: top;">Reason:</td>
        <td style="padding: 8px 0;">$reason</td>
      </tr>
      <tr>
        <td style="padding: 8px 0; font-weight: bold;">Status:</td>
        <td style="padding: 8px 0;">$activeStatus</td>
      </tr>
      <tr>
        <td style="padding: 8px 0; font-weight: bold;">Expires:</td>
        <td style="padding: 8px 0;">$expiresText</td>
      </tr>
    </table>
  </div>

  <div style="background-color: #e7f3ff; border-left: 4px solid #0066cc; padding: 15px; margin-bottom: 20px;">
    <h3 style="color: #004085; margin-top: 0; border-bottom: 2px solid #004085; padding-bottom: 10px;">Facility Information</h3>
    <p style="margin: 5px 0;"><strong>Facility:</strong> $facilityName</p>
    <p style="margin: 5px 0;"><strong>Facility Email:</strong> $facilityEmail</p>
  </div>

  <div style="background-color: #fff3cd; border-left: 4px solid #ffc107; padding: 20px; text-align: center; border-radius: 4px;">
    <p style="margin: 0; color: #856404; font-size: 18px; font-weight: bold;">VERIFICATION CODE</p>
    <p style="margin: 10px 0 0 0; color: #856404; font-size: 28px; letter-spacing: 8px; font-weight: bold;">$code</p>
    <p style="margin: 15px 0 0 0; color: #856404;">Enter this code in the SFC App to complete the DNR entry creation.</p>
  </div>

  <div style="margin-top: 30px; padding-top: 20px; border-top: 1px solid #dee2e6; text-align: center; color: #6c757d; font-size: 12px;">
    <p>This is an automated verification email from SFC App - Storage Facility Creator</p>
  </div>
</body>
</html>
''';

      final result = await EmailService.sendEmail(
        to: facilityEmail,
        subject: subject,
        text: text,
        html: html,
        facilityId: facilityId,
      );

      if (!result.success) {
        throw Exception(result.error ?? 'Unknown error sending verification email');
      }

      if (mounted) {
        setState(() {
          _generatedVerificationCode = code;
          _verificationSent = true;
          _verificationSuccessful = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Verification code sent to $facilityEmail with all DNR details'),
            backgroundColor: AppTheme.success,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Failed to send DNR verification email: $e');
      }
      if (mounted) {
        setState(() {
          _verificationError = 'Failed to send verification code: $e';
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSendingVerification = false;
        });
      }
    }
  }

  void _confirmVerificationCode() {
    final expected = _generatedVerificationCode;
    final entered = _verificationCodeController.text.trim();

    if (expected == null) {
      setState(() {
        _verificationError = 'Send a verification code first.';
      });
      return;
    }

    if (entered.isEmpty) {
      setState(() {
        _verificationError = 'Enter the verification code that was sent to the facility.';
      });
      return;
    }

    if (entered == expected) {
      setState(() {
        _verificationSuccessful = true;
        _verificationError = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Facility ownership verified successfully.'),
          backgroundColor: AppTheme.success,
        ),
      );
    } else {
      setState(() {
        _verificationSuccessful = false;
        _verificationError = 'Verification code does not match. Please try again.';
      });
    }
  }

  void _populateFields() {
    final entry = widget.dnrEntry!;
    _nameController.text = entry.name;
    _emailController.text = entry.email;
    _phoneController.text = entry.phone;
    _reasonController.text = entry.reason;
    _notesController.text = '';
    _isActive = entry.active;
    _expiresAt = entry.expiresAt;
    _selectedFacilityId = entry.facilityId;
    _selectedTenantId = entry.linkedTenantId;
    _linkedTenantName = entry.linkedTenantName;
    _verificationSuccessful = true;
    _verificationSent = true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _reasonController.dispose();
    _notesController.dispose();
    _verificationCodeController.dispose();
    super.dispose();
  }

  Future<void> _saveDNR() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final authState = ref.read(authStateProvider);
      final user = authState.value;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      // Get facility info if not provided
      String facilityId = _selectedFacilityId ?? '';
      String facilityName = '';
      String facilityEmail = '';
      String facilityPhone = '';

      if (facilityId.isEmpty) {
        // Get user's first facility
        final facilities = await FacilityService.getUserFacilities();
        if (facilities.isEmpty) {
          throw Exception('No facilities found. Please create a facility first.');
        }
        facilityId = facilities.first.id;
        facilityName = facilities.first.name;
        facilityEmail = facilities.first.email ?? '';
        facilityPhone = facilities.first.phone ?? '';
      } else {
        // Get facility details
        final facilities = await FacilityService.getUserFacilities();
        final facility = facilities.firstWhere(
          (f) => f.id == facilityId,
          orElse: () => throw Exception('Facility not found: $facilityId'),
        );
        facilityName = facility.name;
        facilityEmail = facility.email ?? '';
        facilityPhone = facility.phone ?? '';
      }

      // Ensure local state tracks the facility we ended up using
      if (mounted) {
        setState(() {
          _selectedFacilityId = facilityId;
        });
      }

      // Require verification for new DNR entries
      if (widget.dnrEntry == null && !_verificationSuccessful) {
        throw Exception('Please verify the DNR entry using the verification code sent to your email before saving.');
      }

      final linkedTenantName = _selectedTenantId != null
          ? (_linkedTenantName ?? _nameController.text.trim())
          : null;

      if (widget.dnrEntry != null) {
        // Update existing DNR entry
        final updatedEntry = widget.dnrEntry!.copyWith(
          name: _nameController.text.trim(),
          email: _emailController.text.trim(),
          phone: _phoneController.text.trim(),
          reason: _reasonController.text.trim(),
          active: _isActive,
          expiresAt: _expiresAt,
          updatedAt: DateTime.now(),
          nameLower: _nameController.text.trim().toLowerCase(),
          emailLower: _emailController.text.trim().toLowerCase(),
          phoneDigits: _phoneController.text.trim().replaceAll(RegExp(r'\D'), ''),
          linkedTenantId: _selectedTenantId,
          linkedTenantName: linkedTenantName,
        );

        await DNRService.updateDNREntry(
          facilityId: facilityId,
          dnrId: widget.dnrEntry!.id,
          name: updatedEntry.name,
          email: updatedEntry.email,
          phone: updatedEntry.phone,
          reason: updatedEntry.reason,
          active: updatedEntry.active,
          expiresAt: updatedEntry.expiresAt,
          evidenceUrls: updatedEntry.evidenceUrls,
          facilityName: _facilityName ?? facilityName,
          ownerEmail: _ownerEmail ?? user.email ?? '',
          facilityPhone: _facilityPhone ?? facilityPhone,
          linkedTenantId: _selectedTenantId,
          linkedTenantName: linkedTenantName,
          previousLinkedTenantId: widget.dnrEntry!.linkedTenantId,
        );

        if (kDebugMode) {
          print('✅ DNR entry updated successfully');
        }
        
        // Invalidate providers to trigger real-time updates
        ref.invalidate(dnrEntriesForFacilityProvider(facilityId));
      } else {
        // Create new DNR entry
        // Get user display name
        final userEmail = user.email ?? '';
        final userDisplayName = await DNRService.getUserDisplayName(user.uid, userEmail);
        
        final dnrId = await DNRService.createDNREntry(
          facilityId: facilityId,
          name: _nameController.text.trim(),
          email: _emailController.text.trim(),
          phone: _phoneController.text.trim(),
          reason: _reasonController.text.trim(),
          active: _isActive,
          expiresAt: _expiresAt,
          facilityName: _facilityName ?? facilityName,
          ownerEmail: _ownerEmail ?? user.email ?? '',
          facilityPhone: _facilityPhone ?? facilityPhone,
          addedByEmail: userEmail,
          addedByName: userDisplayName,
          linkedTenantId: _selectedTenantId,
          linkedTenantName: linkedTenantName,
        );

        if (kDebugMode) {
          print('✅ DNR entry created successfully: $dnrId');
        }
        
        // Invalidate providers to trigger real-time updates
        ref.invalidate(dnrEntriesForFacilityProvider(facilityId));
      }

      if (mounted) {
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.dnrEntry != null 
              ? 'DNR entry updated successfully' 
              : 'DNR entry created successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error saving DNR entry: $e');
      }
      
      if (mounted) {
        setState(() {
          _errorMessage = e.toString();
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  Widget _buildFacilitySelectorField() {
    final authState = ref.watch(authStateProvider);

    return authState.when(
      data: (user) {
        if (user == null) {
          return Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.warning.withOpacity(0.1),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.warning),
            ),
            child: const Text(
              'Sign in to manage DNR entries.',
              style: TextStyle(color: AppTheme.textPrimary),
            ),
          );
        }

        final facilitiesAsync = ref.watch(userFacilitiesProvider(user.uid));

        return facilitiesAsync.when(
          data: (facilities) {
            if (_selectedFacilityId == null &&
                widget.facilityId == null &&
                facilities.length == 1) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted) return;
                setState(() {
                  _selectedFacilityId = facilities.first.id;
                });
                _loadFacilityInfo(facilityId: facilities.first.id);
              });
            }

            if (facilities.isEmpty) {
              return Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.warning.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.warning),
                ),
                child: const Text(
                  'No facilities found. Create a facility before adding DNR entries.',
                  style: TextStyle(color: AppTheme.textPrimary),
                ),
              );
            }

            final selectedValue = _selectedFacilityId ?? '';
            final items = <DropdownMenuItem<String>>[
              const DropdownMenuItem(
                value: '',
                child: Text('Select facility'),
              ),
              ...facilities.map(
                (facility) => DropdownMenuItem(
                  value: facility.id,
                  child: Text(facility.name),
                ),
              ),
            ];

            if (selectedValue.isNotEmpty &&
                !facilities.any((facility) => facility.id == selectedValue)) {
              items.add(
                DropdownMenuItem(
                  value: selectedValue,
                  child: Text(
                    'Existing selection',
                    style: const TextStyle(fontStyle: FontStyle.italic),
                  ),
                ),
              );
            }

            return DropdownButtonFormField<String>(
              value: selectedValue,
              decoration: InputDecoration(
                labelText: 'Facility *',
                prefixIcon: const Icon(Icons.business),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
              items: items,
              onChanged: (value) {
                final newValue = value ?? '';
                setState(() {
                  _selectedFacilityId = newValue.isEmpty ? null : newValue;
                  _selectedTenantId = null;
                  _linkedTenantName = null;
                  _verificationSent = false;
                  _verificationSuccessful = false;
                  _generatedVerificationCode = null;
                  _verificationError = null;
                  _verificationCodeController.clear();
                });
                if (newValue.isNotEmpty) {
                  _loadFacilityInfo(facilityId: newValue);
                } else {
                  _loadFacilityInfo(facilityId: null);
                }
              },
            );
          },
          loading: () => const SizedBox(
            height: 4,
            child: LinearProgressIndicator(),
          ),
          error: (error, stackTrace) => Text('Error loading facilities: $error'),
        );
      },
      loading: () => const SizedBox(
        height: 4,
        child: LinearProgressIndicator(),
      ),
      error: (error, stackTrace) => Text('Error loading account: $error'),
    );
  }

  Widget _buildTenantLinkSelector() {
    final facilityId = _selectedFacilityId;
    if (facilityId == null || facilityId.isEmpty) {
      return const SizedBox.shrink();
    }

    final tenantsAsync = ref.watch(facilityTenantsProvider(facilityId));

    return tenantsAsync.when(
      data: (tenants) {
        final items = <DropdownMenuItem<String>>[
          const DropdownMenuItem(
            value: '',
            child: Text('Manual entry'),
          ),
          ...tenants.map(
            (tenant) => DropdownMenuItem(
              value: tenant.id,
              child: Text(
                '${tenant.name}${tenant.unitNumber.isNotEmpty ? ' • ${tenant.unitNumber}' : ''}',
              ),
            ),
          ),
        ];

        final hasSelectedTenant = _selectedTenantId != null &&
            tenants.any((tenant) => tenant.id == _selectedTenantId);

        if (_selectedTenantId != null &&
            _selectedTenantId!.isNotEmpty &&
            !hasSelectedTenant) {
          items.add(
            DropdownMenuItem(
              value: _selectedTenantId!,
              child: Text(
                _linkedTenantName != null
                    ? 'Linked tenant: $_linkedTenantName (inactive)'
                    : 'Linked tenant (inactive)',
                style: const TextStyle(fontStyle: FontStyle.italic),
              ),
            ),
          );
        }

        final selectedValue = _selectedTenantId ?? '';

        return DropdownButtonFormField<String>(
          value: selectedValue,
          decoration: InputDecoration(
            labelText: 'Link to tenant (optional)',
            helperText: 'Selecting a tenant auto-fills their contact details.',
            prefixIcon: const Icon(Icons.person_search),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
          items: items,
          onChanged: (value) {
            setState(() {
              if (value == null || value.isEmpty) {
                _selectedTenantId = null;
                _linkedTenantName = null;
              } else {
                _selectedTenantId = value;
                TenantModel? matchedTenant;
                for (final tenant in tenants) {
                  if (tenant.id == value) {
                    matchedTenant = tenant;
                    break;
                  }
                }
                if (matchedTenant != null) {
                  _linkedTenantName = matchedTenant.name;
                  _nameController.text = matchedTenant.name;
                  _emailController.text = matchedTenant.email;
                  _phoneController.text = matchedTenant.phone;
                }
              }
            });
          },
        );
      },
      loading: () => const SizedBox(
        height: 4,
        child: LinearProgressIndicator(),
      ),
      error: (error, stackTrace) => Text('Error loading tenants: $error'),
    );
  }

  Widget _buildFacilitySummaryCard() {
    final facilityId = _selectedFacilityId;
    if (facilityId == null || facilityId.isEmpty) {
      return const SizedBox.shrink();
    }

    final facilityName = _facilityName ?? 'Not available';
    final facilityEmail = (_ownerEmail?.isNotEmpty ?? false) ? _ownerEmail! : 'Not available';
    final facilityPhone = _facilityPhone ?? 'Not available';
    final addedBy = (_addedByName != null && _addedByEmail != null)
        ? '$_addedByName ($_addedByEmail)'
        : 'Not available';

    Widget summaryRow(IconData icon, String label, String value) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4.0),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, color: AppTheme.error, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  Text(value),
                ],
              ),
            ),
          ],
        ),
      );
    }

    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.verified_outlined, color: AppTheme.error),
                const SizedBox(width: 8),
                const Text(
                  'Facility Context',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: () {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Switch facilities using the selector above. Update facility contact details inside Facility Management.'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.info_outline),
                  label: const Text('Manage'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            summaryRow(Icons.business, 'Facility', facilityName),
            summaryRow(Icons.email_outlined, 'Facility Email', facilityEmail),
            summaryRow(Icons.phone, 'Facility Phone', facilityPhone),
            summaryRow(Icons.person_outline, 'Added By', addedBy),
          ],
        ),
      ),
    );
  }

  Widget _buildVerificationCard() {
    if (widget.dnrEntry != null) {
      return const SizedBox.shrink();
    }

    final facilityId = _selectedFacilityId;
    if (facilityId == null || facilityId.isEmpty) {
      return const SizedBox.shrink();
    }

    final facilityEmail = _ownerEmail;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Facility Verification',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Text(
              facilityEmail != null && facilityEmail.isNotEmpty
                  ? 'Send a verification code to $facilityEmail to confirm this DNR entry.'
                  : 'Facility email is missing. Add an email to the facility to enable verification.',
            ),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: (facilityEmail == null || facilityEmail.isEmpty || _isSendingVerification)
                  ? null
                  : _sendVerificationCode,
              icon: _isSendingVerification
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send),
              label: Text(_isSendingVerification ? 'Sending...' : 'Send Verification Code'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.error,
                foregroundColor: AppTheme.textOnDark,
              ),
            ),
            if (_verificationSent) ...[
              const SizedBox(height: 16),
              TextField(
                controller: _verificationCodeController,
                decoration: InputDecoration(
                  labelText: 'Verification Code',
                  border: const OutlineInputBorder(),
                  prefixIcon: const Icon(Icons.verified_user),
                  suffixIcon: _verificationSuccessful
                      ? Icon(Icons.check_circle, color: AppTheme.success)
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: _confirmVerificationCode,
                icon: const Icon(Icons.lock_open),
                label: const Text('Confirm Code'),
              ),
            ],
            if (_verificationError != null) ...[
              const SizedBox(height: 8),
              Text(
                _verificationError!,
                style: TextStyle(color: AppTheme.error),
              ),
            ],
            if (_verificationSuccessful) ...[
              const SizedBox(height: 8),
              Row(
                children: const [
                  Icon(Icons.check_circle, color: AppTheme.success),
                  SizedBox(width: 8),
                  Text('Facility verification complete.', style: TextStyle(color: AppTheme.success)),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Error message
              if (_errorMessage != null)
                Container(
                  padding: const EdgeInsets.all(12),
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: AppTheme.error.withOpacity(0.1),
                    border: Border.all(color: AppTheme.error),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error, color: AppTheme.error),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(color: AppTheme.error),
                        ),
                      ),
                    ],
                  ),
                ),

              // Facility Information (Read-only)
              _buildFacilitySelectorField(),
              const SizedBox(height: 16),
              if ((_selectedFacilityId ?? '').isNotEmpty) ...[
                _buildFacilitySummaryCard(),
                const SizedBox(height: 16),
                _buildVerificationCard(),
                const SizedBox(height: 16),
                _buildTenantLinkSelector(),
                const SizedBox(height: 16),
              ],

              // Name field
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Full Name *',
                  hintText: 'Enter the person\'s full name',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Email field
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email Address *',
                  hintText: 'Enter email address',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email),
                ),
                keyboardType: TextInputType.emailAddress,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter an email address';
                  }
                  if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(value)) {
                    return 'Please enter a valid email address';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Phone field
              TextFormField(
                controller: _phoneController,
                decoration: const InputDecoration(
                  labelText: 'Phone Number *',
                  hintText: 'Enter phone number',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.phone),
                ),
                keyboardType: TextInputType.phone,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a phone number';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Reason field
              TextFormField(
                controller: _reasonController,
                decoration: const InputDecoration(
                  labelText: 'Reason for DNR *',
                  hintText: 'Enter the reason for Do Not Rent',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.warning),
                ),
                maxLines: 3,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a reason';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              // Active status
              SwitchListTile(
                title: const Text('Active'),
                subtitle: const Text('Whether this DNR entry is currently active'),
                value: _isActive,
                onChanged: (value) {
                  setState(() {
                    _isActive = value;
                  });
                },
                secondary: Icon(
                  _isActive ? Icons.check_circle : Icons.cancel,
                  color: _isActive ? AppTheme.success : AppTheme.error,
                ),
              ),
              const SizedBox(height: 16),

              // Expiration date
              InkWell(
                onTap: () async {
                  final date = await showDatePicker(
                    context: context,
                    initialDate: _expiresAt ?? DateTime.now().add(const Duration(days: 365)),
                    firstDate: DateTime.now(),
                    lastDate: DateTime.now().add(const Duration(days: 3650)),
                  );
                  if (date != null) {
                    setState(() {
                      _expiresAt = date;
                    });
                  }
                },
                child: InputDecorator(
                  decoration: const InputDecoration(
                    labelText: 'Expiration Date (Optional)',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.calendar_today),
                  ),
                  child: Text(
                    _expiresAt != null 
                      ? '${_expiresAt!.day}/${_expiresAt!.month}/${_expiresAt!.year}'
                      : 'No expiration',
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Notes field
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(
                  labelText: 'Additional Notes',
                  hintText: 'Enter any additional information',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.note),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 24),

              // Save button
              ElevatedButton(
                onPressed: _isLoading ? null : _saveDNR,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.error,
                  foregroundColor: AppTheme.textOnDark,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: _isLoading
                    ? const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(AppTheme.textOnDark),
                            ),
                          ),
                          SizedBox(width: 12),
                          Text('Saving...'),
                        ],
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(widget.dnrEntry != null ? Icons.save : Icons.add),
                          const SizedBox(width: 8),
                          Text(widget.dnrEntry != null ? 'Update DNR Entry' : 'Create DNR Entry'),
                        ],
                      ),
              ),
              const SizedBox(height: 120),
            ],
          ),
        ),
      );
  }

}