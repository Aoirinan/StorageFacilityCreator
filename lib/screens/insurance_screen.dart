import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/modern_navigation_service.dart';
import '../services/insurance_service.dart';
import '../services/facility_service.dart';
import '../services/facility_creator_account_service.dart';
import '../providers/facility_provider.dart';
import '../providers/auth_provider.dart';
import '../models/insurance_plan_model.dart';
import '../models/tenant_insurance_model.dart';
import 'package:flutter/foundation.dart';
import 'insurance_settings_screen.dart';

class InsuranceScreen extends ConsumerStatefulWidget {
  const InsuranceScreen({super.key});

  @override
  ConsumerState<InsuranceScreen> createState() => _InsuranceScreenState();
}

class _InsuranceScreenState extends ConsumerState<InsuranceScreen> with SingleTickerProviderStateMixin {
  late TabController _tabController;
  String? _selectedFacilityId;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 4, vsync: this);
    _loadFacilities();
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadFacilities() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) return;

    try {
      // Ensure account exists before loading facilities
      await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
      
      final facilities = await FacilityService.getUserFacilities();
      if (facilities.isNotEmpty && mounted) {
        setState(() {
          _selectedFacilityId = facilities.first.id;
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error loading facilities in insurance screen: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/insurance',
      title: 'Insurance Management',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        if (_selectedFacilityId != null)
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Create Insurance Plan',
            onPressed: () => _showCreatePlanDialog(),
          ),
      ],
      child: _selectedFacilityId == null
          ? _buildNoFacilityMessage()
          : Column(
              children: [
                _buildFacilitySelector(),
                TabBar(
                  controller: _tabController,
                  tabs: const [
                    Tab(text: 'Plans', icon: Icon(Icons.shield)),
                    Tab(text: 'Tenants', icon: Icon(Icons.people)),
                    Tab(text: 'Settings', icon: Icon(Icons.settings)),
                    Tab(text: 'Reports', icon: Icon(Icons.assessment)),
                  ],
                ),
                Expanded(
                  child: TabBarView(
                    controller: _tabController,
                    children: [
                      _buildPlansTab(),
                      _buildTenantsTab(),
                      _buildSettingsTab(),
                      _buildReportsTab(),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildNoFacilityMessage() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.business, size: 64, color: AppTheme.textTertiary),
          const SizedBox(height: 16),
          const Text(
            'No Facilities Found',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'Please create a facility to manage insurance plans.',
            style: TextStyle(color: AppTheme.textSecondary),
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
            return Padding(
              padding: const EdgeInsets.all(16),
              child: DropdownButtonFormField<String>(
                value: _selectedFacilityId,
                decoration: const InputDecoration(
                  labelText: 'Facility',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.business),
                ),
                items: facilities.map((facility) {
                  return DropdownMenuItem(
                    value: facility.id,
                    child: Text(facility.name),
                  );
                }).toList(),
                onChanged: (value) {
                  setState(() {
                    _selectedFacilityId = value;
                  });
                },
              ),
            );
          },
          loading: () => const LinearProgressIndicator(),
          error: (_, __) => const SizedBox.shrink(),
        );
      },
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  Widget _buildPlansTab() {
    if (_selectedFacilityId == null) {
      return const Center(child: Text('Select a facility'));
    }

    return StreamBuilder<List<InsurancePlanModel>>(
      stream: InsuranceService.getInsurancePlansStream(_selectedFacilityId!),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }

        if (snapshot.hasError) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error, size: 64, color: AppTheme.error),
                const SizedBox(height: 16),
                Text('Error loading plans: ${snapshot.error}'),
              ],
            ),
          );
        }

        final plans = snapshot.data ?? [];

        if (plans.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.shield_outlined, size: 64, color: AppTheme.textTertiary),
                const SizedBox(height: 16),
                const Text(
                  'No Insurance Plans',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Text(
                  'Create your first insurance plan to get started',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 24),
                ElevatedButton.icon(
                  onPressed: () => _showCreatePlanDialog(),
                  icon: const Icon(Icons.add),
                  label: const Text('Create Plan'),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16),
          itemCount: plans.length,
          itemBuilder: (context, index) {
            final plan = plans[index];
            return _buildPlanCard(plan);
          },
        );
      },
    );
  }

  Widget _buildPlanCard(InsurancePlanModel plan) {
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: plan.isDefault ? AppTheme.primaryBlue : AppTheme.borderLight,
          width: plan.isDefault ? 2 : 1,
        ),
      ),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppTheme.primaryBlue.withOpacity(0.1),
          child: Icon(Icons.shield, color: AppTheme.primaryBlue),
        ),
        title: Row(
          children: [
            Expanded(child: Text(plan.name, style: const TextStyle(fontWeight: FontWeight.bold))),
            if (plan.isDefault)
              Chip(
                label: const Text('Default', style: TextStyle(fontSize: 10)),
                backgroundColor: AppTheme.primaryBlue.withOpacity(0.1),
                padding: EdgeInsets.zero,
              ),
            if (plan.isRequired)
              Chip(
                label: const Text('Required', style: TextStyle(fontSize: 10)),
                backgroundColor: AppTheme.error.withOpacity(0.1),
                padding: EdgeInsets.zero,
              ),
          ],
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 4),
            Text('Monthly: \$${plan.monthlyPrice.toStringAsFixed(2)}'),
            Text('Coverage: \$${plan.coverageAmount.toStringAsFixed(2)}'),
            if (plan.description != null && plan.description!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  plan.description!,
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
              ),
          ],
        ),
        trailing: PopupMenuButton(
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'edit', child: Text('Edit')),
            const PopupMenuItem(value: 'delete', child: Text('Delete')),
          ],
          onSelected: (value) {
            if (value == 'edit') {
              _showEditPlanDialog(plan);
            } else if (value == 'delete') {
              _showDeletePlanDialog(plan);
            }
          },
        ),
      ),
    );
  }

  Widget _buildTenantsTab() {
    return const Center(
      child: Text('Tenant insurance view - to be implemented'),
    );
  }

  Widget _buildSettingsTab() {
    if (_selectedFacilityId == null) {
      return const Center(child: Text('Select a facility'));
    }
    
    return InsuranceSettingsScreen(facilityId: _selectedFacilityId!);
  }

  Widget _buildReportsTab() {
    return const Center(
      child: Text('Insurance reports - to be implemented'),
    );
  }

  void _showCreatePlanDialog() {
    final nameController = TextEditingController();
    final priceController = TextEditingController();
    final coverageController = TextEditingController();
    final descriptionController = TextEditingController();
    bool isDefault = false;
    bool isRequired = false;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Create Insurance Plan'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Plan Name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: priceController,
                  decoration: const InputDecoration(
                    labelText: 'Monthly Price (\$)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: coverageController,
                  decoration: const InputDecoration(
                    labelText: 'Coverage Amount (\$)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  title: const Text('Set as Default'),
                  value: isDefault,
                  onChanged: (value) => setState(() => isDefault = value),
                ),
                SwitchListTile(
                  title: const Text('Required for Tenants'),
                  value: isRequired,
                  onChanged: (value) => setState(() => isRequired = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                if (nameController.text.isEmpty ||
                    priceController.text.isEmpty ||
                    coverageController.text.isEmpty) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Please fill in all required fields')),
                  );
                  return;
                }

                try {
                  // Validate numeric inputs
                  final monthlyPrice = double.tryParse(priceController.text);
                  final coverageAmount = double.tryParse(coverageController.text);
                  
                  if (monthlyPrice == null || monthlyPrice <= 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please enter a valid monthly price')),
                    );
                    return;
                  }
                  
                  if (coverageAmount == null || coverageAmount <= 0) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Please enter a valid coverage amount')),
                    );
                    return;
                  }
                  
                  await InsuranceService.createInsurancePlan(
                    facilityId: _selectedFacilityId!,
                    name: nameController.text.trim(),
                    monthlyPrice: monthlyPrice,
                    coverageAmount: coverageAmount,
                    description: descriptionController.text.trim().isEmpty
                        ? null
                        : descriptionController.text.trim(),
                    isDefault: isDefault,
                    isRequired: isRequired,
                  );

                  if (mounted) {
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Insurance plan created successfully'),
                        backgroundColor: AppTheme.success,
                      ),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Error creating plan: $e'),
                        backgroundColor: AppTheme.error,
                      ),
                    );
                  }
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditPlanDialog(InsurancePlanModel plan) {
    final nameController = TextEditingController(text: plan.name);
    final priceController = TextEditingController(text: plan.monthlyPrice.toString());
    final coverageController = TextEditingController(text: plan.coverageAmount.toString());
    final descriptionController = TextEditingController(text: plan.description ?? '');
    bool isDefault = plan.isDefault;
    bool isRequired = plan.isRequired;

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Edit Insurance Plan'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  decoration: const InputDecoration(
                    labelText: 'Plan Name',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: priceController,
                  decoration: const InputDecoration(
                    labelText: 'Monthly Price (\$)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: coverageController,
                  decoration: const InputDecoration(
                    labelText: 'Coverage Amount (\$)',
                    border: OutlineInputBorder(),
                  ),
                  keyboardType: TextInputType.number,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: descriptionController,
                  decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                    border: OutlineInputBorder(),
                  ),
                  maxLines: 3,
                ),
                const SizedBox(height: 16),
                SwitchListTile(
                  title: const Text('Set as Default'),
                  value: isDefault,
                  onChanged: (value) => setState(() => isDefault = value),
                ),
                SwitchListTile(
                  title: const Text('Required for Tenants'),
                  value: isRequired,
                  onChanged: (value) => setState(() => isRequired = value),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                try {
                  await InsuranceService.updateInsurancePlan(
                    facilityId: plan.facilityId,
                    planId: plan.id,
                    name: nameController.text,
                    monthlyPrice: double.parse(priceController.text),
                    coverageAmount: double.parse(coverageController.text),
                    description: descriptionController.text.isEmpty
                        ? null
                        : descriptionController.text,
                    isDefault: isDefault,
                    isRequired: isRequired,
                  );

                  if (mounted) {
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Insurance plan updated')),
                    );
                  }
                } catch (e) {
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Error: $e')),
                    );
                  }
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  void _showDeletePlanDialog(InsurancePlanModel plan) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Insurance Plan'),
        content: Text('Are you sure you want to delete "${plan.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              try {
                await InsuranceService.deleteInsurancePlan(
                  facilityId: plan.facilityId,
                  planId: plan.id,
                );

                if (mounted) {
                  Navigator.of(context).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Insurance plan deleted')),
                  );
                }
              } catch (e) {
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Error: $e')),
                  );
                }
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
