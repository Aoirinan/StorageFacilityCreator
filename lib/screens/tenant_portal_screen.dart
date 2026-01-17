import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/tenant_portal_models.dart';
import 'package:sfcapp/providers/tenant_portal_provider.dart';
import 'package:sfcapp/services/stripe_service.dart';
import 'package:sfcapp/services/tenant_portal_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

class TenantPortalScreen extends ConsumerStatefulWidget {
  final TenantPortalLookup lookup;
  final TenantPortalData initialData;

  const TenantPortalScreen({
    super.key,
    required this.lookup,
    required this.initialData,
  });

  @override
  ConsumerState<TenantPortalScreen> createState() => _TenantPortalScreenState();
}

class _TenantPortalScreenState extends ConsumerState<TenantPortalScreen> {
  bool _isProcessingPayment = false;
  bool _appCheckFailureShown = false;

  @override
  void initState() {
    super.initState();
    // Prefetch App Check token to avoid failed-precondition on first load.
    FirebaseAppCheck.instance.getToken().catchError((_) {
      if (mounted && !_appCheckFailureShown) {
        _appCheckFailureShown = true;
        _showAppCheckDialog();
      }
    });
  }

  String _formatCurrency(double amount) => '\$${amount.toStringAsFixed(2)}';

  String _formatDate(DateTime? value) {
    if (value == null) return '—';
    final month = value.month.toString().padLeft(2, '0');
    final day = value.day.toString().padLeft(2, '0');
    final year = value.year;
    return '$month/$day/$year';
  }

  String _formatMethod(String? method) {
    if (method == null || method.isEmpty) {
      return '—';
    }

    final match = PaymentMethod.values.where((m) => m.name == method).toList();
    if (match.isNotEmpty) {
      return match.first.displayName;
    }
    return method;
  }

  Color _statusColor(PaymentStatus status) {
    switch (status) {
      case PaymentStatus.paid:
      case PaymentStatus.completed:
        return AppTheme.success;
      case PaymentStatus.failed:
      case PaymentStatus.cancelled:
        return AppTheme.error;
      case PaymentStatus.refunded:
        return AppTheme.primaryBlueDark;
      default:
        return AppTheme.warning;
    }
  }

  IconData _statusIcon(PaymentStatus status) {
    switch (status) {
      case PaymentStatus.paid:
      case PaymentStatus.completed:
        return Icons.check_circle_outline;
      case PaymentStatus.failed:
        return Icons.error_outline;
      case PaymentStatus.refunded:
        return Icons.undo;
      case PaymentStatus.cancelled:
        return Icons.cancel_outlined;
      default:
        return Icons.schedule;
    }
  }

  Future<void> _manualRefresh() async {
    try {
      // Ensure App Check token is fresh before hitting Functions
      await FirebaseAppCheck.instance.getToken();
      await ref.refresh(tenantPortalProvider(widget.lookup).future);
    } on TenantPortalException catch (error) {
      if (error.code == 'failed-precondition') {
        _showAppCheckDialog();
      } else {
        _showSnack(error.message);
      }
    } catch (_) {
      _showSnack('Unable to refresh portal. Please try again.');
    }
  }

