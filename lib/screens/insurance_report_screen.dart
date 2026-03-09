import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:csv/csv.dart';
import 'package:go_router/go_router.dart';
import 'dart:convert';
import 'dart:typed_data';
import '../models/tenant_model.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/facility_service.dart';
import 'insurance_report_stub.dart'
    if (dart.library.html) 'insurance_report_web.dart';

/// Screen showing insurance status report for all tenants
class InsuranceReportScreen extends StatefulWidget {
  final String facilityId;

  const InsuranceReportScreen({
    super.key,
    required this.facilityId,
  });

  @override
  State<InsuranceReportScreen> createState() => _InsuranceReportScreenState();
}

class _InsuranceReportScreenState extends State<InsuranceReportScreen> {
  String _filterStatus = 'all'; // 'all', 'missing', 'enrolled', 'pending'
  bool _isLoading = false;
  List<TenantModel> _tenants = [];

  @override
  void initState() {
    super.initState();
    _loadTenants();
  }

  Future<void> _loadTenants() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final snapshot = await FirebaseFirestore.instance
          .collection('facilities')
          .doc(widget.facilityId)
          .collection('tenants')
          .where('isActive', isEqualTo: true)
          .get();

      final tenants = snapshot.docs
          .map((doc) => TenantModel.fromFirestore(doc))
          .toList();

