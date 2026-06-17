import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/payment_provider.dart';
import '../router/app_route.dart';
import 'invoice_list_screen.dart';
import 'payment_list_screen.dart';
import 'reminder_list_screen.dart';
import 'rent_payments/past_due_hub_tab.dart';

/// Unified Rent & payments hub: transactions, collect, past due, invoices, reminders.
class RentPaymentsShellScreen extends ConsumerStatefulWidget {
  const RentPaymentsShellScreen({super.key});

  @override
  ConsumerState<RentPaymentsShellScreen> createState() =>
      _RentPaymentsShellScreenState();
}

class _RentPaymentsShellScreenState extends ConsumerState<RentPaymentsShellScreen>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  bool _appliedRouteParams = false;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_appliedRouteParams) return;
    _appliedRouteParams = true;
    _applyQueryTab(initial: true);
  }

  void _applyQueryTab({bool initial = false}) {
    final params = GoRouterState.of(context).uri.queryParameters;
    final tab = params['tab'];
    final hubTab = RentPaymentsTabQuery.fromQuery(tab);
    final index = hubTab.index;

    if (_tabController.index != index) {
      _tabController.index = index;
    }
    ref.read(rentPaymentsTabProvider.notifier).state = hubTab;

    if (tab == 'autopay') {
      ref.read(paymentsTabIndexProvider.notifier).state = 1;
      if (params['tenantId']?.isNotEmpty == true) {
        ref.read(paymentsAutopaySelectedTenantIdProvider.notifier).state =
            params['tenantId'];
      }
    } else if (tab == 'onetime') {
      ref.read(paymentsTabIndexProvider.notifier).state = 2;
      if (params['tenantId']?.isNotEmpty == true) {
        ref.read(paymentsAutopaySelectedTenantIdProvider.notifier).state =
            params['tenantId'];
      }
    } else if (hubTab == RentPaymentsTab.collect && tab == 'collect') {
      final collectSub = ref.read(paymentsTabIndexProvider);
      if (collectSub == 0) {
        ref.read(paymentsTabIndexProvider.notifier).state = 1;
      }
    }
  }

  void _syncUrlToTab(int index) {
    final hubTab = RentPaymentsTab.values[index];
    ref.read(rentPaymentsTabProvider.notifier).state = hubTab;

    final uri = GoRouterState.of(context).uri;
    final params = Map<String, String>.from(uri.queryParameters);

    if (hubTab == RentPaymentsTab.collect) {
      final sub = ref.read(paymentsTabIndexProvider);
      if (sub == 2) {
        params['tab'] = 'onetime';
      } else if (sub == 1) {
        params['tab'] = 'autopay';
      } else {
        params['tab'] = 'collect';
      }
    } else {
      params['tab'] = hubTab.queryValue;
      params.remove('tenantId');
      params.remove('facilityId');
      params.remove('cardAdded');
    }

    final query = params.entries
        .map((e) =>
            '${Uri.encodeComponent(e.key)}=${Uri.encodeComponent(e.value)}')
        .join('&');
    final target =
        query.isEmpty ? AppRoute.payments : '${AppRoute.payments}?$query';
    if (uri.toString() != target) {
      context.go(target);
    }
  }

  void _onHubTabTap(int index) {
    _tabController.animateTo(index);
    _syncUrlToTab(index);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Container(
          color: colorScheme.surface,
          child: TabBar(
            controller: _tabController,
            isScrollable: true,
            onTap: _onHubTabTap,
            tabs: const [
              Tab(text: 'Transactions'),
              Tab(text: 'Collect'),
              Tab(text: 'Past due'),
              Tab(text: 'Invoices'),
              Tab(text: 'Reminders'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabController,
            physics: const NeverScrollableScrollPhysics(),
            children: const [
              PaymentListScreen(hubSection: PaymentListSection.transactions),
              PaymentListScreen(hubSection: PaymentListSection.collect),
              PastDueHubTab(),
              InvoiceListScreen(),
              ReminderListScreen(),
            ],
          ),
        ),
      ],
    );
  }
}
