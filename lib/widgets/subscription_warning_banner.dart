import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../services/subscription_guard_service.dart';
import '../theme/app_theme.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';

/// Banner widget that displays subscription warnings (past due, cancelled, etc.)
/// Should be displayed at the top of protected screens
class SubscriptionWarningBanner extends StatefulWidget {
  const SubscriptionWarningBanner({super.key});

  @override
  State<SubscriptionWarningBanner> createState() => _SubscriptionWarningBannerState();
}

class _SubscriptionWarningBannerState extends State<SubscriptionWarningBanner> {
  bool _showWarning = false;
  String? _warningMessage;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _checkWarning();
  }

  Future<void> _checkWarning() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final shouldShow = await SubscriptionGuardService.shouldShowWarning();
      final message = await SubscriptionGuardService.getWarningMessage();

      if (mounted) {
        setState(() {
          _showWarning = shouldShow;
          _warningMessage = message;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _showWarning = false;
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || !_showWarning || _warningMessage == null) {
      return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.warning.withOpacity(0.1),
        border: Border(
          bottom: BorderSide(color: AppTheme.warning.withOpacity(0.3), width: 1),
        ),
      ),
      child: Row(
        children: [
          Icon(
            Icons.warning_amber_rounded,
            color: AppTheme.warning,
            size: 24,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              _warningMessage!,
              style: TextStyle(
                color: AppTheme.warning,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          TextButton(
            onPressed: () {
              context.push(AppRoute.subscription);
            },
            child: const Text(
              'Manage Subscription',
              style: TextStyle(
                color: AppTheme.warning,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            color: AppTheme.warning,
            onPressed: () {
              setState(() {
                _showWarning = false;
              });
            },
            tooltip: 'Dismiss',
          ),
        ],
      ),
    );
  }
}

