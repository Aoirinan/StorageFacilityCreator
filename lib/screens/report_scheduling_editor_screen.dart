import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/scheduled_report_model.dart';
import '../services/report_scheduling_service.dart';
import '../providers/facility_provider.dart';
import '../providers/search_provider.dart';
import '../theme/app_theme.dart';

/// Screen for creating/editing scheduled reports
class ReportSchedulingEditorScreen extends ConsumerStatefulWidget {
  final String? scheduleId; // If provided, editing existing schedule

  const ReportSchedulingEditorScreen({
    super.key,
    this.scheduleId,
  });

  @override
  ConsumerState<ReportSchedulingEditorScreen> createState() => _ReportSchedulingEditorScreenState();
}

class _ReportSchedulingEditorScreenState extends ConsumerState<ReportSchedulingEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _recipientsController = TextEditingController(); // Comma-separated emails
  final _scheduleTimeController = TextEditingController(text: '09:00');
  
  ScheduledReportType _selectedReportType = ScheduledReportType.financial;
  ReportScheduleFrequency _selectedFrequency = ReportScheduleFrequency.monthly;
  ReportExportFormat _selectedFormat = ReportExportFormat.csv;
  String? _scheduleDay;
  bool _isLoading = false;
  ScheduledReport? _existingSchedule;

  @override
  void initState() {
    super.initState();
    if (widget.scheduleId != null) {
      _loadSchedule();
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _recipientsController.dispose();
    _scheduleTimeController.dispose();
    super.dispose();
  }

  Future<void> _loadSchedule() async {
    if (widget.scheduleId == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final selectedFacility = ref.read(selectedFacilityProvider);
      final facilityId = selectedFacility?.id;
      if (facilityId == null) {
        throw Exception('No facility selected');
      }

      final schedules = await ReportSchedulingService.getScheduledReports(facilityId);
      final schedule = schedules.firstWhere((s) => s.id == widget.scheduleId);

      setState(() {
        _existingSchedule = schedule;
        _nameController.text = schedule.name;
        _recipientsController.text = schedule.recipients.join(', ');
        _selectedReportType = schedule.reportType;
        _selectedFrequency = schedule.frequency;
        _selectedFormat = schedule.format;
        _scheduleDay = schedule.scheduleDay;
        _scheduleTimeController.text = schedule.scheduleTime ?? '09:00';
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading schedule: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  Future<void> _saveSchedule() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    final recipients = _recipientsController.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    if (recipients.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter at least one recipient email address'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    final selectedFacility = ref.read(selectedFacilityProvider);
    final facilityId = selectedFacility?.id;
    if (facilityId == null || facilityId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select a facility'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    setState(() {
      _isLoading = true;
    });

    try {
      if (widget.scheduleId != null && _existingSchedule != null) {
        // Update existing schedule
        await ReportSchedulingService.updateScheduledReport(
          facilityId: facilityId,
          reportId: widget.scheduleId!,
          name: _nameController.text.trim(),
          reportType: _selectedReportType,
          frequency: _selectedFrequency,
          recipients: recipients,
          format: _selectedFormat,
          scheduleDay: _scheduleDay,
          scheduleTime: _scheduleTimeController.text.trim(),
        );
      } else {
        // Create new schedule
        await ReportSchedulingService.createScheduledReport(
          facilityId: facilityId,
          name: _nameController.text.trim(),
          reportType: _selectedReportType,
          frequency: _selectedFrequency,
          recipients: recipients,
          format: _selectedFormat,
          scheduleDay: _scheduleDay,
          scheduleTime: _scheduleTimeController.text.trim(),
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Schedule saved successfully')),
        );
        context.pop();
      }
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving schedule: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && _existingSchedule == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.scheduleId != null ? 'Edit Schedule' : 'Schedule Report'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saveSchedule,
            tooltip: 'Save',
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Basic Information
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Report Settings',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Schedule Name *',
                          border: OutlineInputBorder(),
                          helperText: 'e.g., Monthly Financial Report',
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a schedule name';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<ScheduledReportType>(
                        value: _selectedReportType,
                        decoration: const InputDecoration(
                          labelText: 'Report Type *',
                          border: OutlineInputBorder(),
                        ),
                        items: ScheduledReportType.values.map((type) {
                          return DropdownMenuItem(
                            value: type,
                            child: Text(_formatReportType(type)),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _selectedReportType = value;
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<ReportExportFormat>(
                        value: _selectedFormat,
                        decoration: const InputDecoration(
                          labelText: 'Export Format *',
                          border: OutlineInputBorder(),
                        ),
                        items: ReportExportFormat.values.map((format) {
                          return DropdownMenuItem(
                            value: format,
                            child: Text(format.name.toUpperCase()),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _selectedFormat = value;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Schedule Settings
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Schedule Settings',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<ReportScheduleFrequency>(
                        value: _selectedFrequency,
                        decoration: const InputDecoration(
                          labelText: 'Frequency *',
                          border: OutlineInputBorder(),
                        ),
                        items: ReportScheduleFrequency.values.map((frequency) {
                          return DropdownMenuItem(
                            value: frequency,
                            child: Text(_formatFrequency(frequency)),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _selectedFrequency = value;
                              _scheduleDay = null; // Reset day when frequency changes
                            });
                          }
                        },
                      ),
                      if (_selectedFrequency == ReportScheduleFrequency.weekly) ...[
                        const SizedBox(height: 16),
                        DropdownButtonFormField<String>(
                          value: _scheduleDay,
                          decoration: const InputDecoration(
                            labelText: 'Day of Week *',
                            border: OutlineInputBorder(),
                          ),
                          items: [
                            'Monday',
                            'Tuesday',
                            'Wednesday',
                            'Thursday',
                            'Friday',
                            'Saturday',
                            'Sunday',
                          ].map((day) {
                            return DropdownMenuItem(
                              value: day,
                              child: Text(day),
                            );
                          }).toList(),
                          onChanged: (value) {
                            setState(() {
                              _scheduleDay = value;
                            });
                          },
                        ),
                      ],
                      if (_selectedFrequency == ReportScheduleFrequency.monthly) ...[
                        const SizedBox(height: 16),
                        TextFormField(
                          initialValue: _scheduleDay ?? '1',
                          decoration: const InputDecoration(
                            labelText: 'Day of Month *',
                            border: OutlineInputBorder(),
                            helperText: 'Enter day (1-31)',
                          ),
                          keyboardType: TextInputType.number,
                          onChanged: (value) {
                            setState(() {
                              _scheduleDay = value;
                            });
                          },
                          validator: (value) {
                            if (value == null || value.isEmpty) {
                              return 'Please enter a day';
                            }
                            final day = int.tryParse(value);
                            if (day == null || day < 1 || day > 31) {
                              return 'Please enter a valid day (1-31)';
                            }
                            return null;
                          },
                        ),
                      ],
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _scheduleTimeController,
                        decoration: const InputDecoration(
                          labelText: 'Send Time *',
                          border: OutlineInputBorder(),
                          helperText: 'Format: HH:mm (e.g., 09:00)',
                          prefixIcon: Icon(Icons.access_time),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a time';
                          }
                          // Simple validation for HH:mm format
                          if (!RegExp(r'^\d{2}:\d{2}$').hasMatch(value.trim())) {
                            return 'Please use HH:mm format (e.g., 09:00)';
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Recipients
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        'Recipients',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _recipientsController,
                        decoration: const InputDecoration(
                          labelText: 'Email Addresses *',
                          border: OutlineInputBorder(),
                          helperText: 'Enter email addresses separated by commas',
                          prefixIcon: Icon(Icons.email),
                        ),
                        maxLines: 3,
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter at least one email address';
                          }
                          final emails = value.split(',').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
                          if (emails.isEmpty) {
                            return 'Please enter at least one email address';
                          }
                          // Basic email validation
                          for (final email in emails) {
                            if (!RegExp(r'^[^@]+@[^@]+\.[^@]+').hasMatch(email)) {
                              return 'Invalid email address: $email';
                            }
                          }
                          return null;
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatReportType(ScheduledReportType type) {
    switch (type) {
      case ScheduledReportType.financial:
        return 'Financial Report';
      case ScheduledReportType.arAging:
        return 'AR Aging Report';
      case ScheduledReportType.occupancy:
        return 'Occupancy Report';
      case ScheduledReportType.delinquency:
        return 'Delinquency Report';
      case ScheduledReportType.deposits:
        return 'Deposits Report';
      case ScheduledReportType.communicationAnalytics:
        return 'Communication Analytics';
      case ScheduledReportType.all:
        return 'All Reports';
    }
  }

  String _formatFrequency(ReportScheduleFrequency frequency) {
    switch (frequency) {
      case ReportScheduleFrequency.daily:
        return 'Daily';
      case ReportScheduleFrequency.weekly:
        return 'Weekly';
      case ReportScheduleFrequency.monthly:
        return 'Monthly';
      case ReportScheduleFrequency.quarterly:
        return 'Quarterly';
      case ReportScheduleFrequency.custom:
        return 'Custom';
    }
  }
}

