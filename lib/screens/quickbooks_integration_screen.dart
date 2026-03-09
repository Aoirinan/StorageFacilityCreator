import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:sfcapp/models/facility_model.dart';
import 'package:sfcapp/services/quickbooks_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/error_message_helper.dart';
import 'package:sfcapp/utils/open_url_stub.dart'
    if (dart.library.html) 'package:sfcapp/utils/open_url_web.dart' as open_url;

class QuickBooksIntegrationScreen extends StatefulWidget {
  final FacilityModel facility;

  const QuickBooksIntegrationScreen({
    super.key,
    required this.facility,
  });

  @override
  State<QuickBooksIntegrationScreen> createState() =>
      _QuickBooksIntegrationScreenState();
}

class _QuickBooksIntegrationScreenState extends State<QuickBooksIntegrationScreen> {
  bool _loading = false;
  bool _busy = false;
  bool _autoCompleting = false;
  Map<String, dynamic>? _status;

  final TextEditingController _stateController = TextEditingController();
  final TextEditingController _codeController = TextEditingController();
  final TextEditingController _realmController = TextEditingController();
  final TextEditingController _invoiceIdController = TextEditingController();
  final TextEditingController _paymentIdController = TextEditingController();
  final TextEditingController _paymentInvoiceIdController =
      TextEditingController();
  bool _autoFilledFromUrl = false;
  bool _attemptedAutoComplete = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initialize();
    });
  }

  @override
  void didUpdateWidget(covariant QuickBooksIntegrationScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.facility.id != widget.facility.id) {
      _stateController.clear();
      _codeController.clear();
      _realmController.clear();
      _invoiceIdController.clear();
      _paymentIdController.clear();
      _paymentInvoiceIdController.clear();
      _status = null;
      _autoFilledFromUrl = false;
      _attemptedAutoComplete = false;
      _initialize();
    }
  }

  @override
  void dispose() {
    _stateController.dispose();
    _codeController.dispose();
    _realmController.dispose();
    _invoiceIdController.dispose();
    _paymentIdController.dispose();
    _paymentInvoiceIdController.dispose();
    super.dispose();
  }

  Future<void> _refreshStatus() async {
    setState(() => _loading = true);
    try {
      final status = await QuickBooksService.getConnectionStatus(
        facilityId: widget.facility.id,
      );
      if (!mounted) return;
      setState(() => _status = status);
    } catch (e) {
      _showError(e, prefix: 'Status check failed');
    } finally {
      if (mounted) {
        setState(() => _loading = false);
      }
    }
  }

  Future<void> _initialize() async {
    _prefillOAuthFromUrl();
    await _refreshStatus();
    await _maybeAutoCompleteConnect();
  }

  void _prefillOAuthFromUrl() {
    if (_autoFilledFromUrl) return;
    final params = Uri.base.queryParameters;
    final code = params['code']?.trim() ?? '';
    final realmId = params['realmId']?.trim() ?? '';
    final state = params['state']?.trim() ?? '';
    if (code.isEmpty && realmId.isEmpty && state.isEmpty) {
      return;
    }
    _autoFilledFromUrl = true;
    if (state.isNotEmpty) _stateController.text = state;
    if (code.isNotEmpty) _codeController.text = code;
    if (realmId.isNotEmpty) _realmController.text = realmId;
  }

  Future<void> _maybeAutoCompleteConnect() async {
    if (_attemptedAutoComplete) return;
    final code = _codeController.text.trim();
    final realmId = _realmController.text.trim();
    final state = _stateController.text.trim();
    if (code.isEmpty || realmId.isEmpty || state.isEmpty) return;
    if ((_status?['connected'] == true)) return;
    _attemptedAutoComplete = true;
    setState(() => _autoCompleting = true);
    try {
      await QuickBooksService.completeConnect(
        facilityId: widget.facility.id,
        code: code,
        realmId: realmId,
        state: state,
      );
      if (!mounted) return;
      _showSuccess('QuickBooks connected successfully.');
      await _refreshStatus();
    } catch (e) {
      // Keep manual fallback available if auto-complete fails.
      _showError(e, prefix: 'Auto-complete connection failed');
    } finally {
      if (mounted) setState(() => _autoCompleting = false);
    }
  }

  Future<void> _startConnectFlow() async {
    setState(() => _busy = true);
    try {
      final result = await QuickBooksService.getConnectUrl(
        facilityId: widget.facility.id,
      );
      final authUrl = (result['authUrl'] as String?) ?? '';
      final state = (result['state'] as String?) ?? '';
      if (state.isNotEmpty) {
        _stateController.text = state;
      }
      if (authUrl.isEmpty) {
        throw Exception('QuickBooks authorization URL was not returned');
      }
      if (kIsWeb) {
        open_url.openUrlInBrowserWeb(authUrl);
      } else {
        if (!mounted) return;
        await showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Open QuickBooks'),
            content: SelectableText(authUrl),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          ),
        );
        if (!mounted) return;
      }
      if (!mounted) return;
      _showSuccess('QuickBooks connect opened. Finish OAuth, then paste code/realm/state below.');
    } catch (e) {
      _showError(e, prefix: 'Could not start QuickBooks connect');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _completeConnect() async {
    final code = _codeController.text.trim();
    final realmId = _realmController.text.trim();
    final state = _stateController.text.trim();
    if (code.isEmpty || realmId.isEmpty || state.isEmpty) {
      _showSnack('Enter OAuth code, realmId, and state first.', isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await QuickBooksService.completeConnect(
        facilityId: widget.facility.id,
        code: code,
        realmId: realmId,
        state: state,
      );
      _showSuccess('QuickBooks connected for ${widget.facility.name}.');
      await _refreshStatus();
    } catch (e) {
      _showError(e, prefix: 'QuickBooks connection failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disconnect() async {
    setState(() => _busy = true);
    try {
      await QuickBooksService.disconnect(facilityId: widget.facility.id);
      _showSuccess('QuickBooks disconnected.');
      await _refreshStatus();
    } catch (e) {
      _showError(e, prefix: 'Disconnect failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleAutoSync(bool enabled) async {
    setState(() => _busy = true);
    try {
      await QuickBooksService.setAutoSync(
        facilityId: widget.facility.id,
        enabled: enabled,
      );
      await _refreshStatus();
      _showSuccess(enabled
          ? 'Automatic QuickBooks sync enabled.'
          : 'Automatic QuickBooks sync disabled.');
    } catch (e) {
      _showError(e, prefix: 'Could not update auto-sync');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncInvoice() async {
    final invoiceId = _invoiceIdController.text.trim();
    if (invoiceId.isEmpty) {
      _showSnack('Enter an invoice ID to sync.', isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await QuickBooksService.syncInvoice(
        facilityId: widget.facility.id,
        invoiceId: invoiceId,
      );
      _showSuccess(
        'Invoice synced. QBO invoice ID: ${result['quickbooksInvoiceId'] ?? 'unknown'}',
      );
      await _refreshStatus();
    } catch (e) {
      _showError(e, prefix: 'Invoice sync failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _syncPayment() async {
    final paymentId = _paymentIdController.text.trim();
    final invoiceId = _paymentInvoiceIdController.text.trim();
    if (paymentId.isEmpty) {
      _showSnack('Enter a payment ID to sync.', isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      final result = await QuickBooksService.syncPayment(
        facilityId: widget.facility.id,
        paymentId: paymentId,
        invoiceId: invoiceId.isEmpty ? null : invoiceId,
      );
      _showSuccess(
        'Payment synced. QBO payment ID: ${result['quickbooksPaymentId'] ?? 'unknown'}',
      );
      await _refreshStatus();
    } catch (e) {
      _showError(e, prefix: 'Payment sync failed');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showError(Object error, {required String prefix}) {
    final message = ErrorMessageHelper.getUserFriendlyMessage(error);
    _showSnack(
      message.isEmpty ? prefix : '$prefix: $message',
      isError: true,
    );
  }

  void _showSuccess(String message) {
    _showSnack(message, isError: false);
  }

  void _showSnack(String message, {required bool isError}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? AppTheme.error : AppTheme.success,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final connected = _status?['connected'] == true;
    final autoSyncEnabled = (_status?['autoSyncEnabled'] ?? true) == true;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'QuickBooks Online',
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Connect ${widget.facility.name} to QuickBooks to sync invoices and payments.',
                    style: const TextStyle(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ElevatedButton.icon(
                        onPressed: (_busy || _loading) ? null : _startConnectFlow,
                        icon: const Icon(Icons.link),
                        label: const Text('Connect QuickBooks'),
                      ),
                      OutlinedButton.icon(
                        onPressed: (_busy || _loading) ? null : _refreshStatus,
                        icon: _loading
                            ? const SizedBox(
                                width: 14,
                                height: 14,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh),
                        label: const Text('Refresh Status'),
                      ),
                      OutlinedButton.icon(
                        onPressed:
                            (_busy || _loading || !connected) ? null : _disconnect,
                        icon: const Icon(Icons.link_off),
                        label: const Text('Disconnect'),
                      ),
                    ],
                  ),
                  if (_autoCompleting) ...[
                    const SizedBox(height: 12),
                    const Row(
                      children: [
                        SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                        SizedBox(width: 8),
                        Text(
                          'Finishing QuickBooks connection...',
                          style: TextStyle(color: AppTheme.textSecondary),
                        ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Connection Status',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  _statusRow('Connected', connected ? 'Yes' : 'No'),
                  _statusRow('Realm ID', '${_status?['realmId'] ?? '-'}'),
                  _statusRow('Environment', '${_status?['environment'] ?? '-'}'),
                  _statusRow('Auto Sync', autoSyncEnabled ? 'Enabled' : 'Disabled'),
                  _statusRow('Last Sync', '${_status?['lastSyncAt'] ?? '-'}'),
                  _statusRow('Last Sync Status', '${_status?['lastSyncStatus'] ?? '-'}'),
                  if ((_status?['lastSyncError'] ?? '').toString().isNotEmpty)
                    _statusRow('Last Sync Error', '${_status?['lastSyncError']}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Automation', style: TextStyle(fontWeight: FontWeight.w700)),
                  const SizedBox(height: 8),
                  const Text(
                    'When connected, invoices and completed payments sync automatically to QuickBooks.',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    value: autoSyncEnabled,
                    onChanged: (!_busy && !_loading) && connected ? _toggleAutoSync : null,
                    title: const Text('Auto Sync to QuickBooks'),
                    subtitle: const Text('Keep this enabled for hands-off accounting sync.'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: ExpansionTile(
                title: const Text('Advanced / Manual tools'),
                subtitle: const Text('Fallback only - most users should not need this'),
                childrenPadding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                children: [
                  const SizedBox(height: 8),
                  const Text(
                    'If auto-complete did not finish OAuth, paste `code`, `realmId`, and `state` from your redirect URL.',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _stateController,
                    decoration: const InputDecoration(
                      labelText: 'state',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _codeController,
                    decoration: const InputDecoration(
                      labelText: 'code',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _realmController,
                    decoration: const InputDecoration(
                      labelText: 'realmId',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ElevatedButton(
                      onPressed: (_busy || _loading) ? null : _completeConnect,
                      child: const Text('Complete Connection Manually'),
                    ),
                  ),
                  const Text(
                    'Manual Sync',
                    style: TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _invoiceIdController,
                    decoration: const InputDecoration(
                      labelText: 'Invoice ID',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ElevatedButton.icon(
                      onPressed: (_busy || _loading || !connected) ? null : _syncInvoice,
                      icon: const Icon(Icons.receipt_long),
                      label: const Text('Sync Invoice'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _paymentIdController,
                    decoration: const InputDecoration(
                      labelText: 'Payment ID',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _paymentInvoiceIdController,
                    decoration: const InputDecoration(
                      labelText: 'Linked Invoice ID (optional)',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: ElevatedButton.icon(
                      onPressed: (_busy || _loading || !connected) ? null : _syncPayment,
                      icon: const Icon(Icons.payments_outlined),
                      label: const Text('Sync Payment'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 140,
            child: Text(
              '$label:',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
          Expanded(child: SelectableText(value)),
        ],
      ),
    );
  }
}
