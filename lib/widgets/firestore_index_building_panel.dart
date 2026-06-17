import 'package:flutter/material.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Shown while a required Firestore collection-group index is still building.
class FirestoreIndexBuildingPanel extends StatelessWidget {
  final String collectionGroup;
  final VoidCallback? onRetry;

  const FirestoreIndexBuildingPanel({
    super.key,
    required this.collectionGroup,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.build_circle_outlined,
                size: 48, color: AppTheme.warning),
            const SizedBox(height: 16),
            const Text(
              'Database index is building',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Firestore is enabling the collection group index for '
              '`$collectionGroup` (createdAt desc). '
              'This usually takes 5–15 minutes on first setup.\n\n'
              'This page will check again automatically.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 14, color: Colors.grey.shade700),
            ),
            const SizedBox(height: 20),
            const CircularProgressIndicator(),
            if (onRetry != null) ...[
              const SizedBox(height: 20),
              TextButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Check now'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
