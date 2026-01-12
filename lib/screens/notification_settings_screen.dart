import 'package:flutter/material.dart';
import '../widgets/keyboard_scrollable.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter/services.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/facility_service.dart';

/// Screen for managing notification and communication settings
class NotificationSettingsScreen extends StatefulWidget {
  final String facilityId;

  const NotificationSettingsScreen({
    super.key,
    required this.facilityId,
  });

  @override
  State<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}

class _NotificationSettingsScreenState extends State<NotificationSettingsScreen> {
  final _formKey = GlobalKey<FormState>();
  final _paymentReminderDaysController = TextEditingController();
  
  bool _isLoading = false;
  bool _isSaving = false;
  
  // Payment reminder settings
  bool _enablePaymentReminders = true;
  int _paymentReminderDays = 3;
  String _paymentReminderChannel = 'email'; // email, sms, both
  
  // Late payment notice settings
  bool _enableLatePaymentNotices = true;
  String _latePaymentChannel = 'both'; // email, sms, both
  
  // Move-in welcome email settings
  bool _enableWelcomeEmails = true;
  String _welcomeEmailChannel = 'email'; // email, sms, both
  
  // Delinquency notification settings
  bool _enableDelinquencyNotifications = true;
  String _delinquencyChannel = 'email'; // email, sms, both
  
  // Default channel preference
  String _defaultChannel = 'email'; // email, sms, both
  
  // Timing controls
  TimeOfDay _sendTime = const TimeOfDay(hour: 9, minute: 0);

  @override
  void initState() {
    super.initState();
    _loadFacilitySettings();
  }

  @override
  void dispose() {
    _paymentReminderDaysController.dispose();
    super.dispose();
  }

