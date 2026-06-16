import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class DashboardOwnerTipsDialogResult {
  final bool neverShowAgain;

  const DashboardOwnerTipsDialogResult({required this.neverShowAgain});
}

/// Carousel of practical tips shown after login on the owner dashboard.
class DashboardOwnerTipsDialog extends StatefulWidget {
  const DashboardOwnerTipsDialog({super.key});

  @override
  State<DashboardOwnerTipsDialog> createState() => _DashboardOwnerTipsDialogState();
}

class _OwnerTip {
  final IconData icon;
  final String title;
  final String body;

  const _OwnerTip({
    required this.icon,
    required this.title,
    required this.body,
  });
}

class _DashboardOwnerTipsDialogState extends State<DashboardOwnerTipsDialog> {
  static const List<_OwnerTip> _tips = [
    _OwnerTip(
      icon: Icons.swap_horiz,
      title: 'Facility switcher',
      body:
          'Use the facility menu in the top bar to change which site you are working on. '
          'When you pick “All” or a single facility, dashboards and search follow that context.',
    ),
    _OwnerTip(
      icon: Icons.search,
      title: 'Global search',
      body:
          'The search field searches tenants, units, and facilities across your access. '
          'Clear the field to return to the normal dashboard view.',
    ),
    _OwnerTip(
      icon: Icons.refresh,
      title: 'Sync counts',
      body:
          'If occupancy or tenant totals look off, use the refresh icon next to the facility switcher '
          'to recompute stats for all facilities you manage.',
    ),
    _OwnerTip(
      icon: Icons.people_outline,
      title: 'Tenants and units',
      body:
          'Add tenants from Tenants, assign units from Units or the site map, and keep move-in dates current '
          'so delinquency and billing stay accurate.',
    ),
    _OwnerTip(
      icon: Icons.payments_outlined,
      title: 'Payments and Billing',
      body:
          'Record payments, invoices, and autopay from Payments and Billing. '
          'Connect Stripe under billing settings when you are ready to take cards online.',
    ),
    _OwnerTip(
      icon: Icons.message_outlined,
      title: 'Messaging',
      body:
          'Send email and SMS from Messaging after texting is set up for a facility. '
          'Templates and conversations live in one place for staff.',
    ),
    _OwnerTip(
      icon: Icons.warning_amber_outlined,
      title: 'Delinquency and reports',
      body:
          'Use Delinquency for late balances and reminders, and open Reports for financial summaries. '
          'The sidebar groups everything by how you run day-to-day operations.',
    ),
  ];

  final PageController _pageController = PageController();
  bool _neverShowAgain = false;
  int _pageIndex = 0;

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void _finish() {
    Navigator.of(context).pop(
      DashboardOwnerTipsDialogResult(neverShowAgain: _neverShowAgain),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isLast = _pageIndex >= _tips.length - 1;

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.lightbulb_outline, color: colorScheme.primary, size: 28),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Tips for using SFC',
                      style: theme.textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: colorScheme.onSurface,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Close',
                    onPressed: _finish,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Quick ideas to get the most out of your dashboard.',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: colorScheme.onSurfaceVariant,
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                height: 220,
                child: PageView.builder(
                  controller: _pageController,
                  itemCount: _tips.length,
                  onPageChanged: (i) => setState(() => _pageIndex = i),
                  itemBuilder: (context, i) {
                    final tip = _tips[i];
                    return SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          CircleAvatar(
                            radius: 22,
                            backgroundColor: colorScheme.primary.withOpacity(0.12),
                            child: Icon(tip.icon, color: colorScheme.primary, size: 26),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            tip.title,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                              color: colorScheme.onSurface,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            tip.body,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.45,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_tips.length, (i) {
                  final active = i == _pageIndex;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: active ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(3),
                      color: active ? AppTheme.primaryBlue : colorScheme.outlineVariant,
                    ),
                  );
                }),
              ),
              const SizedBox(height: 4),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: Text(
                  "Don't show these tips again",
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
                value: _neverShowAgain,
                onChanged: (v) => setState(() => _neverShowAgain = v ?? false),
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  if (_pageIndex > 0)
                    TextButton(
                      onPressed: () {
                        _pageController.previousPage(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOutCubic,
                        );
                      },
                      child: const Text('Back'),
                    )
                  else
                    const SizedBox(width: 64),
                  const Spacer(),
                  if (!isLast)
                    FilledButton(
                      onPressed: () {
                        _pageController.nextPage(
                          duration: const Duration(milliseconds: 250),
                          curve: Curves.easeOutCubic,
                        );
                      },
                      child: const Text('Next'),
                    )
                  else
                    FilledButton(
                      onPressed: _finish,
                      child: const Text('Got it'),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
