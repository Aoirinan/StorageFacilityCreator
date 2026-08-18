import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/tenant_autopay_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/models/tenant_portal_models.dart';
import 'package:sfcapp/providers/tenant_portal_provider.dart';
import 'package:sfcapp/services/autopay_service.dart';
import 'package:sfcapp/services/stripe_service.dart';
import 'package:sfcapp/services/tenant_portal_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/ui/payments/stripe_embedded_payment_dialog.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/auth/widgets/auth_shell.dart';

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
  bool _isAutopayLoading = false;
  bool _appCheckFailureShown = false;
  final bool _isLocalhost = kIsWeb &&
      (Uri.base.host == 'localhost' || Uri.base.host == '127.0.0.1');

  @override
  void initState() {
    super.initState();
    // Prefetch App Check token to avoid failed-precondition on first load.
    if (!_isLocalhost) {
      FirebaseAppCheck.instance.getToken().catchError((Object _) {
        if (mounted && !_appCheckFailureShown) {
          _appCheckFailureShown = true;
          _showAppCheckDialog();
        }
        return null;
      });
    }
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

  Future<void> _reloadTenantPortal() async {
    ref.invalidate(tenantPortalProvider(widget.lookup));
    await ref.read(tenantPortalProvider(widget.lookup).future);
  }

  Future<void> _manualRefresh() async {
    try {
      // Ensure App Check token is fresh before hitting Functions
      if (!_isLocalhost) {
        await FirebaseAppCheck.instance.getToken();
      }
      await _reloadTenantPortal();
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

  /// Match staff Insurance screen behavior: allow `www.example.com` without a scheme.
  String _normalizePortalWebUrl(String raw) {
    var t = raw.trim();
    if (t.isEmpty) return t;
    if (!t.contains('://') && t.contains('.')) {
      t = 'https://$t';
    }
    return t;
  }

  Future<void> _openInsuranceReferralUrl(String raw) async {
    final normalized = _normalizePortalWebUrl(raw);
    final uri = Uri.tryParse(normalized);
    if (uri == null) {
      _showSnack('Invalid link. Ask your facility for an updated URL.', isError: true);
      return;
    }
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      _showSnack('Could not open link.', isError: true);
    }
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        behavior: SnackBarBehavior.floating,
        backgroundColor: isError ? AppTheme.error : null,
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
              if (!_isLocalhost) {
                await FirebaseAppCheck.instance.getToken();
              }
              await _manualRefresh();
            },
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Future<void> _startAdditionalUnitRental(TenantPortalData data) async {
    final facilityId = data.facility.id;

    try {
      final units = await TenantPortalService.listAvailableUnitsForAdditionalRental(
        email: widget.lookup.email,
        accessCode: widget.lookup.accessCode,
        facilityId: facilityId,
      );
      if (!mounted) return;
      if (units.isEmpty) {
        _showSnack('No units are currently available to rent.', isError: true);
        return;
      }

      final selected = await showModalBottomSheet<TenantPortalAvailableUnit>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (ctx) => _AvailableUnitsSheet(units: units),
      );

      if (selected == null || !mounted) return;

      final reservation = await TenantPortalService.createAdditionalUnitReservation(
        email: widget.lookup.email,
        accessCode: widget.lookup.accessCode,
        facilityId: facilityId,
        unitId: selected.id,
        unitNumber: selected.unitNumber,
      );

      final token = reservation.moveInToken;
      if (token == null || token.isEmpty) {
        _showSnack(
          'Unable to start move-in for this unit. Please try again.',
          isError: true,
        );
        return;
      }

      if (!mounted) return;
      context.go('${AppRoute.publicMoveIn}?token=$token');
    } catch (_) {
      if (!mounted) return;
      _showSnack(
        'Could not start unit rental. Please try again or contact your facility.',
        isError: true,
      );
    }
  }

  Future<void> _initiatePayment(
    TenantPortalData data,
    double amount, {
    String? tenantId,
  }) async {
    setState(() {
      _isProcessingPayment = true;
    });

    try {
      // Create checkout using portal credentials
      final checkoutUrl = await StripeService.createTenantPortalPaymentCheckout(
        email: widget.lookup.email,
        accessCode: widget.lookup.accessCode,
        amount: amount,
        tenantId: tenantId,
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
        child: SizedBox(
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
                      color: Colors.black.withValues(alpha: 0.1),
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
    unawaited(_reloadTenantPortalAfterPayment());
  }

  Future<void> _reloadTenantPortalAfterPayment() async {
    await _reloadTenantPortal();
    if (mounted) {
      _showSnack('Payment successful! Your account will be updated shortly.');
    }
  }

  void _exitPortal(BuildContext context) {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go(AppRoute.tenantPortal);
    }
  }

  Widget _buildPortalBackdrop(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    return Stack(
      fit: StackFit.expand,
      children: [
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color(0xFF312E81),
                AppTheme.primaryBlue,
                Color(0xFF2563EB),
              ],
              stops: [0.0, 0.55, 1.0],
            ),
          ),
        ),
        Positioned(
          top: -100,
          left: -80,
          child: _TenantPortalOrb(size: 320, color: Colors.white.withValues(alpha: 0.06)),
        ),
        Positioned(
          bottom: -120,
          right: -100,
          child: _TenantPortalOrb(
            size: 380,
            color: AppTheme.accentYellow.withValues(alpha: 0.08),
          ),
        ),
        Positioned(
          top: screenWidth * 0.3,
          right: -60,
          child: _TenantPortalOrb(
            size: 220,
            color: AppTheme.accentBlueLight.withValues(alpha: 0.08),
          ),
        ),
      ],
    );
  }

  Widget _buildPortalTopBar(
    BuildContext context,
    TenantPortalData data,
    AsyncValue<TenantPortalData> portalAsync,
  ) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 2, 8, 10),
      child: Row(
        children: [
          AuthShellBackButton(onPressed: () => _exitPortal(context)),
          Expanded(
            child: Column(
              children: [
                Text(
                  data.facility.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.35,
                  ),
                ),
                Text(
                  'Tenant portal',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.85),
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          Material(
            color: Colors.white.withValues(alpha: 0.12),
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: portalAsync.isLoading ? null : _manualRefresh,
              child: Padding(
                padding: const EdgeInsets.all(10),
                child: portalAsync.isLoading
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white.withValues(alpha: 0.92),
                        ),
                      )
                    : Icon(
                        Icons.refresh_rounded,
                        size: 22,
                        color: Colors.white.withValues(alpha: 0.95),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final portalAsync = ref.watch(tenantPortalProvider(widget.lookup));
    final data = portalAsync.value ?? widget.initialData;

    final theme = Theme.of(context);

    final bodyChildren = <Widget>[
      if (portalAsync.hasError) _buildErrorBanner(context, portalAsync.error),
      if (data.tenant.overlockIsActive) _buildOverlockBanner(context),
      _buildSummaryCard(context, data),
      const SizedBox(height: 16),
      _buildUnitAccountsCard(context, data),
      const SizedBox(height: 16),
      _buildStatsSection(context, data),
      const SizedBox(height: 16),
      _buildUpcomingCard(context, data),
      const SizedBox(height: 16),
      _buildMyInfoCard(context, data),
      const SizedBox(height: 16),
      _buildFacilityCard(context, data),
      const SizedBox(height: 16),
      _buildEmergencyContactsCard(context, data),
      const SizedBox(height: 16),
      _buildVehiclesCard(context, data),
      const SizedBox(height: 16),
      _buildPaymentsCard(context, data),
      const SizedBox(height: 16),
      _buildAutopayCard(context, data),
      const SizedBox(height: 16),
      if (data.facility.insuranceReferral?.hasLink == true) ...[
        _buildInsuranceReferralCard(context, data),
        const SizedBox(height: 16),
      ],
      _buildHelpCard(context, data),
      const SizedBox(height: 16),
      Text(
        'Portal data refreshes each time you return to this page. Facility managers can update your details or reset your access code if needed.',
        style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
      ),
    ];

    final screenWidth = MediaQuery.sizeOf(context).width;
    final isMobile = screenWidth < 600;

    return Scaffold(
      backgroundColor: const Color(0xFF312E81),
      body: Stack(
        fit: StackFit.expand,
        children: [
          _buildPortalBackdrop(context),
          SafeArea(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildPortalTopBar(context, data, portalAsync),
                Expanded(
                  child: Stack(
                    children: [
                      RefreshIndicator(
                        onRefresh: () async {
                          ref.invalidate(tenantPortalProvider(widget.lookup));
                          await ref.read(tenantPortalProvider(widget.lookup).future);
                        },
                        child: ListView(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding: EdgeInsets.fromLTRB(
                            isMobile ? 16 : 24,
                            4,
                            isMobile ? 16 : 24,
                            28,
                          ),
                          children: [
                            Center(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(maxWidth: 720),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(24),
                                    boxShadow: [
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.18),
                                        blurRadius: 48,
                                        offset: const Offset(0, 24),
                                      ),
                                      BoxShadow(
                                        color: Colors.black.withValues(alpha: 0.06),
                                        blurRadius: 12,
                                        offset: const Offset(0, 4),
                                      ),
                                    ],
                                  ),
                                  child: Padding(
                                    padding: EdgeInsets.all(isMobile ? 20 : 28),
                                    child: Theme(
                                      data: theme.copyWith(
                                        cardTheme: CardThemeData(
                                          elevation: 0,
                                          color: const Color(0xFFF8FAFC),
                                          shape: RoundedRectangleBorder(
                                            borderRadius: BorderRadius.circular(16),
                                            side: const BorderSide(color: AppTheme.borderLight),
                                          ),
                                        ),
                                      ),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.stretch,
                                        children: bodyChildren,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
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
                ),
              ],
            ),
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
      color: AppTheme.error.withValues(alpha: 0.1),
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

  Widget _buildOverlockBanner(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: AppTheme.error.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.lock, color: AppTheme.error, size: 28),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Unit is currently overlocked',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: AppTheme.error,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'This unit is currently overlocked. Please contact management. You can still make payments below.',
                    style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.error),
                  ),
                ],
              ),
            ),
          ],
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
              style: const TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.w800,
                color: AppTheme.textPrimary,
                letterSpacing: -0.45,
                height: 1.2,
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _infoChip(Icons.storefront_outlined, 'Unit ${tenant.unitNumber}'),
                _infoChip(Icons.payments_outlined, '${_formatCurrency(tenant.monthlyRate)} / month'),
                if (data.units.length > 1)
                  _infoChip(Icons.meeting_room_outlined, '${data.units.length} units'),
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
              AuthGradientButton(
                isLoading: _isProcessingPayment,
                onPressed: () => _initiatePayment(
                  data,
                  outstanding,
                  tenantId: tenant.id,
                ),
                label: 'Pay now',
              ),
            ],
            if (tenant.welcomeMessage != null && tenant.welcomeMessage!.isNotEmpty) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.primaryBlueDark.withValues(alpha: 0.1),
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
      backgroundColor: AppTheme.primaryBlueDark.withValues(alpha: 0.08),
      label: Text(label),
      side: BorderSide(color: AppTheme.primaryBlueDark.withValues(alpha: 0.12)),
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
      backgroundColor: color.withValues(alpha: 0.08),
      side: BorderSide(color: color.withValues(alpha: 0.12)),
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

  // ─── Upcoming Dates Card ──────────────────────────────────────────────────────

  /// Builds a compact timeline of the next important dates for this tenant.
  /// Only shows items that are actually present and upcoming.
  Widget _buildUpcomingCard(BuildContext context, TenantPortalData data) {
    final tenant = data.tenant;
    final stats = data.stats;
    final now = DateTime.now();
    final theme = Theme.of(context);

    // Collect upcoming items: (date, label, icon, color, urgency)
    final items = <_UpcomingItem>[];

    // Next payment due
    if (stats.nextDueDate != null) {
      final daysUntil = stats.nextDueDate!.difference(now).inDays;
      final isPast = stats.nextDueDate!.isBefore(now);
      items.add(_UpcomingItem(
        date: stats.nextDueDate!,
        label: isPast
            ? 'Payment overdue'
            : 'Payment due',
        detail: stats.nextAmountDue != null
            ? _formatCurrency(stats.nextAmountDue!)
            : null,
        icon: Icons.receipt_long_outlined,
        color: isPast || daysUntil <= 3
            ? AppTheme.error
            : daysUntil <= 7
                ? AppTheme.warning
                : AppTheme.primaryBlue,
        isUrgent: isPast || daysUntil <= 3,
      ));
    }

    // Autopay charge date — same as next due date when autopay is on
    if (tenant.autopay.isOn &&
        stats.nextDueDate != null &&
        !stats.nextDueDate!.isBefore(now)) {
      items.add(_UpcomingItem(
        date: stats.nextDueDate!,
        label: 'Autopay charge',
        detail: stats.nextAmountDue != null
            ? _formatCurrency(stats.nextAmountDue!)
            : null,
        icon: Icons.autorenew,
        color: AppTheme.success,
        isUrgent: false,
      ));
    }

    // Scheduled move-out
    if (tenant.scheduledMoveOutDate != null) {
      final daysUntil = tenant.scheduledMoveOutDate!.difference(now).inDays;
      items.add(_UpcomingItem(
        date: tenant.scheduledMoveOutDate!,
        label: 'Scheduled move-out',
        icon: Icons.logout,
        color: daysUntil <= 7 ? AppTheme.warning : AppTheme.primaryBlueDark,
        isUrgent: daysUntil <= 3,
      ));
    }

    // Contract expiration
    if (tenant.contractExpiresAt != null) {
      final daysUntil = tenant.contractExpiresAt!.difference(now).inDays;
      if (daysUntil <= 60) {
        items.add(_UpcomingItem(
          date: tenant.contractExpiresAt!,
          label: daysUntil < 0 ? 'Lease expired' : 'Lease expires',
          detail: daysUntil >= 0 ? 'in $daysUntil days' : null,
          icon: Icons.description_outlined,
          color: daysUntil <= 14
              ? AppTheme.error
              : daysUntil <= 30
                  ? AppTheme.warning
                  : AppTheme.textSecondary,
          isUrgent: daysUntil <= 14,
        ));
      }
    }

    // Insurance expiration
    if (tenant.insuranceExpiresAt != null) {
      final daysUntil = tenant.insuranceExpiresAt!.difference(now).inDays;
      if (daysUntil <= 60) {
        items.add(_UpcomingItem(
          date: tenant.insuranceExpiresAt!,
          label: daysUntil < 0 ? 'Insurance expired' : 'Insurance expires',
          detail: daysUntil >= 0 ? 'in $daysUntil days' : null,
          icon: Icons.shield_outlined,
          color: daysUntil <= 14
              ? AppTheme.error
              : daysUntil <= 30
                  ? AppTheme.warning
                  : AppTheme.textSecondary,
          isUrgent: daysUntil <= 14,
        ));
      }
    }

    // Sort by date ascending
    items.sort((a, b) => a.date.compareTo(b.date));

    // Deduplicate: if autopay charge and payment due are on the same day, keep only autopay
    final deduped = <_UpcomingItem>[];
    for (final item in items) {
      final sameDay = deduped.any((existing) =>
          existing.date.year == item.date.year &&
          existing.date.month == item.date.month &&
          existing.date.day == item.date.day &&
          existing.label == 'Payment due' &&
          item.label == 'Autopay charge');
      if (!sameDay) deduped.add(item);
    }

    // Nothing to show — hide the card entirely
    if (deduped.isEmpty) return const SizedBox.shrink();

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.event_note_outlined,
                    size: 18, color: theme.colorScheme.primary),
                const SizedBox(width: 8),
                Text('Upcoming', style: theme.textTheme.titleMedium),
              ],
            ),
            const SizedBox(height: 12),
            ...deduped.asMap().entries.map((entry) {
              final i = entry.key;
              final item = entry.value;
              final isLast = i == deduped.length - 1;
              return _buildUpcomingRow(context, item, isLast: isLast);
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildUpcomingRow(
    BuildContext context,
    _UpcomingItem item, {
    required bool isLast,
  }) {
    final theme = Theme.of(context);
    final dateStr = _formatDate(item.date);
    final daysUntil = item.date.difference(DateTime.now()).inDays;
    final String relativeLabel;
    if (daysUntil < 0) {
      relativeLabel = '${daysUntil.abs()} day${daysUntil.abs() == 1 ? '' : 's'} ago';
    } else if (daysUntil == 0) {
      relativeLabel = 'Today';
    } else if (daysUntil == 1) {
      relativeLabel = 'Tomorrow';
    } else {
      relativeLabel = 'In $daysUntil days';
    }

    return Column(
      children: [
        Row(
          children: [
            // Timeline dot + line
            SizedBox(
              width: 32,
              child: Column(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: item.color.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(item.icon, size: 14, color: item.color),
                  ),
                  if (!isLast)
                    Container(
                      width: 1.5,
                      height: 20,
                      color: theme.dividerColor,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Padding(
                padding: EdgeInsets.only(bottom: isLast ? 0 : 20),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                item.label,
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: item.isUrgent ? item.color : null,
                                ),
                              ),
                              if (item.isUrgent) ...[
                                const SizedBox(width: 4),
                                Icon(Icons.priority_high,
                                    size: 14, color: item.color),
                              ],
                            ],
                          ),
                          const SizedBox(height: 2),
                          Text(
                            dateStr,
                            style: theme.textTheme.bodySmall?.copyWith(
                                color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          relativeLabel,
                          style: theme.textTheme.labelMedium?.copyWith(
                            color: item.isUrgent ? item.color : AppTheme.textSecondary,
                            fontWeight: item.isUrgent ? FontWeight.w700 : FontWeight.normal,
                          ),
                        ),
                        if (item.detail != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            item.detail!,
                            style: theme.textTheme.labelMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: item.color,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
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

  Widget _buildUnitAccountsCard(BuildContext context, TenantPortalData data) {
    final theme = Theme.of(context);
    if (data.units.isEmpty) {
      return const SizedBox.shrink();
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('My Units', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            ...data.units.map((unit) {
              final canPay = unit.outstandingBalance > 0;
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFF8FAFC),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.borderLight),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          'Unit ${unit.unitNumber}',
                          style: theme.textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        _statusChip(unit.isDelinquent, unit.outstandingBalance),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      'Balance: ${_formatCurrency(unit.outstandingBalance)}',
                      style: theme.textTheme.bodyMedium,
                    ),
                    Text(
                      'Next due: ${unit.nextDueDate != null ? _formatDate(unit.nextDueDate) : 'No upcoming payment'}',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    if (canPay) ...[
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: OutlinedButton.icon(
                          onPressed: _isProcessingPayment
                              ? null
                              : () => _initiatePayment(
                                    data,
                                    unit.outstandingBalance,
                                    tenantId: unit.tenantId,
                                  ),
                          icon: const Icon(Icons.payments_outlined, size: 18),
                          label: const Text('Pay this unit'),
                        ),
                      ),
                    ],
                  ],
                ),
              );
            }),
          ],
        ),
      ),
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
        color: highlight.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: highlight.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: highlight.withValues(alpha: 0.15),
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

  // ─── Edit My Information ────────────────────────────────────────────────────

  Widget _buildMyInfoCard(BuildContext context, TenantPortalData data) {
    final tenant = data.tenant;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('My Contact Information', style: theme.textTheme.titleMedium)),
                TextButton.icon(
                  onPressed: () => _showEditPhoneDialog(context, data),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            if (tenant.email != null && tenant.email!.isNotEmpty)
              _infoRow(Icons.email_outlined, 'Email', tenant.email!),
            if (tenant.phone != null && tenant.phone!.isNotEmpty) ...[
              const SizedBox(height: 8),
              _infoRow(Icons.phone_outlined, 'Phone', tenant.phone!),
            ],
            if ((tenant.email == null || tenant.email!.isEmpty) &&
                (tenant.phone == null || tenant.phone!.isEmpty))
              Text('No contact info on file.', style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary)),
            const SizedBox(height: 4),
            Text(
              'Email is managed by your facility. You can update your phone number here.',
              style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, size: 18, color: AppTheme.primaryBlueDark),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
              Text(value),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _showEditPhoneDialog(BuildContext context, TenantPortalData data) async {
    final controller = TextEditingController(text: data.tenant.phone ?? '');
    final formKey = GlobalKey<FormState>();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Update Phone Number'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
              labelText: 'Phone Number',
              prefixIcon: Icon(Icons.phone_outlined),
              border: OutlineInputBorder(),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Please enter a phone number';
              return null;
            },
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            onPressed: () {
              if (formKey.currentState!.validate()) Navigator.pop(ctx, true);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await _saveProfileUpdate(phone: controller.text.trim());
  }

  Future<void> _showEditContactsSheet(BuildContext context, TenantPortalData data) async {
    final contacts = List<TenantContact>.from(data.tenant.contacts);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _EditContactsSheet(
        contacts: contacts,
        onSave: (updated) async {
          Navigator.pop(ctx);
          await _saveProfileUpdate(emergencyContacts: updated);
        },
      ),
    );
  }

  Future<void> _showEditVehiclesSheet(BuildContext context, TenantPortalData data) async {
    final vehicles = List<TenantVehicle>.from(data.tenant.vehicles);
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => _EditVehiclesSheet(
        vehicles: vehicles,
        onSave: (updated) async {
          Navigator.pop(ctx);
          await _saveProfileUpdate(vehicles: updated);
        },
      ),
    );
  }

  Future<void> _saveProfileUpdate({
    String? phone,
    List<TenantContact>? emergencyContacts,
    List<TenantVehicle>? vehicles,
  }) async {
    try {
      await TenantPortalService.updateProfile(
        email: widget.lookup.email,
        accessCode: widget.lookup.accessCode,
        phone: phone,
        emergencyContacts: emergencyContacts,
        vehicles: vehicles,
      );
      if (!mounted) return;
      _showSnack('Information updated successfully.');
      await _reloadTenantPortal();
    } on TenantPortalException catch (e) {
      if (!mounted) return;
      _showSnack('Error: ${e.message}', isError: true);
    } catch (e) {
      if (!mounted) return;
      _showSnack('Unexpected error. Please try again.', isError: true);
    }
  }

  // ─── Emergency Contacts Card ─────────────────────────────────────────────────

  Widget _buildEmergencyContactsCard(BuildContext context, TenantPortalData data) {
    final contacts = data.tenant.contacts;
    final theme = Theme.of(context);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(child: Text('Emergency & Alternate Contacts', style: theme.textTheme.titleMedium)),
                TextButton.icon(
                  onPressed: () => _showEditContactsSheet(context, data),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit'),
                ),
              ],
            ),
            if (contacts.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('No contacts on file. Tap Edit to add one.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary)),
              ),
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
      backgroundColor: color.withValues(alpha: 0.1),
      side: BorderSide(color: color.withValues(alpha: 0.2)),
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
            Row(
              children: [
                Expanded(child: Text('Registered Vehicles', style: theme.textTheme.titleMedium)),
                TextButton.icon(
                  onPressed: () => _showEditVehiclesSheet(context, data),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: const Text('Edit'),
                ),
              ],
            ),
            if (vehicles.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('No vehicles on file. Tap Edit to add one.',
                    style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary)),
              ),
            ...vehicles.map((vehicle) {
              return Padding(
                padding: const EdgeInsets.only(top: 12),
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
                        backgroundColor: statusColor.withValues(alpha: 0.12),
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
                          if (payment.unitNumber != null &&
                              payment.unitNumber!.isNotEmpty)
                            Text('Unit: ${payment.unitNumber}'),
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

  Future<void> _addCardFromPortal({String? tenantId}) async {
    if (!kIsWeb) return;
    setState(() => _isAutopayLoading = true);
    try {
      final resolvedTenantId = tenantId ??
          ref.read(tenantPortalProvider(widget.lookup)).whenOrNull(data: (d) => d.tenant.id);
      final result = await StripeService.createTenantSetupIntentFromPortal(
        email: widget.lookup.email,
        accessCode: widget.lookup.accessCode,
        tenantId: resolvedTenantId,
      );
      final clientSecret = result['clientSecret'] as String?;
      final publishableKey = result['publishableKey'] as String?;
      final connectedAccountId = result['connectedAccountId'] as String?;
      if (clientSecret == null) throw Exception('No client secret');
      if (!mounted) return;
      final baseUrl = Uri.base.origin;
      final dialogResult = await showStripeEmbeddedDialog(
        context: context,
        clientSecret: clientSecret,
        mode: 'setup',
        // '/portal' is not a route. Stripe redirects here after Link or 3DS,
        // so the tenant landed on "Page not found" immediately after typing
        // their card number — the most alarming possible moment to show it.
        returnUrl: '$baseUrl/#${AppRoute.tenantPortal}',
        publishableKeyFromBackend: publishableKey,
        stripeAccount: connectedAccountId,
      );
      if (!mounted) return;
      if (dialogResult != null && dialogResult.succeeded) {
        // Record the card server-side rather than trusting the
        // setup_intent.succeeded webhook. That webhook fires on the facility's
        // connected account, and connected-account events only arrive if the
        // Stripe endpoint is subscribed to Connect events — when it is not, the
        // tenant is told the card saved while autopay never sees it at all.
        final setupIntentId = result['setupIntentId'] as String?;
        if (setupIntentId != null && setupIntentId.isNotEmpty) {
          try {
            await StripeService.attachTenantPaymentMethodFromPortal(
              email: widget.lookup.email,
              accessCode: widget.lookup.accessCode,
              tenantId: resolvedTenantId,
              setupIntentId: setupIntentId,
            );
          } catch (_) {
            // The webhook may still record it, and both paths are idempotent —
            // so don't tell the tenant their card failed when it did save.
          }
        }
        _showSnack('Card saved. Refreshing…');
        await _reloadTenantPortal();
        final data = ref.read(tenantPortalProvider(widget.lookup)).whenOrNull(data: (d) => d);
        if (data != null && data.tenant.autopay.isRequested) {
          await AutopayService.setTenantAutopayFromPortal(
            email: widget.lookup.email,
            accessCode: widget.lookup.accessCode,
            enabled: true,
            tenantId: resolvedTenantId,
          );
          await _reloadTenantPortal();
          _showSnack('Autopay is now on.');
        }
      }
    } catch (e) {
      if (mounted) _showSnack('Could not add card. Please try again.');
    } finally {
      if (mounted) setState(() => _isAutopayLoading = false);
    }
  }

  Widget _buildAutopayCard(BuildContext context, TenantPortalData data) {
    final theme = Theme.of(context);
    final autopay = data.tenant.autopay;
    final stripe = data.tenant.stripe;
    final paymentsEnabled = data.facility.paymentsEnabled;

    Widget statusChip;
    switch (autopay.status) {
      case AutopayStatus.off:
        statusChip = Chip(
          avatar: const Icon(Icons.toggle_off, color: AppTheme.textSecondary, size: 20),
          label: const Text('OFF'),
          backgroundColor: AppTheme.textSecondary.withValues(alpha: 0.1),
        );
        break;
      case AutopayStatus.requested:
        statusChip = Chip(
          avatar: const Icon(Icons.schedule, color: AppTheme.warning, size: 20),
          label: const Text('REQUESTED'),
          backgroundColor: AppTheme.warning.withValues(alpha: 0.1),
        );
        break;
      case AutopayStatus.on:
        statusChip = Chip(
          avatar: const Icon(Icons.check_circle, color: AppTheme.success, size: 20),
          label: const Text('ON'),
          backgroundColor: AppTheme.success.withValues(alpha: 0.1),
        );
        break;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Autopay', style: theme.textTheme.titleMedium),
                const SizedBox(width: 12),
                statusChip,
              ],
            ),
            if (!paymentsEnabled) ...[
              const SizedBox(height: 12),
              Text(
                "Payments aren't enabled for this facility yet. Your autopay request is saved. Add your card once the facility enables payments.",
                style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
              ),
            ] else ...[
              if (autopay.isOn) ...[
                if (stripe.hasPaymentMethod && stripe.paymentMethodSummary != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    'Card: ${stripe.paymentMethodSummary!.displayLabel}',
                    style: theme.textTheme.bodySmall,
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    const Text('Turn off autopay'),
                    const SizedBox(width: 12),
                    Switch(
                      value: true,
                      onChanged: _isAutopayLoading ? null : (v) async {
                        if (!v) {
                          setState(() => _isAutopayLoading = true);
                          try {
                            await AutopayService.setTenantAutopayFromPortal(
                              email: widget.lookup.email,
                              accessCode: widget.lookup.accessCode,
                              enabled: false,
                              tenantId: data.tenant.id,
                            );
                            await _reloadTenantPortal();
                            _showSnack('Autopay turned off.');
                          } catch (e) {
                            _showSnack('Could not update. Try again.');
                          } finally {
                            if (mounted) setState(() => _isAutopayLoading = false);
                          }
                        }
                      },
                    ),
                  ],
                ),
              ] else if (autopay.isRequested) ...[
                const SizedBox(height: 12),
                const Text('Autopay requested — add a card to finish setup.'),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _isAutopayLoading ? null : () => _addCardFromPortal(tenantId: data.tenant.id),
                  icon: _isAutopayLoading ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.add_card),
                  label: const Text('Add card / Finish setup'),
                ),
              ] else ...[
                const SizedBox(height: 12),
                const Text('Turn on autopay to have rent charged automatically each month.'),
                if (!stripe.hasPaymentMethod) ...[
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    onPressed: _isAutopayLoading ? null : () => _addCardFromPortal(tenantId: data.tenant.id),
                    icon: _isAutopayLoading ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.add_card),
                    label: const Text('Add card'),
                  ),
                ] else ...[
                  const SizedBox(height: 8),
                  FilledButton(
                    onPressed: _isAutopayLoading ? null : () async {
                      setState(() => _isAutopayLoading = true);
                      try {
                        await AutopayService.setTenantAutopayFromPortal(
                          email: widget.lookup.email,
                          accessCode: widget.lookup.accessCode,
                          enabled: true,
                          tenantId: data.tenant.id,
                        );
                        await _reloadTenantPortal();
                        _showSnack('Autopay is now on.');
                      } catch (e) {
                        _showSnack(e.toString().replaceFirst('Exception: ', ''));
                      } finally {
                        if (mounted) setState(() => _isAutopayLoading = false);
                      }
                    },
                    child: const Text('Turn on autopay'),
                  ),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildInsuranceReferralCard(BuildContext context, TenantPortalData data) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final ref = data.facility.insuranceReferral!;
    final title = (ref.referralName != null && ref.referralName!.isNotEmpty)
        ? ref.referralName!
        : 'Recommended insurance';
    final urlRaw = ref.referralUrl!.trim();
    final urlForOpen = _normalizePortalWebUrl(urlRaw);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.shield_outlined, color: cs.primary, size: 22),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
            if (ref.referralNotes != null && ref.referralNotes!.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(ref.referralNotes!, style: theme.textTheme.bodyMedium),
            ],
            const SizedBox(height: 12),
            Text(
              '${data.facility.name} suggests this provider for your storage insurance needs. '
              'Storage Facility Creator does not sell insurance; any policy is between you and the provider.',
              style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton.icon(
                  onPressed: () => _openInsuranceReferralUrl(urlRaw),
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: const Text('Open link'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _copyToClipboard(urlForOpen, 'Insurance link'),
                  icon: const Icon(Icons.copy, size: 18),
                  label: const Text('Copy link'),
                ),
              ],
            ),
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
              'Use this portal to review your account, make payments, and start a new rental for another available unit. Reach out to your facility manager for account or billing questions.',
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: [
                FilledButton.icon(
                  onPressed: () => _startAdditionalUnitRental(data),
                  icon: const Icon(Icons.add_business_outlined),
                  label: const Text('Rent Another Unit'),
                ),
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

class _TenantPortalOrb extends StatelessWidget {
  final double size;
  final Color color;

  const _TenantPortalOrb({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
        ),
      ),
    );
  }
}

class _AvailableUnitsSheet extends StatelessWidget {
  final List<TenantPortalAvailableUnit> units;

  const _AvailableUnitsSheet({required this.units});

  String _formatCurrency(double amount) => '\$${amount.toStringAsFixed(2)}';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Select a Unit', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          Text(
            'Choose an available unit to continue to move-in.',
            style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          Flexible(
            child: ListView.separated(
              shrinkWrap: true,
              itemCount: units.length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final unit = units[index];
                return ListTile(
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                    side: const BorderSide(color: AppTheme.borderLight),
                  ),
                  tileColor: const Color(0xFFF8FAFC),
                  title: Text(
                    'Unit ${unit.unitNumber}',
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                  ),
                  subtitle: Text(
                    '${unit.unitType} • ${_formatCurrency(unit.monthlyRate)}/month',
                  ),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).pop(unit),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Upcoming item data class ─────────────────────────────────────────────────

class _UpcomingItem {
  final DateTime date;
  final String label;
  final String? detail;
  final IconData icon;
  final Color color;
  final bool isUrgent;

  const _UpcomingItem({
    required this.date,
    required this.label,
    this.detail,
    required this.icon,
    required this.color,
    required this.isUrgent,
  });
}

// ─── Edit Contacts Sheet ──────────────────────────────────────────────────────

class _EditContactsSheet extends StatefulWidget {
  final List<TenantContact> contacts;
  final Future<void> Function(List<TenantContact>) onSave;

  const _EditContactsSheet({required this.contacts, required this.onSave});

  @override
  State<_EditContactsSheet> createState() => _EditContactsSheetState();
}

class _EditContactsSheetState extends State<_EditContactsSheet> {
  late List<Map<String, dynamic>> _items;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _items = widget.contacts
        .map((c) => {
              'name': c.name,
              'relationship': c.relationship ?? '',
              'phone': c.phone ?? '',
              'email': c.email ?? '',
              'isPrimary': c.isPrimary,
              'isEmergency': c.isEmergency,
            })
        .toList();
  }

  void _addContact() {
    setState(() {
      _items.add({'name': '', 'relationship': '', 'phone': '', 'email': '', 'isPrimary': false, 'isEmergency': true});
    });
  }

  void _removeContact(int index) => setState(() => _items.removeAt(index));

  Future<void> _save() async {
    for (final item in _items) {
      if ((item['name'] as String).trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Each contact must have a name.'), behavior: SnackBarBehavior.floating),
        );
        return;
      }
    }
    setState(() => _saving = true);
    final contacts = _items
        .map((item) => TenantContact(
              name: (item['name'] as String).trim(),
              relationship: (item['relationship'] as String).trim().isEmpty ? null : (item['relationship'] as String).trim(),
              phone: (item['phone'] as String).trim().isEmpty ? null : (item['phone'] as String).trim(),
              email: (item['email'] as String).trim().isEmpty ? null : (item['email'] as String).trim(),
              isPrimary: item['isPrimary'] as bool,
              isEmergency: item['isEmergency'] as bool,
            ))
        .toList();
    await widget.onSave(contacts);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (ctx, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                Expanded(child: Text('Edit Contacts', style: theme.textTheme.titleLarge)),
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Save'),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(16),
              children: [
                ..._items.asMap().entries.map((entry) {
                  final i = entry.key;
                  final item = entry.value;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text('Contact ${i + 1}', style: theme.textTheme.titleSmall),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red),
                                onPressed: () => _removeContact(i),
                                tooltip: 'Remove',
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          _field('Name *', item['name'] as String, (v) => setState(() => item['name'] = v)),
                          const SizedBox(height: 8),
                          _field('Relationship', item['relationship'] as String, (v) => setState(() => item['relationship'] = v)),
                          const SizedBox(height: 8),
                          _field('Phone', item['phone'] as String, (v) => setState(() => item['phone'] = v), keyboard: TextInputType.phone),
                          const SizedBox(height: 8),
                          _field('Email', item['email'] as String, (v) => setState(() => item['email'] = v), keyboard: TextInputType.emailAddress),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('Primary'),
                                  value: item['isPrimary'] as bool,
                                  onChanged: (v) => setState(() => item['isPrimary'] = v ?? false),
                                ),
                              ),
                              Expanded(
                                child: CheckboxListTile(
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                  title: const Text('Emergency'),
                                  value: item['isEmergency'] as bool,
                                  onChanged: (v) => setState(() => item['isEmergency'] = v ?? true),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  );
                }),
                OutlinedButton.icon(
                  onPressed: _addContact,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Contact'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(String label, String value, ValueChanged<String> onChanged, {TextInputType? keyboard}) {
    return TextFormField(
      initialValue: value,
      keyboardType: keyboard,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      onChanged: onChanged,
    );
  }
}

// ─── Edit Vehicles Sheet ──────────────────────────────────────────────────────

class _EditVehiclesSheet extends StatefulWidget {
  final List<TenantVehicle> vehicles;
  final Future<void> Function(List<TenantVehicle>) onSave;

  const _EditVehiclesSheet({required this.vehicles, required this.onSave});

  @override
  State<_EditVehiclesSheet> createState() => _EditVehiclesSheetState();
}

class _EditVehiclesSheetState extends State<_EditVehiclesSheet> {
  late List<Map<String, dynamic>> _items;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _items = widget.vehicles
        .map((v) => {
              'make': v.make,
              'model': v.model,
              'color': v.color ?? '',
              'licensePlate': v.licensePlate ?? '',
              'state': v.state ?? '',
              'notes': v.notes ?? '',
            })
        .toList();
  }

  void _addVehicle() {
    setState(() {
      _items.add({'make': '', 'model': '', 'color': '', 'licensePlate': '', 'state': '', 'notes': ''});
    });
  }

  void _removeVehicle(int index) => setState(() => _items.removeAt(index));

  Future<void> _save() async {
    for (final item in _items) {
      if ((item['make'] as String).trim().isEmpty || (item['model'] as String).trim().isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Each vehicle must have a make and model.'), behavior: SnackBarBehavior.floating),
        );
        return;
      }
    }
    setState(() => _saving = true);
    final vehicles = _items
        .map((item) => TenantVehicle(
              make: (item['make'] as String).trim(),
              model: (item['model'] as String).trim(),
              color: (item['color'] as String).trim().isEmpty ? null : (item['color'] as String).trim(),
              licensePlate: (item['licensePlate'] as String).trim().isEmpty ? null : (item['licensePlate'] as String).trim(),
              state: (item['state'] as String).trim().isEmpty ? null : (item['state'] as String).trim(),
              notes: (item['notes'] as String).trim().isEmpty ? null : (item['notes'] as String).trim(),
            ))
        .toList();
    await widget.onSave(vehicles);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.85,
      maxChildSize: 0.95,
      builder: (ctx, scrollController) => Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Row(
              children: [
                Expanded(child: Text('Edit Vehicles', style: theme.textTheme.titleLarge)),
                TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white)) : const Text('Save'),
                ),
              ],
            ),
          ),
          const Divider(),
          Expanded(
            child: ListView(
              controller: scrollController,
              padding: const EdgeInsets.all(16),
              children: [
                ..._items.asMap().entries.map((entry) {
                  final i = entry.key;
                  final item = entry.value;
                  return Card(
                    margin: const EdgeInsets.only(bottom: 12),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text('Vehicle ${i + 1}', style: theme.textTheme.titleSmall),
                              const Spacer(),
                              IconButton(
                                icon: const Icon(Icons.delete_outline, color: Colors.red),
                                onPressed: () => _removeVehicle(i),
                                tooltip: 'Remove',
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(child: _field('Make *', item['make'] as String, (v) => setState(() => item['make'] = v))),
                              const SizedBox(width: 8),
                              Expanded(child: _field('Model *', item['model'] as String, (v) => setState(() => item['model'] = v))),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(child: _field('Color', item['color'] as String, (v) => setState(() => item['color'] = v))),
                              const SizedBox(width: 8),
                              Expanded(child: _field('License Plate', item['licensePlate'] as String, (v) => setState(() => item['licensePlate'] = v))),
                            ],
                          ),
                          const SizedBox(height: 8),
                          _field('State', item['state'] as String, (v) => setState(() => item['state'] = v)),
                          const SizedBox(height: 8),
                          _field('Notes', item['notes'] as String, (v) => setState(() => item['notes'] = v)),
                        ],
                      ),
                    ),
                  );
                }),
                OutlinedButton.icon(
                  onPressed: _addVehicle,
                  icon: const Icon(Icons.add),
                  label: const Text('Add Vehicle'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(String label, String value, ValueChanged<String> onChanged, {TextInputType? keyboard}) {
    return TextFormField(
      initialValue: value,
      keyboardType: keyboard,
      decoration: InputDecoration(labelText: label, border: const OutlineInputBorder(), isDense: true),
      onChanged: onChanged,
    );
  }
}