  Future<void> _loadFacilitySettings() async {
    setState(() {
      _isLoading = true;
    });

    try {
      final facility = await FacilityService.getFacility(widget.facilityId);
      if (facility != null && facility.billingSettings != null) {
        final settings = facility.billingSettings!;
        
        setState(() {
          _enablePaymentReminders = settings['enablePaymentReminders'] ?? true;
          _paymentReminderDays = settings['paymentReminderDays'] ?? 3;
          _paymentReminderChannel = settings['paymentReminderChannel'] ?? 'email';
          _enableLatePaymentNotices = settings['enableLatePaymentNotices'] ?? true;
          _latePaymentChannel = settings['latePaymentChannel'] ?? 'both';
          _enableWelcomeEmails = settings['enableWelcomeEmails'] ?? true;
          _welcomeEmailChannel = settings['welcomeEmailChannel'] ?? 'email';
          _enableDelinquencyNotifications = settings['enableDelinquencyNotifications'] ?? true;
          _delinquencyChannel = settings['delinquencyChannel'] ?? 'email';
          _defaultChannel = settings['defaultChannel'] ?? 'email';
          
          // Load send time
          if (settings['sendTimeHour'] != null && settings['sendTimeMinute'] != null) {
            _sendTime = TimeOfDay(
              hour: settings['sendTimeHour'] as int,
              minute: settings['sendTimeMinute'] as int,
            );
          }
          
          _paymentReminderDaysController.text = _paymentReminderDays.toString();
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading settings: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  Future<void> _saveSettings() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSaving = true;
    });

    try {
      // Get current facility
      final facility = await FacilityService.getFacility(widget.facilityId);
      if (facility == null) {
        throw Exception('Facility not found');
      }

      // Update billing settings with notification preferences
      final currentBillingSettings = facility.billingSettings ?? <String, dynamic>{};
      final updatedBillingSettings = {
        ...currentBillingSettings,
        'enablePaymentReminders': _enablePaymentReminders,
        'paymentReminderDays': int.parse(_paymentReminderDaysController.text),
        'paymentReminderChannel': _paymentReminderChannel,
        'enableLatePaymentNotices': _enableLatePaymentNotices,
        'latePaymentChannel': _latePaymentChannel,
        'enableWelcomeEmails': _enableWelcomeEmails,
        'welcomeEmailChannel': _welcomeEmailChannel,
        'enableDelinquencyNotifications': _enableDelinquencyNotifications,
        'delinquencyChannel': _delinquencyChannel,
        'defaultChannel': _defaultChannel,
        'sendTimeHour': _sendTime.hour,
        'sendTimeMinute': _sendTime.minute,
      };

      await FacilityService.updateFacility(
        facilityId: widget.facilityId,
        billingSettings: updatedBillingSettings,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Notification settings saved successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving settings: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      setState(() {
        _isSaving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentRoute = GoRouter.of(context).routeInformationProvider.value.location ?? '/settings/notifications';
    return ModernPageWrapper(
      currentRoute: currentRoute,
      title: 'Notification Settings',
      child: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : Form(
              key: _formKey,
              child: KeyboardScrollable(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Payment Reminder Settings
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.calendar_today, color: AppTheme.primaryBlue),
                                const SizedBox(width: 8),
                                Text(
                                  'Payment Reminders',
                                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            SwitchListTile(
                              title: const Text('Enable Payment Reminders'),
                              subtitle: const Text(
                                'Automatically send email reminders to tenants before payments are due',
                              ),
                              value: _enablePaymentReminders,
                              onChanged: (value) {
                                setState(() {
                                  _enablePaymentReminders = value;
                                });
                              },
                            ),
                            if (_enablePaymentReminders) ...[
                              const SizedBox(height: 8),
                              TextFormField(
                                controller: _paymentReminderDaysController,
                                decoration: const InputDecoration(
                                  labelText: 'Days in Advance',
                                  helperText: 'Number of days before due date to send reminder',
                                  border: OutlineInputBorder(),
                                ),
                                keyboardType: TextInputType.number,
                                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                validator: (value) {
                                  if (value == null || value.isEmpty) {
                                    return 'Please enter number of days';
                                  }
                                  final days = int.tryParse(value);
                                  if (days == null || days < 1 || days > 30) {
                                    return 'Must be between 1 and 30 days';
                                  }
                                  return null;
                                },
                              ),
                              const SizedBox(height: 16),
                              _buildChannelSelector(
                                'Channel',
                                _paymentReminderChannel,
                                (value) => setState(() => _paymentReminderChannel = value!),
                                'How to send payment reminders',
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Late Payment Notices
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.warning, color: AppTheme.error),
                                const SizedBox(width: 8),
                                Text(
                                  'Late Payment Notices',
                                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            SwitchListTile(
                              title: const Text('Enable Late Payment Notices'),
                              subtitle: const Text(
                                'Automatically send notices when payments become overdue',
                              ),
                              value: _enableLatePaymentNotices,
                              onChanged: (value) {
                                setState(() {
                                  _enableLatePaymentNotices = value;
                                });
                              },
                            ),
                            if (_enableLatePaymentNotices) ...[
                              const SizedBox(height: 16),
                              _buildChannelSelector(
                                'Channel',
                                _latePaymentChannel,
                                (value) => setState(() => _latePaymentChannel = value!),
                                'How to send late payment notices',
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Welcome Emails
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.email, color: AppTheme.success),
                                const SizedBox(width: 8),
                                Text(
                                  'Move-In Welcome Emails',
                                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            SwitchListTile(
                              title: const Text('Enable Welcome Emails'),
                              subtitle: const Text(
                                'Automatically send welcome emails to new tenants upon move-in',
                              ),
                              value: _enableWelcomeEmails,
                              onChanged: (value) {
                                setState(() {
                                  _enableWelcomeEmails = value;
                                });
                              },
                            ),
                            if (_enableWelcomeEmails) ...[
                              const SizedBox(height: 16),
                              _buildChannelSelector(
                                'Channel',
                                _welcomeEmailChannel,
                                (value) => setState(() => _welcomeEmailChannel = value!),
                                'How to send welcome messages',
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Delinquency Notifications
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.notifications_active, color: AppTheme.warning),
                                const SizedBox(width: 8),
                                Text(
                                  'Delinquency Notifications',
                                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            SwitchListTile(
                              title: const Text('Enable Delinquency Notifications'),
                              subtitle: const Text(
                                'Automatically notify staff about delinquent accounts and lien proceedings',
                              ),
                              value: _enableDelinquencyNotifications,
                              onChanged: (value) {
                                setState(() {
                                  _enableDelinquencyNotifications = value;
                                });
                              },
                            ),
                            if (_enableDelinquencyNotifications) ...[
                              const SizedBox(height: 16),
                              _buildChannelSelector(
                                'Channel',
                                _delinquencyChannel,
                                (value) => setState(() => _delinquencyChannel = value!),
                                'How to send delinquency notifications',
                              ),
                            ],
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Default Channel Preferences
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Icon(Icons.settings, color: AppTheme.primaryBlue),
                                const SizedBox(width: 8),
                                Text(
                                  'Default Preferences',
                                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                        fontWeight: FontWeight.bold,
                                      ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            _buildChannelSelector(
                              'Default Channel',
                              _defaultChannel,
                              (value) => setState(() => _defaultChannel = value!),
                              'Default channel for notifications without specific settings',
                            ),
                            const SizedBox(height: 16),
                            ListTile(
                              leading: const Icon(Icons.access_time),
                              title: const Text('Send Time'),
                              subtitle: Text(
                                '${_sendTime.format(context)}',
                                style: const TextStyle(fontSize: 16),
                              ),
                              trailing: const Icon(Icons.arrow_forward_ios, size: 16),
                              onTap: () async {
                                final picked = await showTimePicker(
                                  context: context,
                                  initialTime: _sendTime,
                                );
                                if (picked != null) {
                                  setState(() {
                                    _sendTime = picked;
                                  });
                                }
                              },
                            ),
                            const SizedBox(height: 8),
                            Text(
                              'Automated notifications will be sent at this time (in facility timezone)',
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppTheme.textTertiary,
                                  ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),

                    // Save Button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isSaving ? null : _saveSettings,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryBlue,
                          foregroundColor: AppTheme.textOnDark,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                        ),
                        child: _isSaving
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  valueColor: AlwaysStoppedAnimation<Color>(AppTheme.textOnDark),
                                ),
                              )
                            : const Text(
                                'Save Settings',
                                style: TextStyle(fontSize: 16),
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),
                  ],
                ),
              ),
            ),
          ),
    );
  }

  Widget _buildChannelSelector(
    String label,
    String currentValue,
    ValueChanged<String?> onChanged,
    String? helperText,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        if (helperText != null) ...[
          const SizedBox(height: 4),
          Text(
            helperText,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textTertiary,
                ),
          ),
        ],
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(
              value: 'email',
              label: Text('Email'),
              icon: Icon(Icons.email, size: 18),
            ),
            ButtonSegment(
              value: 'sms',
              label: Text('SMS'),
              icon: Icon(Icons.sms, size: 18),
            ),
            ButtonSegment(
              value: 'both',
              label: Text('Both'),
              icon: Icon(Icons.message, size: 18),
            ),
          ],
          selected: {currentValue},
          onSelectionChanged: (Set<String> selected) {
            onChanged(selected.first);
          },
        ),
      ],
    );
  }
}

