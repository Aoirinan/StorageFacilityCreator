import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../providers/active_facility_provider.dart';
import '../services/autopay_service.dart';
import '../models/autopay_event_model.dart';

class AutopayActivityScreen extends ConsumerStatefulWidget {
  const AutopayActivityScreen({super.key});

  @override
  ConsumerState<AutopayActivityScreen> createState() => _AutopayActivityScreenState();
}

class _AutopayActivityScreenState extends ConsumerState<AutopayActivityScreen> {
  String _searchQuery = '';
  AutopayEventAction? _filterAction; // null = All

  @override
  Widget build(BuildContext context) {
    final facilityIdAsync = ref.watch(activeFacilityIdProvider);

    return facilityIdAsync.when(
      data: (facilityId) {
        if (facilityId == null || facilityId.isEmpty) {
          return ModernPageWrapper(
            currentRoute: '/autopay-activity',
            title: 'Autopay Activity',
            child: const Center(child: Text('Please select a facility')),
          );
        }
        return _buildContent(context, facilityId);
      },
      loading: () => ModernPageWrapper(
        currentRoute: '/autopay-activity',
        title: 'Autopay Activity',
        child: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => ModernPageWrapper(
        currentRoute: '/autopay-activity',
        title: 'Autopay Activity',
        child: Center(child: Text('Error: $e')),
      ),
    );
  }

  Widget _buildContent(BuildContext context, String facilityId) {
    return ModernPageWrapper(
      currentRoute: '/autopay-activity',
      title: 'Autopay Activity',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildFilters(context),
          const SizedBox(height: 16),
          Expanded(child: _buildEventsList(facilityId)),
        ],
      ),
    );
  }

  Widget _buildFilters(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilterChip(
          label: const Text('All'),
          selected: _filterAction == null,
          onSelected: (_) => setState(() => _filterAction = null),
        ),
        FilterChip(
          label: const Text('Requested'),
          selected: _filterAction == AutopayEventAction.requested,
          onSelected: (_) => setState(() => _filterAction = AutopayEventAction.requested),
        ),
        FilterChip(
          label: const Text('Enabled'),
          selected: _filterAction == AutopayEventAction.enabled,
          onSelected: (_) => setState(() => _filterAction = AutopayEventAction.enabled),
        ),
        FilterChip(
          label: const Text('Disabled'),
          selected: _filterAction == AutopayEventAction.disabled,
          onSelected: (_) => setState(() => _filterAction = AutopayEventAction.disabled),
        ),
        const SizedBox(width: 24),
        SizedBox(
          width: 260,
          child: TextField(
            onChanged: (v) => setState(() => _searchQuery = v.trim().toLowerCase()),
            decoration: const InputDecoration(
              hintText: 'Search by tenant name...',
              prefixIcon: Icon(Icons.search),
              border: OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildEventsList(String facilityId) {
    return StreamBuilder(
      stream: AutopayService.watchAutopayEvents(facilityId),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(child: Text('Error: ${snapshot.error}'));
        }
        final docs = snapshot.data?.docs ?? [];
        final events = docs.map((d) => AutopayEventModel.fromFirestore(d)).toList();
        var filtered = events;
        if (_filterAction != null) {
          filtered = events.where((e) => e.action == _filterAction).toList();
        }
        if (_searchQuery.isNotEmpty) {
          filtered = filtered.where((e) =>
              (e.tenantName ?? '').toLowerCase().contains(_searchQuery)).toList();
        }
        if (filtered.isEmpty) {
          return const Center(child: Text('No autopay events'));
        }
        return ListView.builder(
          itemCount: filtered.length,
          itemBuilder: (context, index) {
            final event = filtered[index];
            return _EventTile(event: event);
          },
        );
      },
    );
  }
}

class _EventTile extends StatelessWidget {
  final AutopayEventModel event;

  const _EventTile({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDisabled = event.action == AutopayEventAction.disabled;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isDisabled ? AppTheme.error.withOpacity(0.06) : null,
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: _actionColor(event.action).withOpacity(0.2),
          child: Icon(_actionIcon(event.action), color: _actionColor(event.action), size: 22),
        ),
        title: Text(
          event.tenantName ?? 'Unknown tenant',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: isDisabled ? FontWeight.w600 : null,
          ),
        ),
        subtitle: Text(
          '${event.action.displayLabel} · ${event.source.value}'
          '${event.reason != null && event.reason!.isNotEmpty ? " · ${event.reason}" : ""}',
          style: theme.textTheme.bodySmall,
        ),
        trailing: Text(
          DateFormat.yMMMd().add_Hm().format(event.createdAt),
          style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
        ),
      ),
    );
  }

  Color _actionColor(AutopayEventAction action) {
    switch (action) {
      case AutopayEventAction.requested:
        return AppTheme.warning;
      case AutopayEventAction.enabled:
      case AutopayEventAction.paymentSucceeded:
      case AutopayEventAction.cardAdded:
        return AppTheme.success;
      case AutopayEventAction.disabled:
      case AutopayEventAction.paymentFailed:
      case AutopayEventAction.cardRemoved:
        return AppTheme.error;
    }
  }

  IconData _actionIcon(AutopayEventAction action) {
    switch (action) {
      case AutopayEventAction.requested:
        return Icons.schedule;
      case AutopayEventAction.enabled:
        return Icons.check_circle;
      case AutopayEventAction.disabled:
        return Icons.cancel;
      case AutopayEventAction.cardAdded:
        return Icons.credit_card;
      case AutopayEventAction.cardRemoved:
        return Icons.credit_card_off;
      case AutopayEventAction.paymentFailed:
        return Icons.error;
      case AutopayEventAction.paymentSucceeded:
        return Icons.payment;
    }
  }
}
