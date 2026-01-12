import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import '../models/claim_model.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import 'claim_detail_screen.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';

/// Screen listing all insurance claims for a facility
class ClaimsListScreen extends StatelessWidget {
  final String facilityId;

  const ClaimsListScreen({
    super.key,
    required this.facilityId,
  });

  @override
  Widget build(BuildContext context) {
    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/insurance/claims';
    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'Insurance Claims',
      actions: [
        IconButton(
          icon: const Icon(Icons.add),
          tooltip: 'File New Claim',
          onPressed: () {
            context.push(AppRoute.claimDetail, extra: {
              'facilityId': facilityId,
              'isNewClaim': true,
            });
          },
        ),
      ],
      child: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('facilities')
            .doc(facilityId)
            .collection('claims')
            .orderBy('filedDate', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.hasError) {
            return Center(
              child: Text('Error loading claims: ${snapshot.error}'),
            );
          }

          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.description_outlined,
                    size: 64,
                    color: AppTheme.textTertiary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'No claims found',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'File a new claim to get started',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: AppTheme.textTertiary,
                        ),
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () {
                      context.push(AppRoute.claimDetail, extra: {
                        'facilityId': facilityId,
                        'isNewClaim': true,
                      });
                    },
                    icon: const Icon(Icons.add),
                    label: const Text('File New Claim'),
                  ),
                ],
              ),
            );
          }

          final claims = snapshot.data!.docs
              .map((doc) => ClaimModel.fromFirestore(doc))
              .toList();

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: claims.length,
            itemBuilder: (context, index) {
              final claim = claims[index];
              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: ListTile(
                  contentPadding: const EdgeInsets.all(16),
                  leading: CircleAvatar(
                    backgroundColor: _getStatusColor(claim.status).withOpacity(0.1),
                    child: Icon(
                      _getStatusIcon(claim.status),
                      color: _getStatusColor(claim.status),
                    ),
                  ),
                  title: Text(
                    claim.claimType.displayName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  subtitle: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 4),
                      Text('Filed: ${_formatDate(claim.filedDate)}'),
                      Text('Amount: \$${claim.claimAmount.toStringAsFixed(2)}'),
                      if (claim.tenantId.isNotEmpty)
                        FutureBuilder<DocumentSnapshot>(
                          future: FirebaseFirestore.instance
                              .collection('facilities')
                              .doc(facilityId)
                              .collection('tenants')
                              .doc(claim.tenantId)
                              .get(),
                          builder: (context, tenantSnapshot) {
                            if (tenantSnapshot.hasData) {
                              final tenantData = tenantSnapshot.data!.data() as Map<String, dynamic>?;
                              return Text('Tenant: ${tenantData?['name'] ?? 'Unknown'}');
                            }
                            return const SizedBox.shrink();
                          },
                        ),
                    ],
                  ),
                  trailing: Chip(
                    label: Text(
                      claim.status.displayName,
                      style: TextStyle(
                        color: _getStatusColor(claim.status),
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    backgroundColor: _getStatusColor(claim.status).withOpacity(0.1),
                  ),
                  onTap: () {
                    context.push(AppRoute.claimDetail, extra: {
                      'facilityId': facilityId,
                      'claimId': claim.id,
                      'isNewClaim': false,
                    });
                  },
                ),
              );
            },
          );
        },
      ),
    );
  }

  Color _getStatusColor(ClaimStatus status) {
    switch (status) {
      case ClaimStatus.pending:
        return AppTheme.warning;
      case ClaimStatus.inReview:
        return AppTheme.info;
      case ClaimStatus.approved:
        return AppTheme.success;
      case ClaimStatus.denied:
        return AppTheme.error;
      case ClaimStatus.closed:
        return AppTheme.textTertiary;
    }
  }

  IconData _getStatusIcon(ClaimStatus status) {
    switch (status) {
      case ClaimStatus.pending:
        return Icons.pending;
      case ClaimStatus.inReview:
        return Icons.reviews;
      case ClaimStatus.approved:
        return Icons.check_circle;
      case ClaimStatus.denied:
        return Icons.cancel;
      case ClaimStatus.closed:
        return Icons.archive;
    }
  }

  String _formatDate(DateTime date) {
    return '${date.month}/${date.day}/${date.year}';
  }
}

