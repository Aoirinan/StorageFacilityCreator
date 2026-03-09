import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../router/app_route.dart';

/// Lease templates and e-signature features - coming soon
class LeaseTemplatesScreen extends ConsumerStatefulWidget {
  final String facilityId;

  const LeaseTemplatesScreen({
    super.key,
    required this.facilityId,
  });

  @override
  ConsumerState<LeaseTemplatesScreen> createState() => _LeaseTemplatesScreenState();
}

class _LeaseTemplatesScreenState extends ConsumerState<LeaseTemplatesScreen> {
  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      title: 'Lease Templates',
      currentRoute: AppRoute.leaseTemplates,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.description_outlined,
                size: 64,
                color: AppTheme.textTertiary,
              ),
              const SizedBox(height: 24),
              Text(
                'Contracts & E-Signature Coming Soon',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              Text(
                'Lease templates and electronic signature features will be available in a future update.',
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
