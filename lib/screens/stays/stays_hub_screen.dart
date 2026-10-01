import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/stays/stays_calendar_tab.dart';
import 'package:sfcapp/screens/stays/stays_listings_tab.dart';

/// The Stays hub, with ?tab= kept in sync. The tabs built so far are
/// Calendar and Listings; any other ?tab= (today, bookings, turnovers,
/// earnings: later phases) opens the calendar.
class StaysHubScreen extends StatefulWidget {
  const StaysHubScreen({super.key, required this.facilityId, this.initialTab = 'today'});

  final String facilityId;
  final String initialTab;

  /// The tabs in order, by their ?tab= value.
  static const List<String> tabs = ['calendar', 'listings'];

  static int indexOfTab(String tab) {
    final i = tabs.indexOf(tab);
    return i < 0 ? 0 : i;
  }

  @override
  State<StaysHubScreen> createState() => _StaysHubScreenState();
}

class _StaysHubScreenState extends State<StaysHubScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(
    length: StaysHubScreen.tabs.length,
    vsync: this,
    initialIndex: StaysHubScreen.indexOfTab(widget.initialTab),
  );

  @override
  void didUpdateWidget(StaysHubScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    final index = StaysHubScreen.indexOfTab(widget.initialTab);
    if (widget.initialTab != oldWidget.initialTab && index != _tabs.index) _tabs.index = index;
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  void _onTap(int index) {
    final router = GoRouter.maybeOf(context);
    if (router == null) return;
    final target = AppRoute.staysWithTab(facilityId: widget.facilityId, tab: StaysHubScreen.tabs[index]);
    if (GoRouterState.of(context).uri.toString() != target) router.go(target);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      key: const Key('stays-hub'),
      children: [
        Container(
          color: scheme.surface,
          child: TabBar(
            controller: _tabs,
            isScrollable: true,
            onTap: _onTap,
            tabs: const [
              Tab(text: 'Calendar'),
              Tab(text: 'Listings'),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              StaysCalendarTab(facilityId: widget.facilityId),
              StaysListingsTab(facilityId: widget.facilityId),
            ],
          ),
        ),
      ],
    );
  }
}