      setState(() {
        _tenants = tenants;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading tenants: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  List<TenantModel> get _filteredTenants {
    switch (_filterStatus) {
      case 'missing':
        return _tenants.where((t) => 
          t.insuranceStatus == InsuranceStatus.none || 
          t.insuranceStatus == InsuranceStatus.pendingProof
        ).toList();
      case 'enrolled':
        return _tenants.where((t) => 
          t.insuranceStatus == InsuranceStatus.enrolledInTPP || 
          t.insuranceStatus == InsuranceStatus.autoEnrolled
        ).toList();
      case 'pending':
        return _tenants.where((t) => 
          t.insuranceStatus == InsuranceStatus.pendingProof
        ).toList();
      default:
        return _tenants;
    }
  }

  Future<void> _exportToCSV() async {
    try {
      final csvData = <List<String>>[];
      
      // Header row
      csvData.add([
        'Tenant Name',
        'Unit Number',
        'Email',
        'Phone',
        'Insurance Status',
        'Coverage Amount',
        'TPP Enrollment Date',
        'Insurance Provider',
        'Coverage Level',
      ]);

      // Data rows
      for (final tenant in _filteredTenants) {
        csvData.add([
          tenant.name,
          tenant.unitNumber,
          tenant.email,
          tenant.phone,
          tenant.insuranceStatus.displayName,
          tenant.coverageAmount?.toStringAsFixed(2) ?? 'N/A',
          tenant.tppEnrollmentDate?.toIso8601String() ?? 'N/A',
          tenant.insuranceProvider ?? 'N/A',
          tenant.tppCoverageLevel ?? 'N/A',
        ]);
      }

      final csvString = csv.encode(csvData);
      final bytes = utf8.encode(csvString);
      await downloadReportBytes(bytes, 'insurance_report_${DateTime.now().millisecondsSinceEpoch}.csv');

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Report exported successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error exporting report: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/insurance/report';
    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'Insurance Report',
      actions: [
        IconButton(
          icon: const Icon(Icons.filter_list),
          tooltip: 'Filter',
          onPressed: () {
            showDialog(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Filter by Status'),
                content: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<String>(
                      title: const Text('All Tenants'),
                      value: 'all',
                      groupValue: _filterStatus,
                      onChanged: (value) {
                        setState(() {
                          _filterStatus = value!;
                        });
                        Navigator.pop(context);
                      },
                    ),
                    RadioListTile<String>(
                      title: const Text('Missing Proof / Not Enrolled'),
                      value: 'missing',
                      groupValue: _filterStatus,
                      onChanged: (value) {
                        setState(() {
                          _filterStatus = value!;
                        });
                        Navigator.pop(context);
                      },
                    ),
                    RadioListTile<String>(
                      title: const Text('Enrolled in TPP'),
                      value: 'enrolled',
                      groupValue: _filterStatus,
                      onChanged: (value) {
                        setState(() {
                          _filterStatus = value!;
                        });
                        Navigator.pop(context);
                      },
                    ),
                    RadioListTile<String>(
                      title: const Text('Pending Proof'),
                      value: 'pending',
                      groupValue: _filterStatus,
                      onChanged: (value) {
                        setState(() {
                          _filterStatus = value!;
                        });
                        Navigator.pop(context);
                      },
                    ),
                  ],
                ),
              ),
            );
          },
        ),
        IconButton(
          icon: const Icon(Icons.download),
          tooltip: 'Export CSV',
          onPressed: _exportToCSV,
        ),
      ],
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _filteredTenants.isEmpty
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.shield_outlined,
                        size: 64,
                        color: Colors.grey[400],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No tenants found',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              color: Colors.grey[600],
                            ),
                      ),
                      if (_filterStatus != 'all')
                        Text(
                          'Try changing the filter',
                          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                                color: Colors.grey[500],
                              ),
                        ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    // Summary Cards
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          Expanded(
                            child: _buildSummaryCard(
                              'Total Tenants',
                              _tenants.length.toString(),
                              Colors.blue,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildSummaryCard(
                              'Enrolled in TPP',
                              _tenants.where((t) => 
                                t.insuranceStatus == InsuranceStatus.enrolledInTPP || 
                                t.insuranceStatus == InsuranceStatus.autoEnrolled
                              ).length.toString(),
                              Colors.green,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: _buildSummaryCard(
                              'Missing Proof',
                              _tenants.where((t) => 
                                t.insuranceStatus == InsuranceStatus.none || 
                                t.insuranceStatus == InsuranceStatus.pendingProof
                              ).length.toString(),
                              Colors.orange,
                            ),
                          ),
                        ],
                      ),
                    ),

                    // Tenant List
                    Expanded(
                      child: ListView.builder(
                        padding: const EdgeInsets.all(16),
                        itemCount: _filteredTenants.length,
                        itemBuilder: (context, index) {
                          final tenant = _filteredTenants[index];
                          return Card(
                            margin: const EdgeInsets.only(bottom: 12),
                            child: ListTile(
                              contentPadding: const EdgeInsets.all(16),
                              leading: CircleAvatar(
                                backgroundColor: _getStatusColor(tenant.insuranceStatus).withOpacity(0.1),
                                child: Icon(
                                  _getStatusIcon(tenant.insuranceStatus),
                                  color: _getStatusColor(tenant.insuranceStatus),
                                ),
                              ),
                              title: Text(
                                tenant.name,
                                style: const TextStyle(fontWeight: FontWeight.bold),
                              ),
                              subtitle: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const SizedBox(height: 4),
                                  Text('Unit: ${tenant.unitNumber}'),
                                  Text('Status: ${tenant.insuranceStatus.displayName}'),
                                  if (tenant.coverageAmount != null)
                                    Text('Coverage: \$${tenant.coverageAmount!.toStringAsFixed(2)}'),
                                  if (tenant.tppEnrollmentDate != null)
                                    Text('Enrolled: ${_formatDate(tenant.tppEnrollmentDate!)}'),
                                  if (tenant.insuranceProvider != null)
                                    Text('Provider: ${tenant.insuranceProvider}'),
                                ],
                              ),
                              trailing: Chip(
                                label: Text(
                                  tenant.insuranceStatus.displayName,
                                  style: TextStyle(
                                    color: _getStatusColor(tenant.insuranceStatus),
                                    fontWeight: FontWeight.bold,
                                    fontSize: 12,
                                  ),
                                ),
                                backgroundColor: _getStatusColor(tenant.insuranceStatus).withOpacity(0.1),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _buildSummaryCard(String title, String value, Color color) {
    return Card(
      color: color.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[600],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Color _getStatusColor(InsuranceStatus status) {
    switch (status) {
      case InsuranceStatus.none:
        return Colors.red;
      case InsuranceStatus.pendingProof:
        return Colors.orange;
      case InsuranceStatus.providedProof:
        return Colors.blue;
      case InsuranceStatus.enrolledInTPP:
        return Colors.green;
      case InsuranceStatus.autoEnrolled:
        return Colors.teal;
    }
  }

  IconData _getStatusIcon(InsuranceStatus status) {
    switch (status) {
      case InsuranceStatus.none:
        return Icons.shield_outlined;
      case InsuranceStatus.pendingProof:
        return Icons.pending;
      case InsuranceStatus.providedProof:
        return Icons.check_circle_outline;
      case InsuranceStatus.enrolledInTPP:
        return Icons.shield;
      case InsuranceStatus.autoEnrolled:
        return Icons.auto_fix_high;
    }
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }
}