  Future<void> _copyToClipboard(String value, String label) async {
    await Clipboard.setData(ClipboardData(text: value));
    _showSnack('$label copied to clipboard');
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _showAppCheckDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Security Check Required'),
        content: const Text(
          'We couldn\'t verify the app. Please refresh and try again. If this persists, contact support.'
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await FirebaseAppCheck.instance.getToken();
              await _manualRefresh();
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Future<void> _initiatePayment(TenantPortalData data, double amount) async {
    setState(() {
      _isProcessingPayment = true;
    });

    try {
      // Create checkout using portal credentials
      final checkoutUrl = await StripeService.createTenantPortalPaymentCheckout(
        email: widget.lookup.email,
        accessCode: widget.lookup.accessCode,
        amount: amount,
      );

      // Open checkout
      if (kIsWeb) {
        // On web, open in new tab
        final uri = Uri.parse(checkoutUrl);
        final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
        if (!opened) {
          _showSnack('Could not open checkout. Please try again.');
        } else {
          _showSnack('Opening payment checkout in new tab...');
        }
      } else {
        // On mobile, show in WebView dialog
        _showCheckoutWebView(checkoutUrl);
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error initiating payment: $e');
      }
      _showSnack('Error initiating payment. Please try again or contact support.');
    } finally {
      if (mounted) {
        setState(() {
          _isProcessingPayment = false;
        });
      }
    }
  }

  void _showCheckoutWebView(String url) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => Dialog(
        insetPadding: const EdgeInsets.all(16),
        child: Container(
          width: double.infinity,
          height: double.infinity,
          child: Column(
            children: [
              // Header
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.primaryBlue,
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 4,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Row(
                  children: [
                    const Icon(Icons.payment, color: AppTheme.textOnDark),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Complete Payment',
                        style: TextStyle(
                          color: AppTheme.textOnDark,
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.close, color: AppTheme.textOnDark),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              // WebView
              Expanded(
                child: WebViewWidget(
                  controller: WebViewController()
                    ..setJavaScriptMode(JavaScriptMode.unrestricted)
                    ..setNavigationDelegate(
                      NavigationDelegate(
                        onPageFinished: (url) {
                          if (url.contains('success') || url.contains('payment/success')) {
                            // Payment succeeded
                            Navigator.of(context).pop();
                            _handlePaymentSuccess();
                          } else if (url.contains('cancel') || url.contains('payment/cancel')) {
                            // Payment cancelled
                            Navigator.of(context).pop();
                          }
                        },
                      ),
                    )
                    ..loadRequest(Uri.parse(url)),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handlePaymentSuccess() {
    // Refresh portal data
    ref.refresh(tenantPortalProvider(widget.lookup).future);
    _showSnack('Payment successful! Your account will be updated shortly.');
  }

  @override
  Widget build(BuildContext context) {
    final portalAsync = ref.watch(tenantPortalProvider(widget.lookup));
    final data = portalAsync.value ?? widget.initialData;

    if (data == null) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Tenant Portal'),
          backgroundColor: AppTheme.primaryBlueDark,
          foregroundColor: AppTheme.textOnDark,
        ),
        body: portalAsync.when(
          data: (value) => const SizedBox.shrink(),
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, stackTrace) => Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline, color: AppTheme.error, size: 42),
                  const SizedBox(height: 16),
                  Text(
                    error is TenantPortalException
                        ? error.message
                        : 'We could not load your portal right now.',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 16),
                  FilledButton(
                    onPressed: _manualRefresh,
                    child: const Text('Try Again'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final theme = Theme.of(context);

    final bodyChildren = <Widget>[
      if (portalAsync.hasError) _buildErrorBanner(context, portalAsync.error),
      _buildSummaryCard(context, data),
      const SizedBox(height: 16),
      _buildStatsSection(context, data),
      const SizedBox(height: 16),
      _buildFacilityCard(context, data),
      if (data.tenant.contacts.isNotEmpty) ...[
        const SizedBox(height: 16),
        _buildEmergencyContactsCard(context, data),
      ],
      if (data.tenant.vehicles.isNotEmpty) ...[
        const SizedBox(height: 16),
        _buildVehiclesCard(context, data),
      ],
      const SizedBox(height: 16),
      _buildPaymentsCard(context, data),
      const SizedBox(height: 16),
      _buildHelpCard(context, data),
      const SizedBox(height: 16),
      Text(
        'Portal data refreshes each time you return to this page. Facility managers can update your details or reset your access code if needed.',
        style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
      ),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text('${data.facility.name} Portal'),
        backgroundColor: AppTheme.primaryBlueDark,
        foregroundColor: AppTheme.textOnDark,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: portalAsync.isLoading ? null : _manualRefresh,
          ),
        ],
      ),
      body: Stack(
        children: [
          RefreshIndicator(
            onRefresh: () => ref.refresh(tenantPortalProvider(widget.lookup).future),
            child: ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
              children: bodyChildren,
            ),
          ),
          if (portalAsync.isLoading && portalAsync.value != null)
            const Positioned(
              left: 0,
              right: 0,
              top: 0,
              child: LinearProgressIndicator(minHeight: 3),
            ),
        ],
      ),
    );
  }

  Widget _buildErrorBanner(BuildContext context, Object? error) {
    final theme = Theme.of(context);
    String message;
    if (error is TenantPortalException && error.code == 'failed-precondition') {
      message = 'Security check failed. Please retry to continue.';
    } else if (error is TenantPortalException) {
      message = error.message;
    } else {
      message = 'We had trouble keeping this page up to date. Pull to refresh or try again.';
    }

    return Card(
      color: AppTheme.error.withOpacity(0.1),
      child: ListTile(
        leading: Icon(Icons.error_outline, color: AppTheme.error),
        title: Text(
          'Unable to refresh',
          style: theme.textTheme.titleSmall?.copyWith(color: AppTheme.error),
        ),
        subtitle: Text(message),
        trailing: TextButton(
          onPressed: _manualRefresh,
          child: const Text('Retry'),
        ),
      ),
    );
  }

  Widget _buildSummaryCard(BuildContext context, TenantPortalData data) {
    final tenant = data.tenant;
    final stats = data.stats;
    final outstanding = stats.outstandingBalance;
    final isDelinquent = tenant.isDelinquent || outstanding > 0;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tenant.name,
              style: theme.textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _infoChip(Icons.storefront_outlined, 'Unit ${tenant.unitNumber}'),
                _infoChip(Icons.payments_outlined, '${_formatCurrency(tenant.monthlyRate)} / month'),
                _statusChip(isDelinquent, outstanding),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: _summaryLine(
                    context,
                    label: 'Paid through',
                    value: _formatDate(tenant.paidThrough),
                  ),
                ),
                Expanded(
                  child: _summaryLine(
                    context,
                    label: 'Next payment',
                    value: stats.nextDueDate != null
                        ? '${_formatDate(stats.nextDueDate)}'
                            '${stats.nextAmountDue != null ? ' • ${_formatCurrency(stats.nextAmountDue!)}' : ''}'
                        : 'No upcoming payment',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              outstanding > 0
                  ? 'Balance due: ${_formatCurrency(outstanding)}'
                  : 'Your account is current. Thank you!',
              style: theme.textTheme.titleMedium?.copyWith(
                color: outstanding > 0 ? AppTheme.error : AppTheme.success,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (outstanding > 0) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isProcessingPayment ? null : () => _initiatePayment(data, outstanding),
                  icon: _isProcessingPayment
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.payment),
                  label: Text(_isProcessingPayment ? 'Processing...' : 'Pay Now'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    foregroundColor: AppTheme.textOnDark,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
            if (tenant.welcomeMessage != null && tenant.welcomeMessage!.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.primaryBlueDark.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SelectableText(
                  tenant.welcomeMessage!,
                  style: theme.textTheme.bodyMedium,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoChip(IconData icon, String label) {
    return Chip(
      avatar: Icon(icon, size: 18, color: AppTheme.primaryBlueDark),
      backgroundColor: AppTheme.primaryBlueDark.withOpacity(0.08),
      label: Text(label),
      side: BorderSide(color: AppTheme.primaryBlueDark.withOpacity(0.12)),
    );
  }

  Widget _statusChip(bool isDelinquent, double outstanding) {
    final color = isDelinquent ? AppTheme.error : AppTheme.success;
    final icon = isDelinquent ? Icons.warning_amber_outlined : Icons.check_circle_outline;
    final label = isDelinquent
        ? (outstanding > 0 ? 'Balance Due' : 'Past Due')
        : 'Account Current';

    return Chip(
      avatar: Icon(icon, size: 18, color: color),
      backgroundColor: color.withOpacity(0.08),
      side: BorderSide(color: color.withOpacity(0.12)),
      label: Text(
        label,
        style: TextStyle(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _summaryLine(BuildContext context, {required String label, required String value}) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: theme.textTheme.labelMedium?.copyWith(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _buildStatsSection(BuildContext context, TenantPortalData data) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxWidth = constraints.maxWidth;
        final isTwoColumn = maxWidth >= 560;
        final itemWidth = isTwoColumn ? (maxWidth - 12) / 2 : maxWidth;

        final items = [
          _buildStatTile(
            context,
            icon: Icons.account_balance_wallet_outlined,
            label: 'Outstanding Balance',
            value: _formatCurrency(data.stats.outstandingBalance),
            color: data.stats.outstandingBalance > 0 ? AppTheme.error : AppTheme.success,
          ),
          _buildStatTile(
            context,
            icon: Icons.event_available_outlined,
            label: 'Next Due Date',
            value: data.stats.nextDueDate != null ? _formatDate(data.stats.nextDueDate) : 'No upcoming payment',
          ),
          _buildStatTile(
            context,
            icon: Icons.payments_outlined,
            label: 'Next Amount',
            value: data.stats.nextAmountDue != null ? _formatCurrency(data.stats.nextAmountDue!) : 'Pending',
          ),
        ];

        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: items
              .map(
                (tile) => SizedBox(
                  width: itemWidth,
                  child: tile,
                ),
              )
              .toList(),
        );
      },
    );
  }

  Widget _buildStatTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    Color? color,
  }) {
    final theme = Theme.of(context);
    final highlight = color ?? theme.colorScheme.primary;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: highlight.withOpacity(0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: highlight.withOpacity(0.15)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: highlight.withOpacity(0.15),
            foregroundColor: highlight,
            child: Icon(icon),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 4),
                Text(
                  value,
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFacilityCard(BuildContext context, TenantPortalData data) {
    final facility = data.facility;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Facility Contact', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            if (facility.address != null && facility.address!.isNotEmpty) ...[
              _copyRow(
                context,
                icon: Icons.place_outlined,
                value: facility.address!,
                label: 'Address',
              ),
              const SizedBox(height: 12),
            ],
            if (facility.phone != null && facility.phone!.isNotEmpty) ...[
              _copyRow(
                context,
                icon: Icons.phone_outlined,
                value: facility.phone!,
                label: 'Phone',
              ),
              const SizedBox(height: 12),
            ],
            if (facility.email != null && facility.email!.isNotEmpty)
              _copyRow(
                context,
                icon: Icons.email_outlined,
                value: facility.email!,
                label: 'Email',
              ),
            if ((facility.address ?? '').isEmpty &&
                (facility.phone ?? '').isEmpty &&
                (facility.email ?? '').isEmpty)
              const Text('Facility contact information will appear here once provided.'),
          ],
        ),
      ),
    );
  }

  Widget _copyRow(
    BuildContext context, {
    required IconData icon,
    required String value,
    required String label,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: AppTheme.primaryBlueDark),
        const SizedBox(width: 12),
        Expanded(
          child: SelectableText(
            value,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        IconButton(
          icon: const Icon(Icons.copy),
          tooltip: 'Copy $label',
          onPressed: () => _copyToClipboard(value, label),
        ),
      ],
    );
  }

  Widget _buildEmergencyContactsCard(BuildContext context, TenantPortalData data) {
    final contacts = data.tenant.contacts;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Emergency & Alternate Contacts', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            ...contacts.map((contact) {
              final chips = <Widget>[];
              if (contact.isPrimary) {
                chips.add(_tagChip('Primary', AppTheme.primaryBlueDark));
              }
              if (contact.isEmergency) {
                chips.add(_tagChip('Emergency', AppTheme.warning));
              }

              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          contact.isEmergency ? Icons.warning_amber_outlined : Icons.contact_phone_outlined,
                          color: contact.isEmergency ? AppTheme.warning : AppTheme.primaryBlueDark,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                contact.name,
                                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 4),
                              if (contact.relationship != null && contact.relationship!.isNotEmpty)
                                Text('Relationship: ${contact.relationship}'),
                              if (contact.phone != null && contact.phone!.isNotEmpty)
                                Text('Phone: ${contact.phone}'),
                              if (contact.email != null && contact.email!.isNotEmpty)
                                Text('Email: ${contact.email}'),
                            ],
                          ),
                        ),
                        if (chips.isNotEmpty)
                          Wrap(
                            spacing: 4,
                            runSpacing: 4,
                            children: chips,
                          ),
                      ],
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _tagChip(String label, Color color) {
    return Chip(
      label: Text(label, style: TextStyle(color: color, fontWeight: FontWeight.w600)),
      backgroundColor: color.withOpacity(0.1),
      side: BorderSide(color: color.withOpacity(0.2)),
    );
  }

  Widget _buildVehiclesCard(BuildContext context, TenantPortalData data) {
    final vehicles = data.tenant.vehicles;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Registered Vehicles', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            ...vehicles.map((vehicle) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.directions_car_outlined, color: AppTheme.primaryBlueDark),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${vehicle.make} ${vehicle.model}'.trim(),
                            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          if (vehicle.licensePlate != null && vehicle.licensePlate!.isNotEmpty)
                            Text('Plate: ${vehicle.licensePlate}'),
                          if (vehicle.state != null && vehicle.state!.isNotEmpty)
                            Text('State: ${vehicle.state}'),
                          if (vehicle.color != null && vehicle.color!.isNotEmpty)
                            Text('Color: ${vehicle.color}'),
                          if (vehicle.notes != null && vehicle.notes!.isNotEmpty)
                            Text(vehicle.notes!),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildPaymentsCard(BuildContext context, TenantPortalData data) {
    final payments = data.recentPayments;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Recent Payments', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            if (payments.isEmpty)
              const Text('No payment history yet.')
            else
              ...payments.map((payment) {
                final statusColor = _statusColor(payment.status);
                final statusText = payment.status.displayName;

                return Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundColor: statusColor.withOpacity(0.12),
                        foregroundColor: statusColor,
                        child: Icon(_statusIcon(payment.status)),
                      ),
                      title: Text(
                        '${_formatCurrency(payment.amount)} due ${_formatDate(payment.dueDate)}',
                        style: theme.textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
                      ),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (payment.paidAt != null)
                            Text('Paid on ${_formatDate(payment.paidAt)}'),
                          if (payment.method != null && payment.method!.isNotEmpty)
                            Text('Method: ${_formatMethod(payment.method)}'),
                        ],
                      ),
                      trailing: Text(
                        statusText,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: statusColor,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (payment != payments.last) const Divider(height: 16),
                  ],
                );
              }),
          ],
        ),
      ),
    );
  }

  Widget _buildHelpCard(BuildContext context, TenantPortalData data) {
    final theme = Theme.of(context);
    final facility = data.facility;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Need Assistance?', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            const Text(
              'This portal provides a read-only view of your account. Reach out to your facility manager if you need to update contact information, change your billing details, or have questions about your balance.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                if (facility.email != null && facility.email!.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => _copyToClipboard(facility.email!, 'Facility email'),
                    icon: const Icon(Icons.email_outlined),
                    label: const Text('Copy Email'),
                  ),
                if (facility.phone != null && facility.phone!.isNotEmpty)
                  OutlinedButton.icon(
                    onPressed: () => _copyToClipboard(facility.phone!, 'Facility phone'),
                    icon: const Icon(Icons.phone_outlined),
                    label: const Text('Copy Phone Number'),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
