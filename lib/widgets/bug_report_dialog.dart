import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/models/bug_report_model.dart';
import 'package:sfcapp/providers/search_provider.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Shows the "Report a Bug" dialog. Call [BugReportDialog.show] from anywhere.
class BugReportDialog extends ConsumerStatefulWidget {
  const BugReportDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const BugReportDialog(),
    );
  }

  @override
  ConsumerState<BugReportDialog> createState() => _BugReportDialogState();
}

class _BugReportDialogState extends ConsumerState<BugReportDialog> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  BugReportSeverity _severity = BugReportSeverity.medium;
  bool _submitting = false;
  bool _submitted = false;

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      final facility = ref.read(selectedFacilityProvider);

      final now = DateTime.now();
      final report = BugReportModel(
        id: '',
        title: _titleCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        submittedByUid: user?.uid ?? 'unknown',
        submittedByEmail: user?.email ?? 'unknown',
        facilityId: facility?.id,
        facilityName: facility?.name,
        severity: _severity,
        createdAt: now,
        updatedAt: now,
      );

      await FirebaseFirestore.instance
          .collection('bug_reports')
          .add(report.toFirestore());

      if (mounted) setState(() => _submitted = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to submit: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
        setState(() => _submitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Dialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: _submitted ? _buildSuccess(colorScheme) : _buildForm(theme, colorScheme),
        ),
      ),
    );
  }

  Widget _buildSuccess(ColorScheme colorScheme) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.success.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.check_circle, color: AppTheme.success, size: 40),
        ),
        const SizedBox(height: 16),
        const Text(
          'Bug Report Submitted',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          'Thank you! Our team will review your report and follow up if needed.',
          textAlign: TextAlign.center,
          style: TextStyle(color: colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Done'),
          ),
        ),
      ],
    );
  }

  Widget _buildForm(ThemeData theme, ColorScheme colorScheme) {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.bug_report, color: AppTheme.error, size: 20),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Report a Bug',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.of(context).pop(),
                tooltip: 'Cancel',
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Describe the issue and we\'ll look into it.',
            style: TextStyle(fontSize: 13, color: colorScheme.onSurfaceVariant),
          ),
          const SizedBox(height: 20),
          TextFormField(
            controller: _titleCtrl,
            decoration: const InputDecoration(
              labelText: 'Short title *',
              hintText: 'e.g. Payment page crashes on submit',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Please enter a title' : null,
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 14),
          TextFormField(
            controller: _descCtrl,
            decoration: const InputDecoration(
              labelText: 'Description *',
              hintText: 'Steps to reproduce, what you expected, what happened…',
              border: OutlineInputBorder(),
              alignLabelWithHint: true,
            ),
            maxLines: 5,
            validator: (v) =>
                (v == null || v.trim().length < 10) ? 'Please provide more detail' : null,
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Text('Severity:', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
              const SizedBox(width: 12),
              ..._severityOptions(colorScheme),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _submitting ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                onPressed: _submitting ? null : _submit,
                icon: _submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send, size: 16),
                label: Text(_submitting ? 'Submitting…' : 'Submit Report'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.error,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  List<Widget> _severityOptions(ColorScheme colorScheme) {
    const options = [
      (BugReportSeverity.low, 'Low', Colors.green),
      (BugReportSeverity.medium, 'Medium', Colors.orange),
      (BugReportSeverity.high, 'High', Colors.deepOrange),
      (BugReportSeverity.critical, 'Critical', Colors.red),
    ];
    return options.map((opt) {
      final (sev, label, color) = opt;
      final selected = _severity == sev;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: GestureDetector(
          onTap: () => setState(() => _severity = sev),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: selected ? color.withValues(alpha: 0.15) : colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: selected ? color : Colors.transparent,
                width: 1.5,
              ),
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                color: selected ? color : colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
      );
    }).toList();
  }
}
