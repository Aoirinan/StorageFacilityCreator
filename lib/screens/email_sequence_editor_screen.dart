import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/email_sequence_model.dart';
import '../services/email_sequence_service.dart';
import '../providers/facility_provider.dart';
import '../providers/search_provider.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';

/// Screen for creating/editing email sequences
class EmailSequenceEditorScreen extends ConsumerStatefulWidget {
  final String? sequenceId; // If provided, editing existing sequence

  const EmailSequenceEditorScreen({
    super.key,
    this.sequenceId,
  });

  @override
  ConsumerState<EmailSequenceEditorScreen> createState() => _EmailSequenceEditorScreenState();
}

class _EmailSequenceEditorScreenState extends ConsumerState<EmailSequenceEditorScreen> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  
  SequenceTriggerType _selectedTriggerType = SequenceTriggerType.manualStart;
  List<EmailSequenceStep> _steps = [];
  bool _isLoading = false;
  EmailSequence? _existingSequence;

  @override
  void initState() {
    super.initState();
    if (widget.sequenceId != null) {
      _loadSequence();
    } else {
      // Add initial step
      _steps.add(_createEmptyStep(1));
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _loadSequence() async {
    if (widget.sequenceId == null) return;

    setState(() {
      _isLoading = true;
    });

    try {
      final selectedFacility = ref.read(selectedFacilityProvider);
      final facilityId = selectedFacility?.id;
      if (facilityId == null) {
        throw Exception('No facility selected');
      }

      final sequences = await EmailSequenceService.getEmailSequences(facilityId);
      final sequence = sequences.firstWhere((s) => s.id == widget.sequenceId);

      setState(() {
        _existingSequence = sequence;
        _nameController.text = sequence.name;
        _descriptionController.text = sequence.description ?? '';
        _selectedTriggerType = sequence.triggerType;
        _steps = List.from(sequence.steps);
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading sequence: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  EmailSequenceStep _createEmptyStep(int order) {
    return EmailSequenceStep(
      order: order,
      subject: '',
      htmlBody: '',
      delayDays: order == 1 ? 0 : 1,
    );
  }

  Future<void> _saveSequence() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_steps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please add at least one step to the sequence'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    // Validate steps
    for (int i = 0; i < _steps.length; i++) {
      final step = _steps[i];
      if (step.subject.isEmpty || step.htmlBody.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Step ${i + 1} is incomplete. Please fill in subject and body.'),
            backgroundColor: AppTheme.error,
          ),
        );
        return;
      }
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
      if (widget.sequenceId != null && _existingSequence != null) {
        // Update existing sequence
        await EmailSequenceService.updateEmailSequence(
          facilityId: facilityId,
          sequenceId: widget.sequenceId!,
          name: _nameController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          triggerType: _selectedTriggerType,
          steps: _steps,
        );
      } else {
        // Create new sequence
        await EmailSequenceService.createEmailSequence(
          facilityId: facilityId,
          name: _nameController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          triggerType: _selectedTriggerType,
          steps: _steps,
        );
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Sequence saved successfully')),
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
            content: Text('Error saving sequence: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading && _existingSequence == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(widget.sequenceId != null ? 'Edit Sequence' : 'Create Sequence'),
        actions: [
          IconButton(
            icon: const Icon(Icons.save),
            onPressed: _saveSequence,
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
                        'Basic Information',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Sequence Name *',
                          border: OutlineInputBorder(),
                          helperText: 'e.g., Welcome Series, Move-In Guide',
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Please enter a sequence name';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: _descriptionController,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                          border: OutlineInputBorder(),
                          helperText: 'Optional description of this sequence',
                        ),
                        maxLines: 3,
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<SequenceTriggerType>(
                        value: _selectedTriggerType,
                        decoration: const InputDecoration(
                          labelText: 'Trigger Type *',
                          border: OutlineInputBorder(),
                        ),
                        items: SequenceTriggerType.values.map((type) {
                          return DropdownMenuItem(
                            value: type,
                            child: Text(_formatTriggerType(type)),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _selectedTriggerType = value;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Steps
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Email Steps',
                            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add),
                            onPressed: () {
                              setState(() {
                                _steps.add(_createEmptyStep(_steps.length + 1));
                              });
                            },
                            tooltip: 'Add Step',
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      ...List.generate(_steps.length, (index) {
                        return _buildStepEditor(index);
                      }),
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

  Widget _buildStepEditor(int index) {
    final step = _steps[index];
    
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      color: AppTheme.backgroundSecondary,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Text(
                  'Step ${step.order}',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const Spacer(),
                if (_steps.length > 1)
                  IconButton(
                    icon: const Icon(Icons.delete, color: AppTheme.error),
                    onPressed: () {
                      setState(() {
                        _steps.removeAt(index);
                        // Reorder steps
                        for (int i = 0; i < _steps.length; i++) {
                          _steps[i] = EmailSequenceStep(
                            order: i + 1,
                            emailTemplateId: _steps[i].emailTemplateId,
                            subject: _steps[i].subject,
                            htmlBody: _steps[i].htmlBody,
                            textBody: _steps[i].textBody,
                            delayDays: _steps[i].delayDays,
                            delayTime: _steps[i].delayTime,
                            metadata: _steps[i].metadata,
                          );
                        }
                      });
                    },
                    tooltip: 'Remove Step',
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: TextFormField(
                    initialValue: step.delayDays.toString(),
                    decoration: InputDecoration(
                      labelText: 'Delay (days)',
                      border: const OutlineInputBorder(),
                      helperText: index == 0 ? 'Days after trigger' : 'Days after previous step',
                    ),
                    keyboardType: TextInputType.number,
                    onChanged: (value) {
                      final delay = int.tryParse(value) ?? 0;
                      _steps[index] = EmailSequenceStep(
                        order: step.order,
                        emailTemplateId: step.emailTemplateId,
                        subject: step.subject,
                        htmlBody: step.htmlBody,
                        textBody: step.textBody,
                        delayDays: delay,
                        delayTime: step.delayTime,
                        metadata: step.metadata,
                      );
                    },
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: TextFormField(
                    initialValue: step.delayTime ?? '',
                    decoration: const InputDecoration(
                      labelText: 'Time (HH:mm)',
                      border: OutlineInputBorder(),
                      helperText: 'Optional send time',
                    ),
                    onChanged: (value) {
                      _steps[index] = EmailSequenceStep(
                        order: step.order,
                        emailTemplateId: step.emailTemplateId,
                        subject: step.subject,
                        htmlBody: step.htmlBody,
                        textBody: step.textBody,
                        delayDays: step.delayDays,
                        delayTime: value.trim().isEmpty ? null : value.trim(),
                        metadata: step.metadata,
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              initialValue: step.subject,
              decoration: const InputDecoration(
                labelText: 'Email Subject *',
                border: OutlineInputBorder(),
              ),
              onChanged: (value) {
                _steps[index] = EmailSequenceStep(
                  order: step.order,
                  emailTemplateId: step.emailTemplateId,
                  subject: value,
                  htmlBody: step.htmlBody,
                  textBody: step.textBody,
                  delayDays: step.delayDays,
                  delayTime: step.delayTime,
                  metadata: step.metadata,
                );
              },
            ),
            const SizedBox(height: 16),
            TextFormField(
              initialValue: step.htmlBody,
              decoration: const InputDecoration(
                labelText: 'Email Body (HTML) *',
                border: OutlineInputBorder(),
                helperText: 'You can use variables like {{tenantName}}, {{facilityName}}',
              ),
              maxLines: 8,
              onChanged: (value) {
                _steps[index] = EmailSequenceStep(
                  order: step.order,
                  emailTemplateId: step.emailTemplateId,
                  subject: step.subject,
                  htmlBody: value,
                  textBody: step.textBody,
                  delayDays: step.delayDays,
                  delayTime: step.delayTime,
                  metadata: step.metadata,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _formatTriggerType(SequenceTriggerType type) {
    switch (type) {
      case SequenceTriggerType.tenantCreated:
        return 'When Tenant is Created';
      case SequenceTriggerType.moveInCompleted:
        return 'When Move-In is Completed';
      case SequenceTriggerType.contractSigned:
        return 'When Contract is Signed';
      case SequenceTriggerType.paymentReceived:
        return 'When Payment is Received';
      case SequenceTriggerType.manualStart:
        return 'Manual Start';
      case SequenceTriggerType.custom:
        return 'Custom Trigger';
    }
  }
}

