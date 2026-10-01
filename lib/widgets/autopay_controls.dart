import 'package:flutter/material.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Enable / Disable autopay on the tenant page (setTenantAutopay).
///
/// Disable shows while autopay is set up in any form: the page's ON state
/// ([displayOn], tenant.autopay), or billing/default armed or holding a
/// legacy Stripe subscription id ([offersDisable], the test the facility
/// delete refuses on). It showed for the ON state only, so an owner the
/// facility delete sent to "press Disable autopay" found no such button for
/// a tenant armed from the billing panel's switch or left with a legacy
/// subscription. Disable cancels that subscription too (server side).
class AutopayControls extends StatelessWidget {
  const AutopayControls({
    super.key,
    required this.displayOn,
    required this.billing,
    required this.busy,
    required this.onSet,
  });

  /// tenant.autopay's ON state.
  final bool displayOn;

  /// The tenant's billing/default doc, or null while it loads or is absent.
  final Map<String, dynamic>? billing;

  /// A switch is in flight: both buttons are off.
  final bool busy;

  /// Called with true for Enable, false for Disable.
  final void Function(bool enable) onSet;

  /// Whether Disable autopay is offered.
  static bool offersDisable({
    required bool displayOn,
    Map<String, dynamic>? billing,
  }) =>
      displayOn || TenantService.hasAutopaySubscription(billing);

  @override
  Widget build(BuildContext context) {
    final on = offersDisable(displayOn: displayOn, billing: billing);
    return Row(
      children: [
        if (!on)
          ElevatedButton.icon(
            onPressed: busy ? null : () => onSet(true),
            icon: busy
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.check_circle_outline, size: 18),
            label: const Text('Enable autopay'),
          ),
        if (on)
          OutlinedButton.icon(
            onPressed: busy ? null : () => onSet(false),
            icon: const Icon(Icons.cancel_outlined, size: 18),
            label: const Text('Disable autopay'),
            style: OutlinedButton.styleFrom(foregroundColor: AppTheme.error),
          ),
      ],
    );
  }
}
