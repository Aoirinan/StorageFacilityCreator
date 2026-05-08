import 'package:flutter/material.dart';
import '../widgets/keyboard_scrollable.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:go_router/go_router.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';
import '../services/facility_service.dart';
import '../services/permission_service.dart';
import '../services/facility_creator_account_service.dart';
import '../services/superadmin_service.dart';
import '../services/email_usage_service.dart';
import 'package:sfcapp/constants/email_monthly_limits.dart';
import 'package:sfcapp/constants/facility_capacity.dart';
import '../theme/app_theme.dart';
import '../screens/subscription_test_screen.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';
import '../utils/error_message_helper.dart';
import '../utils/time_zone_helper.dart';

class FacilityCreationWizard extends ConsumerStatefulWidget {
  final VoidCallback? onFacilityCreated;

  const FacilityCreationWizard({
    super.key,
    this.onFacilityCreated,
  });

  @override
  ConsumerState<FacilityCreationWizard> createState() => _FacilityCreationWizardState();
}

class _FacilityCreationWizardState extends ConsumerState<FacilityCreationWizard> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _addressController = TextEditingController();
  final _phoneController = TextEditingController();
  final _emailController = TextEditingController();
  
  // New fields
  String? _selectedTimeZone;
  final _gracePeriodController = TextEditingController(text: '5');
  final _lateFeeAmountController = TextEditingController(text: '25.00');
  String _lateFeeType = 'flat'; // 'flat' or 'percentage'
  final _totalUnitsController = TextEditingController(text: '');
  
  bool _isLoading = false;
  String? _errorMessage;
  
  // Common time zones
  final List<String> _timeZones = [
    'America/New_York',
    'America/Chicago',
    'America/Denver',
    'America/Phoenix',
    'America/Los_Angeles',
    'America/Anchorage',
    'Pacific/Honolulu',
  ];

  @override
  void initState() {
    super.initState();
    _selectedTimeZone ??= TimeZoneHelper.defaultTimeZoneId;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _addressController.dispose();
    _phoneController.dispose();
    _emailController.dispose();
    _gracePeriodController.dispose();
    _lateFeeAmountController.dispose();
    _totalUnitsController.dispose();
    super.dispose();
  }

  Future<void> _createFacility() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      if (kDebugMode) {
        print('🔄 Creating facility: ${_nameController.text.trim()}');
      }

      // Check facility count and subscription before creating
      // Superadmins bypass this check
      final currentUser = FirebaseAuth.instance.currentUser;
      if (currentUser != null && !SuperAdminService.isSuperAdmin(currentUser)) {
        try {
          final account = await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
          final currentFacilityCount = account.facilityIds.length;
          
          // Trial users can only create 1 facility
          // Active subscribers can create unlimited facilities
          if (currentFacilityCount >= 1) {
            // Check if user is on trial - trials are limited to 1 facility
            if (account.hasTrial) {
              if (kDebugMode) {
                print('⚠️ Trial user trying to create 2nd facility (limit is 1)');
              }
              
              // Close wizard and show trial limit message
              if (mounted) {
                setState(() {
                  _isLoading = false;
                });
                
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
                
                showDialog(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => AlertDialog(
                    title: const Row(
                      children: [
                        Icon(Icons.payment, color: AppTheme.warning),
                        SizedBox(width: 8),
                        Text('Subscription Required'),
                      ],
                    ),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Free trial accounts are limited to 1 facility.\n',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'To add a second facility, you need to:',
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: AppTheme.primaryBlue.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.primaryBlue),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Icon(Icons.check_circle, color: AppTheme.primaryBlue, size: 20),
                                  const SizedBox(width: 8),
                                  const Text(
                                    'Subscribe to Base Plan',
                                    style: TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                              const Padding(
                                padding: EdgeInsets.only(left: 28, top: 4),
                                child: Text(
                                  '\$75/month (includes first facility)',
                                  style: TextStyle(fontSize: 14),
                                ),
                              ),
                              const SizedBox(height: 12),
                              Row(
                                children: [
                                  Icon(Icons.add_circle, color: AppTheme.primaryBlue, size: 20),
                                  const SizedBox(width: 8),
                                  const Text(
                                    'Add Extra Facility',
                                    style: TextStyle(fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                              const Padding(
                                padding: EdgeInsets.only(left: 28, top: 4),
                                child: Text(
                                  '\$75/month (for each additional facility)',
                                  style: TextStyle(fontSize: 14),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 12),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: AppTheme.success.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: AppTheme.success),
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                'Total: ',
                                style: TextStyle(fontSize: 14),
                              ),
                              Text(
                                '\$45/month',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                  color: AppTheme.success,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () {
                          Navigator.of(context).pop();
                        },
                        child: const Text('Cancel'),
                      ),
                      ElevatedButton.icon(
                        onPressed: () {
                          Navigator.of(context).pop();
                context.go(
                  AppRoute.subscription,
                  extra: const SubscriptionTestScreen(
                                requireSubscriptionChoice: true,
                                message: 'Subscribe to add your second facility. Your subscription will automatically include the base plan (\$75/month) plus the additional facility (\$75/month).',
                            ),
                          );
                        },
                        icon: const Icon(Icons.payment),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.success,
                          foregroundColor: AppTheme.textOnDark,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                        ),
                        label: const Text(
                          'Subscribe Now',
                          style: TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ),
                );
              }
              return;
            }
            
            // Non-trial users with 1+ facility need active subscription (not just trial)
            if (!account.hasActiveSubscription) {
              if (kDebugMode) {
                print('⚠️ User has $currentFacilityCount facility(ies) but no active subscription');
              }
              
              // Close wizard and redirect to subscription page
              if (mounted) {
                setState(() {
                  _isLoading = false;
                });
                
                if (Navigator.of(context).canPop()) {
                  Navigator.of(context).pop();
                }
                
              showDialog(
                context: context,
                barrierDismissible: false,
                builder: (context) => AlertDialog(
                  title: const Row(
                    children: [
                      Icon(Icons.payment, color: AppTheme.warning),
                      SizedBox(width: 8),
                      Text('Subscription Required'),
                    ],
                  ),
                  content: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'You already have ${currentFacilityCount} facility(ies).\n',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(height: 12),
                      const Text(
                        'To add additional facilities, you need to:',
                        style: TextStyle(fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryBlue.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.primaryBlue),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.check_circle, color: AppTheme.primaryBlue, size: 20),
                                const SizedBox(width: 8),
                                const Text(
                                  'Subscribe to Base Plan',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                            const Padding(
                              padding: EdgeInsets.only(left: 28, top: 4),
                              child: Text(
                                '\$25/month (includes first facility)',
                                style: TextStyle(fontSize: 14),
                              ),
                            ),
                            const SizedBox(height: 12),
                            Row(
                              children: [
                                Icon(Icons.add_circle, color: AppTheme.primaryBlue, size: 20),
                                const SizedBox(width: 8),
                                const Text(
                                  'Add Extra Facility',
                                  style: TextStyle(fontWeight: FontWeight.w600),
                                ),
                              ],
                            ),
                            const Padding(
                              padding: EdgeInsets.only(left: 28, top: 4),
                              child: Text(
                                '\$20/month (for each additional facility)',
                                style: TextStyle(fontSize: 14),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: AppTheme.success.withOpacity(0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: AppTheme.success),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              'Total: ',
                              style: TextStyle(fontSize: 14),
                            ),
                            Text(
                              '\$${(25 + (20 * (currentFacilityCount + 1 - 1))).toStringAsFixed(0)}/month',
                              style: const TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                color: AppTheme.success,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  actions: [
                    TextButton(
                      onPressed: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).pop(); // Close wizard
                      },
                      child: const Text('Cancel'),
                    ),
                    ElevatedButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).pop(); // Close wizard
                context.go(
                  AppRoute.subscription,
                  extra: const SubscriptionTestScreen(
                              requireSubscriptionChoice: true,
                              message: 'Subscribe to add additional facilities. Your subscription will automatically include the base plan (\$75/month) plus each additional facility (\$75/month).',
                          ),
                        );
                      },
                      icon: const Icon(Icons.payment),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.success,
                        foregroundColor: AppTheme.textOnDark,
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                      ),
                      label: const Text(
                        'Subscribe Now',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                  ],
                ),
              );
              }
              return;
            }

            // Active subscribers adding 2nd+ facility: require explicit consent before charging
            if (account.hasActiveSubscription && currentFacilityCount >= 1) {
              if (mounted) {
                setState(() {
                  _isLoading = false;
                });
                final confirmed = await showDialog<bool>(
                  context: context,
                  barrierDismissible: false,
                  builder: (context) => AlertDialog(
                    title: const Row(
                      children: [
                        Icon(Icons.add_business, color: AppTheme.primaryBlue),
                        SizedBox(width: 8),
                        Text('Add Facility to Subscription'),
                      ],
                    ),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Adding another facility will add \$75/month to your subscription.',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'This amount will be included in your next monthly invoice—you will not be charged immediately.',
                          style: TextStyle(fontSize: 14),
                        ),
                        const SizedBox(height: 12),
                        const Text(
                          'Do you agree to add this facility and the \$75/month charge?',
                          style: TextStyle(fontWeight: FontWeight.w500),
                        ),
                      ],
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.of(context).pop(false),
                        child: const Text('Cancel'),
                      ),
                      ElevatedButton.icon(
                        onPressed: () => Navigator.of(context).pop(true),
                        icon: const Icon(Icons.check_circle),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.success,
                          foregroundColor: AppTheme.textOnDark,
                        ),
                        label: const Text('Yes, Add Facility'),
                      ),
                    ],
                  ),
                );
                if (confirmed != true || !mounted) {
                  return;
                }
                setState(() {
                  _isLoading = true;
                });
              }
            }
          }
        } catch (e) {
          if (kDebugMode) {
            print('⚠️ Could not check account status: $e');
          }
          // Continue with creation if check fails
        }
      }

      // Call service with timeout to handle offline issues
      if (kDebugMode) {
        print('🔄 About to call FacilityService.createFacility...');
      }
      
      String? facilityId;
      
      try {
        // Build billing settings
        Map<String, dynamic>? billingSettings;
        try {
          final gracePeriod = int.tryParse(_gracePeriodController.text.trim()) ?? 5;
          final lateFeeAmount = double.tryParse(_lateFeeAmountController.text.trim()) ?? 25.0;
          billingSettings = {
            'gracePeriodDays': gracePeriod,
            'lateFeeType': _lateFeeType,
            'lateFeeAmount': lateFeeAmount,
          };
        } catch (e) {
          if (kDebugMode) {
            print('⚠️ Error building billing settings: $e');
          }
        }
        
        final totalUnits = int.tryParse(_totalUnitsController.text.trim()) ?? 0;
        facilityId = await FacilityService.createFacility(
          name: _nameController.text.trim(),
          address: _addressController.text.trim().isEmpty ? null : _addressController.text.trim(),
          phone: _phoneController.text.trim().isEmpty ? null : _phoneController.text.trim(),
          email: _emailController.text.trim().isEmpty ? null : _emailController.text.trim(),
          timeZone: _selectedTimeZone ?? TimeZoneHelper.defaultTimeZoneId,
          billingSettings: billingSettings,
          totalUnits: totalUnits,
        );
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Facility creation had connectivity issues: $e');
          print('🔄 Checking if facility was created despite connectivity issues...');
        }
        
        // Even if there was a timeout, the facility might have been created
        try {
          final facilities = await FacilityService.getUserFacilities();
          if (facilities.isNotEmpty) {
            if (kDebugMode) {
              print('✅ Found facilities - creation likely succeeded despite timeout');
            }
            facilityId = facilities.last.id; // Use the most recent facility
          }
        } catch (facilityCheckError) {
          if (kDebugMode) {
            print('❌ Could not verify facility creation: $facilityCheckError');
          }
        }
        
        if (facilityId == null) {
          rethrow; // Re-throw if we couldn't find any evidence of success
        }
      }
      
      if (kDebugMode) {
        print('🎯 FacilityService.createFacility completed with ID: $facilityId');
      }

      if (kDebugMode) {
        print('✅ Facility created successfully: $facilityId');
        print('🔄 About to create default owner role...');
      }
      
      if (kDebugMode) {
        print('🔄 Facility creation completed, proceeding to success flow...');
      }

      // Create default owner role for the facility (non-blocking)
      final ownerUser = FirebaseAuth.instance.currentUser;
      if (ownerUser != null) {
        if (kDebugMode) {
          print('🔄 Starting permission assignment for user: ${ownerUser.uid}');
        }
        // Fire and forget - don't wait for this to complete
        PermissionService.createDefaultOwnerRole(
          ownerId: ownerUser.uid,
          facilityId: facilityId!,
        ).then((_) {
          if (kDebugMode) {
            print('✅ Owner role assigned to facility successfully (background)');
          }
        }).catchError((e) {
          if (kDebugMode) {
            print('⚠️ Warning: Could not assign owner role (background): $e');
          }
        });
        
        if (kDebugMode) {
          print('🔄 Permission assignment started in background, proceeding immediately...');
        }
      } else {
        if (kDebugMode) {
          print('⚠️ Warning: No current user found for permission assignment');
        }
      }
      
      if (kDebugMode) {
        print('🔄 Permission assignment completed, checking if widget is mounted...');
      }

      // Ensure we have a valid facility ID before proceeding to success
      if (facilityId == null) {
        throw Exception('Facility ID is null - creation may have failed');
      }

      if (kDebugMode) {
        print('🔄 Checking if widget is mounted...');
      }
      
      // Link facility to account and handle subscription
      if (mounted) {
        setState(() {
          _isLoading = false;
        });

        try {
          // Get or create account for user
          final account = await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
          
          // Check if this is the 2nd+ facility and user needs to upgrade
          final currentFacilityCount = account.facilityIds.length;
          final isAddingSecondFacility = currentFacilityCount == 1;
          
          // Link facility to account
          await FacilityCreatorAccountService.addFacilityToAccount(
            accountId: account.accountId,
            facilityId: facilityId!,
          );
          
          final emailLimit =
              emailMonthlyLimitForAccount(isTrialing: account.hasTrial);
          await EmailUsageService.setEmailLimit(facilityId!, emailLimit);
          
          if (kDebugMode) {
            print('✅ Email limit set to $emailLimit for facility $facilityId (${account.hasTrial ? "Trial" : "Active"})');
          }

          if (kDebugMode) {
            print('✅ Facility linked to account. Current count: ${currentFacilityCount + 1}');
          }

          // Close facility creation wizard
          if (Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }

          // Check subscription status and facility count
          final updatedAccount = await FacilityCreatorAccountService.getAccount(account.accountId);
          if (updatedAccount != null) {
            // Superadmins bypass subscription requirements
            final checkUser = FirebaseAuth.instance.currentUser;
            final isSuperAdmin = checkUser != null && SuperAdminService.isSuperAdmin(checkUser);
            
            // If this is 2nd+ facility and they don't have active subscription, redirect to payment
            if (isAddingSecondFacility && !updatedAccount.hasActiveSubscription && !isSuperAdmin) {
              if (kDebugMode) {
                print('🔄 2nd facility created - redirecting to payment for subscription upgrade');
              }
              if (mounted) {
                context.go(
                  AppRoute.subscription,
                  extra: const SubscriptionTestScreen(
                      requireSubscriptionChoice: true,
                      message: 'To add a second facility, you need an active subscription.',
                  ),
                );
                return;
              }
            }
            
            // First facility - redirect to subscription choice if needed
            // Superadmins bypass subscription requirements
            if (currentFacilityCount == 0 && 
                !updatedAccount.isSubscriptionActive &&
                !isSuperAdmin) {
              if (mounted) {
                context.go(
                  AppRoute.subscription,
                  extra: const SubscriptionTestScreen(
                      requireSubscriptionChoice: true,
                  ),
                );
              }
              return;
            }
          }
          
          // Success - show success message and go back
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('✅ Facility created successfully!'),
                backgroundColor: AppTheme.success,
                duration: Duration(seconds: 2),
              ),
            );
          }
        } catch (e) {
          if (kDebugMode) {
            print('❌ Error linking facility to account: $e');
          }
          // Still redirect to subscription even if linking fails
          if (mounted) {
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
            context.go(
              AppRoute.subscription,
              extra: const SubscriptionTestScreen(
                  requireSubscriptionChoice: true,
              ),
            );
          }
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating facility: $e');
      }
      
      if (mounted) {
        setState(() {
          _isLoading = false;
          _errorMessage = ErrorMessageHelper.getUserFriendlyMessage(e);
        });
        
        if (kDebugMode) {
          print('🔄 Error occurred, navigating back to home screen...');
        }
        
        // Pop the facility creation wizard
        if (Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
        }
        
        // If no callback provided, pop again to reach home screen
        if (widget.onFacilityCreated == null) {
          if (kDebugMode) {
            print('🔄 No callback provided, popping again to reach home screen');
          }
          Future.delayed(const Duration(milliseconds: 100), () {
            if (mounted) {
              Navigator.of(context).pop(); // Pop facility management screen to reach home
            }
          });
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    
    return authState.when(
      data: (user) {
        if (user == null) {
          return const Center(child: Text('Please sign in to create facilities'));
        }
        
        return Container(
          color: AppTheme.backgroundLight,
          child: Form(
            key: _formKey,
            child: KeyboardScrollable(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header Section
                    Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: AppTheme.primaryBlue.withOpacity(0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.add_business,
                            color: AppTheme.primaryBlue,
                            size: 24,
                          ),
                        ),
                        const SizedBox(width: 16),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Create New Facility',
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w700,
                                  color: AppTheme.textPrimary,
                                  letterSpacing: -0.5,
                                ),
                              ),
                              SizedBox(height: 4),
                              Text(
                                'Set up your storage facility with basic information and billing settings',
                                style: TextStyle(
                                  fontSize: 14,
                                  color: AppTheme.textSecondary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 32),
                    
                    // Facility Information Card
                    Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: AppTheme.borderLight, width: 1),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: AppTheme.primaryBlue.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(
                                    Icons.business,
                                    color: AppTheme.primaryBlue,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                const Text(
                                  'Facility Information',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),
                            
                            // Facility Name
                            TextFormField(
                              controller: _nameController,
                              decoration: const InputDecoration(
                                labelText: 'Facility Name *',
                                hintText: 'e.g., Keepsake Self Storage',
                                prefixIcon: Icon(Icons.business),
                              ),
                              validator: (value) {
                                if (value == null || value.trim().isEmpty) {
                                  return 'Please enter a facility name';
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                            
                            // Address
                            TextFormField(
                              controller: _addressController,
                              decoration: const InputDecoration(
                                labelText: 'Address',
                                hintText: '123 Main St, City, State 12345',
                                prefixIcon: Icon(Icons.location_on),
                              ),
                              maxLines: 2,
                            ),
                            const SizedBox(height: 16),
                            
                            // Phone
                            TextFormField(
                              controller: _phoneController,
                              decoration: const InputDecoration(
                                labelText: 'Phone Number',
                                hintText: '(555) 123-4567',
                                prefixIcon: Icon(Icons.phone),
                              ),
                              keyboardType: TextInputType.phone,
                            ),
                            const SizedBox(height: 16),
                            
                            // Email
                            TextFormField(
                              controller: _emailController,
                              decoration: const InputDecoration(
                                labelText: 'Email',
                                hintText: 'contact@facility.com',
                                prefixIcon: Icon(Icons.email),
                              ),
                              keyboardType: TextInputType.emailAddress,
                            ),
                            const SizedBox(height: 16),
                            
                            // Site-wide capacity (max units); unit rows are added separately in the unit list.
                            TextFormField(
                              controller: _totalUnitsController,
                              decoration: InputDecoration(
                                labelText: 'Unit capacity (max)',
                                hintText: 'e.g., 50',
                                prefixIcon: const Icon(Icons.grid_view),
                                helperText:
                                    'Maximum units this site can hold (1–$kMaxFacilityCapacityUnits). '
                                    'You add individual units under Facilities → Units as you build or rent them.',
                              ),
                              keyboardType: TextInputType.number,
                              validator: (value) {
                                final raw = value?.trim() ?? '';
                                if (raw.isEmpty) {
                                  return 'Total units is required.';
                                }
                                final n = int.tryParse(raw);
                                if (n == null || n < 1 || n > kMaxFacilityCapacityUnits) {
                                  return 'Total units must be between 1 and $kMaxFacilityCapacityUnits.';
                                }
                                return null;
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    
                    // Settings Card
                    Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: AppTheme.borderLight, width: 1),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: AppTheme.info.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(
                                    Icons.settings,
                                    color: AppTheme.info,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                const Text(
                                  'Settings',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),
                            
                            // Time Zone
                            DropdownButtonFormField<String>(
                              value: _selectedTimeZone,
                              decoration: const InputDecoration(
                                labelText: 'Time Zone',
                                hintText: 'Select time zone',
                                prefixIcon: Icon(Icons.access_time),
                              ),
                              items: _timeZones.map((tz) {
                                return DropdownMenuItem<String>(
                                  value: tz,
                                  child: Text(TimeZoneHelper.displayLabel(tz)),
                                );
                              }).toList(),
                              onChanged: (value) {
                                setState(() {
                                  _selectedTimeZone = value;
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    
                    // Billing Settings Card
                    Card(
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                        side: BorderSide(color: AppTheme.borderLight, width: 1),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 40,
                                  height: 40,
                                  decoration: BoxDecoration(
                                    color: AppTheme.success.withOpacity(0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(
                                    Icons.payment,
                                    color: AppTheme.success,
                                    size: 20,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                const Text(
                                  'Billing Settings',
                                  style: TextStyle(
                                    fontSize: 20,
                                    fontWeight: FontWeight.w600,
                                    color: AppTheme.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 24),
                            
                            // Grace Period
                            TextFormField(
                              controller: _gracePeriodController,
                              decoration: const InputDecoration(
                                labelText: 'Grace Period (Days)',
                                hintText: '5',
                                prefixIcon: Icon(Icons.calendar_today),
                                helperText: 'Number of days before late fees apply',
                              ),
                              keyboardType: TextInputType.number,
                              validator: (value) {
                                if (value != null && value.isNotEmpty) {
                                  final days = int.tryParse(value);
                                  if (days == null || days < 0) {
                                    return 'Please enter a valid number of days';
                                  }
                                }
                                return null;
                              },
                            ),
                            const SizedBox(height: 16),
                            
                            // Late Fee Type
                            DropdownButtonFormField<String>(
                              value: _lateFeeType,
                              decoration: const InputDecoration(
                                labelText: 'Late Fee Type',
                                prefixIcon: Icon(Icons.attach_money),
                              ),
                              items: const [
                                DropdownMenuItem(value: 'flat', child: Text('Flat Amount')),
                                DropdownMenuItem(value: 'percentage', child: Text('Percentage')),
                              ],
                              onChanged: (value) {
                                setState(() {
                                  _lateFeeType = value ?? 'flat';
                                });
                              },
                            ),
                            const SizedBox(height: 16),
                            
                            // Late Fee Amount
                            TextFormField(
                              controller: _lateFeeAmountController,
                              decoration: InputDecoration(
                                labelText: _lateFeeType == 'flat' ? 'Late Fee Amount (\$)' : 'Late Fee Percentage (%)',
                                hintText: _lateFeeType == 'flat' ? '25.00' : '5.0',
                                prefixIcon: const Icon(Icons.money),
                                helperText: _lateFeeType == 'flat' 
                                    ? 'Fixed late fee amount in dollars'
                                    : 'Late fee as percentage of rent',
                              ),
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              validator: (value) {
                                if (value != null && value.isNotEmpty) {
                                  final amount = double.tryParse(value);
                                  if (amount == null || amount < 0) {
                                    return 'Please enter a valid amount';
                                  }
                                }
                                return null;
                              },
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    
                    // Error Message
                    if (_errorMessage != null)
                      Card(
                        elevation: 0,
                        color: AppTheme.error.withOpacity(0.1),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: BorderSide(color: AppTheme.error, width: 1),
                        ),
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Row(
                            children: [
                              Icon(Icons.error_outline, color: AppTheme.error, size: 24),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _errorMessage!,
                                  style: TextStyle(
                                    color: AppTheme.error,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    
                    if (_errorMessage != null) const SizedBox(height: 16),
                    
                    // Create Button
                    ElevatedButton(
                      onPressed: _isLoading ? null : _createFacility,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlue,
                        foregroundColor: AppTheme.textOnDark,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        elevation: 0,
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
                                Text(
                                  'Creating Facility...',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            )
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.add_business, size: 20),
                                SizedBox(width: 8),
                                Text(
                                  'Create Facility',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                    ),
                    
                    const SizedBox(height: 8),
                    
                    // Helper text
                    Center(
                      child: Text(
                        'This may take a moment',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stackTrace) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error, size: 64, color: AppTheme.error),
            const SizedBox(height: 16),
            const Text('Error loading user data'),
            const SizedBox(height: 8),
            Text(ErrorMessageHelper.getUserFriendlyMessage(error)),
          ],
        ),
      ),
    );
  }
}