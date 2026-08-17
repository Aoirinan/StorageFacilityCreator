import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/custom_domain_service.dart';
import '../theme/app_theme.dart';

/// Connect a facility's own domain to its website.
///
/// This widget is the product surface for the whole feature. SFC can never make
/// the DNS change for an operator — registrars text a verification code to the
/// domain owner for every single edit — so support cannot rescue someone who is
/// stuck. Whether a facility ever goes live comes down to whether the rows
/// below are clear enough to copy without help.
///
/// Hence: exact values with copy buttons rather than prose, only the rows still
/// outstanding by default, per-hostname progress so "it half works" is visible,
/// and no claim of success until every hostname is actually serving.
class CustomDomainPanel extends StatefulWidget {
  final String facilityId;

  /// Domain already saved in Website Setup, used as the initial value.
  final String? initialDomain;

  const CustomDomainPanel({
    super.key,
    required this.facilityId,
    this.initialDomain,
  });

  @override
  State<CustomDomainPanel> createState() => _CustomDomainPanelState();
}

class _CustomDomainPanelState extends State<CustomDomainPanel> {
  final _domainController = TextEditingController();
  CustomDomainState? _state;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _domainController.text = widget.initialDomain ?? '';
    if ((widget.initialDomain ?? '').isNotEmpty) {
      // Show real status on open rather than a stale "not connected".
      _run(() => CustomDomainService.refresh(facilityId: widget.facilityId));
    }
  }

  @override
  void dispose() {
    _domainController.dispose();
    super.dispose();
  }

  Future<void> _run(Future<CustomDomainState> Function() action) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final state = await action();
      if (!mounted) return;
      setState(() => _state = state);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = _friendlyError(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _friendlyError(Object error) {
    final message = error is FirebaseFunctionsException
        ? (error.message ?? error.code)
        : error.toString();
    return message.replaceFirst(RegExp(r'^\[.*?\]\s*'), '');
  }

  void _copy(String value, String label) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Copied $label'), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final state = _state;
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.language, size: 20),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Your own domain',
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
                  ),
                ),
                if (state != null) _StatusChip(status: state.status),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'Point a domain you already own at this website. You make the DNS '
              'changes at your registrar — we cannot do it for you, because they '
              'text a verification code to the domain owner for every change.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 14),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: TextField(
                    controller: _domainController,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Domain',
                      hintText: 'yourfacility.com',
                      helperText: 'Just the domain — no https:// and no trailing path.',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: FilledButton(
                    onPressed: _busy
                        ? null
                        : () => _run(
                              () => CustomDomainService.connect(
                                facilityId: widget.facilityId,
                                domain: _domainController.text.trim(),
                              ),
                            ),
                    child: Text(state?.isConfigured == true ? 'Reconnect' : 'Connect'),
                  ),
                ),
              ],
            ),
            if (_busy) ...[
              const SizedBox(height: 12),
              const LinearProgressIndicator(minHeight: 2),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              _Callout(
                icon: Icons.error_outline,
                color: AppTheme.error,
                child: Text(_error!, style: const TextStyle(fontSize: 13)),
              ),
            ],
            if (state != null) ...[
              const SizedBox(height: 16),
              _buildStatusBody(state),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildStatusBody(CustomDomainState state) {
    if (state.live) {
      return _Callout(
        icon: Icons.check_circle_outline,
        color: Colors.green.shade700,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Your domain is live.',
              style: TextStyle(fontWeight: FontWeight.w600, fontSize: 13),
            ),
            const SizedBox(height: 4),
            for (final host in state.hostnames)
              Text('https://${host.hostname}', style: const TextStyle(fontSize: 13)),
          ],
        ),
      );
    }

    final outstanding = state.outstandingRecords;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (outstanding.isNotEmpty) ...[
          Text(
            'Add these ${outstanding.length} record${outstanding.length == 1 ? '' : 's'} '
            'at your registrar',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          const SizedBox(height: 2),
          const Text(
            'Copy each value exactly. Changes usually take a few minutes, but can '
            'take up to 24 hours.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 10),
          for (final record in outstanding) ...[
            _RecordRow(record: record, onCopy: _copy),
            const SizedBox(height: 8),
          ],
        ] else ...[
          _Callout(
            icon: Icons.hourglass_empty,
            color: AppTheme.primaryBlue,
            child: const Text(
              'DNS looks right. We are waiting on the certificate to finish — '
              'nothing more for you to do.',
              style: TextStyle(fontSize: 13),
            ),
          ),
        ],
        if (state.hostnames.isNotEmpty) ...[
          const SizedBox(height: 12),
          for (final host in state.hostnames)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                children: [
                  Icon(
                    host.status == 'connected'
                        ? Icons.check_circle
                        : Icons.radio_button_unchecked,
                    size: 15,
                    color: host.status == 'connected'
                        ? Colors.green.shade700
                        : AppTheme.textSecondary,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      host.hostname,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  Text(
                    _statusLabel(host.status),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 10),
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _run(
                    () => CustomDomainService.refresh(facilityId: widget.facilityId),
                  ),
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Check progress'),
        ),
      ],
    );
  }
}

String _statusLabel(String status) {
  switch (status) {
    case 'connected':
      return 'Live';
    case 'provisioning_ssl':
      return 'Securing';
    case 'pending_dns':
      return 'Waiting on DNS';
    case 'certificate_issue':
      return 'Certificate problem';
    case 'not_configured':
      return 'Not set up';
    default:
      return status;
  }
}

class _StatusChip extends StatelessWidget {
  final String status;
  const _StatusChip({required this.status});

  @override
  Widget build(BuildContext context) {
    final connected = status == 'connected';
    final problem = status == 'certificate_issue';
    final color = connected
        ? Colors.green.shade700
        : problem
            ? AppTheme.error
            : AppTheme.primaryBlue;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        _statusLabel(status),
        style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// One DNS row, with each field independently copyable.
///
/// Registrar forms have separate Type / Name / Value inputs, so copying the
/// whole row as one string would force the operator to retype pieces of it —
/// which is exactly where transcription mistakes happen.
class _RecordRow extends StatelessWidget {
  final CustomDomainRecord record;
  final void Function(String value, String label) onCopy;

  const _RecordRow({required this.record, required this.onCopy});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        border: Border.all(color: Colors.grey.shade300),
        borderRadius: BorderRadius.circular(8),
        color: Colors.grey.shade50,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _field('Type', record.type, copyable: false),
          const SizedBox(height: 6),
          _field('Name', record.name),
          const SizedBox(height: 6),
          _field('Value', record.value),
        ],
      ),
    );
  }

  Widget _field(String label, String value, {bool copyable = true}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 52,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: const TextStyle(fontSize: 13, fontFamily: 'monospace'),
          ),
        ),
        if (copyable)
          IconButton(
            onPressed: () => onCopy(value, label.toLowerCase()),
            icon: const Icon(Icons.copy, size: 16),
            visualDensity: VisualDensity.compact,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            padding: EdgeInsets.zero,
            tooltip: 'Copy $label',
          ),
      ],
    );
  }
}

class _Callout extends StatelessWidget {
  final IconData icon;
  final Color color;
  final Widget child;

  const _Callout({required this.icon, required this.color, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(child: child),
        ],
      ),
    );
  }
}
