import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Reusable error display widget with development-friendly messaging
class ErrorDisplayWidget extends StatelessWidget {
  final String title;
  final String? error;
  final VoidCallback? onRetry;
  final bool showRetry;
  
  const ErrorDisplayWidget({
    super.key,
    required this.title,
    this.error,
    this.onRetry,
    this.showRetry = true,
  });

  @override
  Widget build(BuildContext context) {
    final isDevelopment = kDebugMode;
    
    return Card(
      margin: const EdgeInsets.all(16),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              isDevelopment ? Icons.warning : Icons.error_outline,
              size: 48,
              color: isDevelopment ? Colors.orange : Colors.red,
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: Theme.of(context).textTheme.titleLarge,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            if (isDevelopment) ...[
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.developer_mode, 
                             size: 16, 
                             color: Colors.orange.shade700),
                        const SizedBox(width: 8),
                        Text(
                          'Development Mode',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.orange.shade700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'This is a development environment. Some features may have limited connectivity. '
                      'In production, all features will work normally.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            if (error != null) ...[
              Text(
                _getDisplayError(error!),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Colors.grey[600],
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
            ],
            if (showRetry && onRetry != null)
              ElevatedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Try Again'),
              ),
          ],
        ),
      ),
    );
  }
  
  String _getDisplayError(String error) {
    if (kDebugMode) {
      // In development, be more descriptive
      if (error.contains('offline') || error.contains('unavailable')) {
        return 'Development environment connectivity issue. Your data is being saved locally.';
      }
      if (error.contains('timeout')) {
        return 'Operation timed out in development mode. This won\'t happen in production.';
      }
    }
    
    // Production-friendly error messages
    if (error.contains('offline') || error.contains('unavailable')) {
      return 'Please check your internet connection and try again.';
    }
    if (error.contains('timeout')) {
      return 'The operation took too long. Please try again.';
    }
    if (error.contains('permission')) {
      return 'You don\'t have permission to perform this action.';
    }
    
    return 'An unexpected error occurred. Please try again.';
  }
}
