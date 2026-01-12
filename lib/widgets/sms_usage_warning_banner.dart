import 'package:flutter/material.dart';
import '../models/sms_usage_model.dart';
import '../services/sms_usage_service.dart';

/// Warning banner that displays when SMS usage is approaching or exceeded
class SMSUsageWarningBanner extends StatefulWidget {
  final String facilityId;
  final String? tenantId;
  final String? accountId;

  const SMSUsageWarningBanner({
    Key? key,
    required this.facilityId,
    this.tenantId,
    this.accountId,
  }) : super(key: key);

  @override
  State<SMSUsageWarningBanner> createState() => _SMSUsageWarningBannerState();
}

class _SMSUsageWarningBannerState extends State<SMSUsageWarningBanner> {
  SMSUsageStatus? _usageStatus;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadUsageStatus();
  }

  Future<void> _loadUsageStatus() async {
    try {
      final status = await SMSUsageService.getUsageStatus(
        facilityId: widget.facilityId,
        tenantId: widget.tenantId,
        accountId: widget.accountId,
      );
      if (mounted) {
        setState(() {
          _usageStatus = status;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading || _usageStatus == null) {
      return const SizedBox.shrink();
    }

    // Only show banner if approaching, exceeded, or extreme
    if (_usageStatus!.state == SMSUsageState.normal) {
      return const SizedBox.shrink();
    }

    Color backgroundColor;
    Color textColor;
    IconData icon;

    switch (_usageStatus!.state) {
      case SMSUsageState.approaching:
        backgroundColor = Colors.orange.shade50;
        textColor = Colors.orange.shade900;
        icon = Icons.warning_amber_rounded;
        break;
      case SMSUsageState.exceeded:
        backgroundColor = Colors.orange.shade100;
        textColor = Colors.orange.shade900;
        icon = Icons.info_outline;
        break;
      case SMSUsageState.extreme:
        backgroundColor = Colors.red.shade50;
        textColor = Colors.red.shade900;
        icon = Icons.error_outline;
        break;
      default:
        return const SizedBox.shrink();
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: backgroundColor,
        border: Border(
          bottom: BorderSide(color: textColor.withOpacity(0.3), width: 1),
        ),
      ),
      child: Row(
        children: [
          Icon(icon, color: textColor, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _usageStatus!.warningMessage ?? 'SMS usage notice',
                  style: TextStyle(
                    color: textColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (_usageStatus!.state == SMSUsageState.approaching ||
                    _usageStatus!.state == SMSUsageState.exceeded)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      _usageStatus!.fairUseExplanation,
                      style: TextStyle(
                        color: textColor.withOpacity(0.8),
                        fontSize: 12,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

