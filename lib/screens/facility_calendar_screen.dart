import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';

import '../models/calendar_event_model.dart';
import '../router/app_route.dart';
import '../providers/active_facility_provider.dart';
import '../services/calendar_service.dart';
import '../theme/app_theme.dart';

// ── View mode ──────────────────────────────────────────────────────────────

enum _CalendarViewMode { month, week, agenda }

// ── Screen ─────────────────────────────────────────────────────────────────

class FacilityCalendarScreen extends ConsumerWidget {
  const FacilityCalendarScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final facilityIdAsync = ref.watch(activeFacilityIdProvider);

    // AppShell already provides sidebar + top bar; do not use ModernPageWrapper.
    return facilityIdAsync.when(
      data: (facilityId) {
        if (facilityId == null || facilityId.isEmpty) {
          return _CalendarPageLayout(
            title: 'Calendar',
            child: const Center(
              child: Text('Please select a facility to view the calendar.'),
            ),
          );
        }
        return _CalendarContent(facilityId: facilityId);
      },
      loading: () => _CalendarPageLayout(
        title: 'Calendar',
        child: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => _CalendarPageLayout(
        title: 'Calendar',
        child: Center(child: Text('Error: $e')),
      ),
    );
  }
}

/// Layout for calendar page content only (title row + content). No sidebar —
/// AppShell already provides the shell layout.
class _CalendarPageLayout extends StatelessWidget {
  final String title;
  final List<Widget>? actions;
  final Widget child;

  const _CalendarPageLayout({
    required this.title,
    this.actions,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: theme.textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (actions != null) ...actions!,
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(child: child),
      ],
    );
  }
}

// ── Content ────────────────────────────────────────────────────────────────

class _CalendarContent extends StatefulWidget {
  final String facilityId;
  const _CalendarContent({required this.facilityId});

  @override
  State<_CalendarContent> createState() => _CalendarContentState();
}

class _CalendarContentState extends State<_CalendarContent> {
  DateTime _focusedDay = DateTime.now();
  DateTime _selectedDay = DateTime.now();
  _CalendarViewMode _viewMode = _CalendarViewMode.month;
  CalendarFilter _filter = const CalendarFilter();

  // Loaded events for the visible range
  List<CalendarEvent> _events = [];
  Map<DateTime, List<CalendarEvent>> _eventsByDay = {};
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadEvents();
  }

  @override
  void didUpdateWidget(_CalendarContent old) {
    super.didUpdateWidget(old);
    if (old.facilityId != widget.facilityId) _loadEvents();
  }

  // Load events for a 3-month window centred on the focused month
  Future<void> _loadEvents() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final start = DateTime(_focusedDay.year, _focusedDay.month - 1, 1);
      final end = DateTime(_focusedDay.year, _focusedDay.month + 2, 0, 23, 59);
      final events = await CalendarService.getEventsForRange(
        facilityId: widget.facilityId,
        start: start,
        end: end,
      );
      if (mounted) {
        setState(() {
          _events = events;
          _eventsByDay = CalendarService.groupByDay(events);
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _loading = false;
        });
      }
    }
  }

  List<CalendarEvent> _eventsForDay(DateTime day) {
    final key = DateTime(day.year, day.month, day.day);
    final raw = _eventsByDay[key] ?? [];
    return raw.where((e) => _filter.isVisible(e.type)).toList();
  }

  List<CalendarEvent> get _filteredEvents =>
      _events.where((e) => _filter.isVisible(e.type)).toList();

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return _CalendarPageLayout(
      title: 'Calendar',
      actions: [
        _FilterButton(
          filter: _filter,
          onChanged: (f) => setState(() => _filter = f),
        ),
        const SizedBox(width: 8),
        _ViewToggle(
          current: _viewMode,
          onChanged: (v) => setState(() => _viewMode = v),
        ),
        const SizedBox(width: 8),
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: 'Refresh',
          onPressed: _loadEvents,
        ),
      ],
      child: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _ErrorView(error: _error!, onRetry: _loadEvents)
              : _buildBody(),
    );
  }

  Widget _buildBody() {
    return switch (_viewMode) {
      _CalendarViewMode.month => _buildMonthView(),
      _CalendarViewMode.week => _buildWeekView(),
      _CalendarViewMode.agenda => _buildAgendaView(),
    };
  }

  /// Format date for query params (yyyy-MM-dd).
  String _dateQuery(DateTime d) {
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  void _showAddToDateMenu(BuildContext context, DateTime day) {
    final theme = Theme.of(context);
    final dateStr = DateFormat('EEEE, MMMM d').format(day);
    final q = _dateQuery(day);
    final facilityId = widget.facilityId;

    final bottomPadding = MediaQuery.of(context).size.height * 0.35;

    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(bottom: bottomPadding),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  'Add to $dateStr',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
              ),
              const Divider(height: 1),
              ListTile(
                leading: Icon(Icons.notifications_active_outlined, color: theme.colorScheme.primary),
                title: const Text('Reminder'),
                subtitle: const Text('Schedule a reminder for this date'),
                onTap: () {
                  Navigator.pop(ctx);
                  context.go('${AppRoute.reminderCreate}?facilityId=$facilityId&date=$q');
                },
              ),
              ListTile(
                leading: Icon(Icons.payment_outlined, color: theme.colorScheme.primary),
                title: const Text('Payment due'),
                subtitle: const Text('Add a payment due on this date'),
                onTap: () {
                  Navigator.pop(ctx);
                  context.go('${AppRoute.paymentCreate}?facilityId=$facilityId&date=$q');
                },
              ),
              ListTile(
                leading: Icon(Icons.lock_outline, color: theme.colorScheme.primary),
                title: const Text('Overlock'),
                subtitle: const Text('Schedule an overlock for this date'),
                onTap: () {
                  Navigator.pop(ctx);
                  context.go('${AppRoute.managerOverlock}?facilityId=$facilityId&date=$q');
                },
              ),
              ListTile(
                leading: Icon(Icons.login_outlined, color: theme.colorScheme.primary),
                title: const Text('Move-in'),
                subtitle: const Text('Start move-in wizard for this date'),
                onTap: () {
                  Navigator.pop(ctx);
                  context.go('${AppRoute.moveInWizard}?facilityId=$facilityId&date=$q');
                },
              ),
              ListTile(
                leading: Icon(Icons.logout_outlined, color: theme.colorScheme.primary),
                title: const Text('Move-out'),
                subtitle: const Text('Open contracts to pick one for move-out on this date'),
                onTap: () {
                  Navigator.pop(ctx);
                  context.go('${AppRoute.contracts}?facilityId=$facilityId&date=$q');
                },
              ),
              ListTile(
                leading: Icon(Icons.build_circle_outlined, color: theme.colorScheme.primary),
                title: const Text('Units'),
                subtitle: const Text('View units (e.g. for maintenance)'),
                onTap: () {
                  Navigator.pop(ctx);
                  context.go('${AppRoute.units}?facilityId=$facilityId&date=$q');
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  // ── Month view ─────────────────────────────────────────────────────────────

  Widget _buildMonthView() {
    final theme = Theme.of(context);
    final selectedEvents = _eventsForDay(_selectedDay);

    return Column(
      children: [
        TableCalendar<CalendarEvent>(
          firstDay: DateTime(2020),
          lastDay: DateTime(2030),
          focusedDay: _focusedDay,
          selectedDayPredicate: (d) => isSameDay(d, _selectedDay),
          eventLoader: _eventsForDay,
          calendarFormat: CalendarFormat.month,
          startingDayOfWeek: StartingDayOfWeek.sunday,
          headerStyle: HeaderStyle(
            formatButtonVisible: false,
            titleCentered: true,
            titleTextStyle: theme.textTheme.titleMedium!
                .copyWith(fontWeight: FontWeight.w600),
            leftChevronIcon:
                Icon(Icons.chevron_left, color: theme.colorScheme.primary),
            rightChevronIcon:
                Icon(Icons.chevron_right, color: theme.colorScheme.primary),
          ),
          calendarStyle: CalendarStyle(
            outsideDaysVisible: false,
            selectedDecoration: BoxDecoration(
              color: theme.colorScheme.primary,
              shape: BoxShape.circle,
            ),
            todayDecoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            todayTextStyle:
                TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.bold),
            markerDecoration: const BoxDecoration(
              color: Colors.transparent,
            ),
          ),
          calendarBuilders: CalendarBuilders(
            markerBuilder: (context, day, events) {
              if (events.isEmpty) return const SizedBox.shrink();
              return _EventDots(events: events.cast<CalendarEvent>());
            },
          ),
          onDaySelected: (selected, focused) {
            setState(() {
              _selectedDay = selected;
              _focusedDay = focused;
            });
            _showAddToDateMenu(context, selected);
          },
          onPageChanged: (focused) {
            setState(() => _focusedDay = focused);
            _loadEvents();
          },
        ),
        const Divider(height: 1),
        Expanded(
          child: _DayEventList(
            day: _selectedDay,
            events: selectedEvents,
            facilityId: widget.facilityId,
          ),
        ),
      ],
    );
  }

  // ── Week view ──────────────────────────────────────────────────────────────

  Widget _buildWeekView() {
    final theme = Theme.of(context);
    final selectedEvents = _eventsForDay(_selectedDay);

    return Column(
      children: [
        TableCalendar<CalendarEvent>(
          firstDay: DateTime(2020),
          lastDay: DateTime(2030),
          focusedDay: _focusedDay,
          selectedDayPredicate: (d) => isSameDay(d, _selectedDay),
          eventLoader: _eventsForDay,
          calendarFormat: CalendarFormat.week,
          startingDayOfWeek: StartingDayOfWeek.sunday,
          headerStyle: HeaderStyle(
            formatButtonVisible: false,
            titleCentered: true,
            titleTextStyle: theme.textTheme.titleMedium!
                .copyWith(fontWeight: FontWeight.w600),
            leftChevronIcon:
                Icon(Icons.chevron_left, color: theme.colorScheme.primary),
            rightChevronIcon:
                Icon(Icons.chevron_right, color: theme.colorScheme.primary),
          ),
          calendarStyle: CalendarStyle(
            outsideDaysVisible: true,
            selectedDecoration: BoxDecoration(
              color: theme.colorScheme.primary,
              shape: BoxShape.circle,
            ),
            todayDecoration: BoxDecoration(
              color: theme.colorScheme.primary.withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            todayTextStyle:
                TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.bold),
          ),
          calendarBuilders: CalendarBuilders(
            markerBuilder: (context, day, events) {
              if (events.isEmpty) return const SizedBox.shrink();
              return _EventDots(events: events.cast<CalendarEvent>());
            },
          ),
          onDaySelected: (selected, focused) {
            setState(() {
              _selectedDay = selected;
              _focusedDay = focused;
            });
            _showAddToDateMenu(context, selected);
          },
          onPageChanged: (focused) {
            setState(() => _focusedDay = focused);
            _loadEvents();
          },
        ),
        const Divider(height: 1),
        Expanded(
          child: _DayEventList(
            day: _selectedDay,
            events: selectedEvents,
            facilityId: widget.facilityId,
          ),
        ),
      ],
    );
  }

  // ── Agenda view ────────────────────────────────────────────────────────────

  Widget _buildAgendaView() {
    final upcoming = _filteredEvents
        .where((e) => !e.date.isBefore(
            DateTime(_focusedDay.year, _focusedDay.month - 1, 1)))
        .toList();

    if (upcoming.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.event_available, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('No upcoming events', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    // Group by date
    final grouped = <DateTime, List<CalendarEvent>>{};
    for (final e in upcoming) {
      final key = DateTime(e.date.year, e.date.month, e.date.day);
      grouped.putIfAbsent(key, () => []).add(e);
    }
    final sortedDays = grouped.keys.toList()..sort();

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: sortedDays.length,
      itemBuilder: (context, i) {
        final day = sortedDays[i];
        final dayEvents = grouped[day]!;
        return _AgendaDayGroup(
          day: day,
          events: dayEvents,
          facilityId: widget.facilityId,
        );
      },
    );
  }
}

// ── Event dots marker ──────────────────────────────────────────────────────

class _EventDots extends StatelessWidget {
  final List<CalendarEvent> events;
  const _EventDots({required this.events});

  @override
  Widget build(BuildContext context) {
    final unique = <Color>{};
    for (final e in events) {
      unique.add(e.color);
      if (unique.length >= 3) break;
    }
    return Positioned(
      bottom: 4,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: unique
            .map((c) => Container(
                  width: 5,
                  height: 5,
                  margin: const EdgeInsets.symmetric(horizontal: 1),
                  decoration: BoxDecoration(color: c, shape: BoxShape.circle),
                ))
            .toList(),
      ),
    );
  }
}

// ── Day event list (used by month + week views) ────────────────────────────

class _DayEventList extends StatelessWidget {
  final DateTime day;
  final List<CalendarEvent> events;
  final String facilityId;

  const _DayEventList({
    required this.day,
    required this.events,
    required this.facilityId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = DateFormat('EEEE, MMMM d').format(day);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            label,
            style: theme.textTheme.titleSmall
                ?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        if (events.isEmpty)
          const Expanded(
            child: Center(
              child: Text('No events', style: TextStyle(color: Colors.grey)),
            ),
          )
        else
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              itemCount: events.length,
              separatorBuilder: (_, __) => const SizedBox(height: 4),
              itemBuilder: (context, i) => _EventTile(
                event: events[i],
                facilityId: facilityId,
              ),
            ),
          ),
      ],
    );
  }
}

// ── Agenda day group ───────────────────────────────────────────────────────

class _AgendaDayGroup extends StatelessWidget {
  final DateTime day;
  final List<CalendarEvent> events;
  final String facilityId;

  const _AgendaDayGroup({
    required this.day,
    required this.events,
    required this.facilityId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isToday = isSameDay(day, DateTime.now());
    final label = isToday
        ? 'Today — ${DateFormat('MMMM d').format(day)}'
        : DateFormat('EEEE, MMMM d').format(day);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          margin: const EdgeInsets.fromLTRB(12, 12, 12, 4),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: isToday
                ? theme.colorScheme.primary.withValues(alpha: 0.1)
                : theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: isToday ? theme.colorScheme.primary : null,
            ),
          ),
        ),
        ...events.map((e) => Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
              child: _EventTile(event: e, facilityId: facilityId),
            )),
      ],
    );
  }
}

// ── Event tile ─────────────────────────────────────────────────────────────

class _EventTile extends StatelessWidget {
  final CalendarEvent event;
  final String facilityId;

  const _EventTile({required this.event, required this.facilityId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _showDetail(context),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: event.color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: event.color.withValues(alpha: 0.25),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: event.color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(event.icon, color: event.color, size: 18),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (event.subtitle != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        event.subtitle!,
                        style: theme.textTheme.bodySmall
                            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (event.formattedAmount != null) ...[
                const SizedBox(width: 8),
                Text(
                  event.formattedAmount!,
                  style: theme.textTheme.labelMedium?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: event.color,
                  ),
                ),
              ],
              if (event.priority == CalendarEventPriority.critical ||
                  event.priority == CalendarEventPriority.high) ...[
                const SizedBox(width: 6),
                Icon(
                  Icons.priority_high,
                  size: 16,
                  color: event.priority == CalendarEventPriority.critical
                      ? AppTheme.error
                      : AppTheme.warning,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  void _showDetail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _EventDetailSheet(event: event, facilityId: facilityId),
    );
  }
}

// ── Event detail bottom sheet ──────────────────────────────────────────────

class _EventDetailSheet extends StatelessWidget {
  final CalendarEvent event;
  final String facilityId;

  const _EventDetailSheet({required this.event, required this.facilityId});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.45,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: ListView(
            controller: scrollController,
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.outlineVariant,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // Type badge + title
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                    decoration: BoxDecoration(
                      color: event.color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: event.color.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(event.icon, size: 14, color: event.color),
                        const SizedBox(width: 5),
                        Text(
                          event.typeLabel,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: event.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  Text(
                    DateFormat('MMM d, yyyy').format(event.date),
                    style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                event.title,
                style: theme.textTheme.titleLarge
                    ?.copyWith(fontWeight: FontWeight.w700),
              ),
              if (event.subtitle != null) ...[
                const SizedBox(height: 4),
                Text(
                  event.subtitle!,
                  style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant),
                ),
              ],

              const SizedBox(height: 20),
              const Divider(),
              const SizedBox(height: 12),

              // Detail rows
              if (event.tenantName != null)
                _DetailRow(
                    icon: Icons.person,
                    label: 'Tenant',
                    value: event.tenantName!),
              if (event.unitNumber != null && event.unitNumber!.isNotEmpty)
                _DetailRow(
                    icon: Icons.storage,
                    label: 'Unit',
                    value: 'Unit ${event.unitNumber}'),
              if (event.formattedAmount != null)
                _DetailRow(
                    icon: Icons.attach_money,
                    label: 'Amount',
                    value: event.formattedAmount!),
              _DetailRow(
                icon: Icons.calendar_today,
                label: 'Date',
                value: DateFormat('EEEE, MMMM d, yyyy h:mm a').format(event.date),
              ),
              if (event.priority == CalendarEventPriority.critical ||
                  event.priority == CalendarEventPriority.high)
                _DetailRow(
                  icon: Icons.priority_high,
                  label: 'Priority',
                  value: event.priority == CalendarEventPriority.critical
                      ? 'Critical'
                      : 'High',
                  valueColor: event.priority == CalendarEventPriority.critical
                      ? AppTheme.error
                      : AppTheme.warning,
                ),

              const SizedBox(height: 24),

              // Action button
              if (event.actionRoute != null)
                FilledButton.icon(
                  icon: const Icon(Icons.open_in_new, size: 18),
                  label: Text(_actionLabel),
                  style: FilledButton.styleFrom(
                    backgroundColor: event.color,
                    minimumSize: const Size.fromHeight(48),
                  ),
                  onPressed: () {
                    Navigator.of(context).pop();
                    _navigate(context);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  String get _actionLabel {
    switch (event.type) {
      case CalendarEventType.moveIn:
      case CalendarEventType.moveOut:
      case CalendarEventType.billingDue:
        return 'View Tenant';
      case CalendarEventType.lienFiled:
      case CalendarEventType.auctionScheduled:
      case CalendarEventType.auctionComplete:
        return 'View Lien';
      case CalendarEventType.contractExpiring:
      case CalendarEventType.contractSigned:
        return 'View Contract';
      case CalendarEventType.overlockScheduled:
        return 'View Overlocks';
      default:
        return 'View Details';
    }
  }

  void _navigate(BuildContext context) {
    if (event.actionRoute == null) return;
    final params = event.actionParams ?? {};
    final query = params.entries.map((e) => '${e.key}=${e.value}').join('&');
    final route =
        query.isEmpty ? event.actionRoute! : '${event.actionRoute}?$query';
    context.go(route);
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color? valueColor;

  const _DetailRow({
    required this.icon,
    required this.label,
    required this.value,
    this.valueColor,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Icon(icon, size: 16, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 10),
          Text(
            '$label:',
            style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              value,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: valueColor,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── View toggle ────────────────────────────────────────────────────────────

class _ViewToggle extends StatelessWidget {
  final _CalendarViewMode current;
  final ValueChanged<_CalendarViewMode> onChanged;

  const _ViewToggle({required this.current, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return SegmentedButton<_CalendarViewMode>(
      segments: const [
        ButtonSegment<_CalendarViewMode>(
          value: _CalendarViewMode.month,
          icon: Icon(Icons.calendar_month, size: 18),
          label: Text('Month'),
          tooltip: 'Month view',
        ),
        ButtonSegment<_CalendarViewMode>(
          value: _CalendarViewMode.week,
          icon: Icon(Icons.calendar_view_week, size: 18),
          label: Text('Week'),
          tooltip: 'Week view',
        ),
        ButtonSegment<_CalendarViewMode>(
          value: _CalendarViewMode.agenda,
          icon: Icon(Icons.format_list_bulleted, size: 18),
          label: Text('Agenda'),
          tooltip: 'Agenda view',
        ),
      ],
      selected: {current},
      onSelectionChanged: (s) => onChanged(s.first),
      style: ButtonStyle(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

// ── Filter button ──────────────────────────────────────────────────────────

class _FilterButton extends StatelessWidget {
  final CalendarFilter filter;
  final ValueChanged<CalendarFilter> onChanged;

  const _FilterButton({required this.filter, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.filter_list),
      tooltip: 'Filter events',
      onPressed: () => _showFilterSheet(context),
    );
  }

  void _showFilterSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => _FilterSheet(filter: filter, onChanged: onChanged),
    );
  }
}

class _FilterSheet extends StatefulWidget {
  final CalendarFilter filter;
  final ValueChanged<CalendarFilter> onChanged;

  const _FilterSheet({required this.filter, required this.onChanged});

  @override
  State<_FilterSheet> createState() => _FilterSheetState();
}

class _FilterSheetState extends State<_FilterSheet> {
  late CalendarFilter _filter;

  @override
  void initState() {
    super.initState();
    _filter = widget.filter;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: theme.colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text('Filter Events',
              style: theme.textTheme.titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const SizedBox(height: 12),
          _FilterTile(
            label: 'Billing & Payments',
            icon: Icons.receipt_long,
            color: const Color(0xFF3B82F6),
            value: _filter.showBilling,
            onChanged: (v) =>
                setState(() => _filter = _filter.copyWith(showBilling: v)),
          ),
          _FilterTile(
            label: 'Delinquency & Liens',
            icon: Icons.gavel,
            color: const Color(0xFFEF4444),
            value: _filter.showDelinquency,
            onChanged: (v) =>
                setState(() => _filter = _filter.copyWith(showDelinquency: v)),
          ),
          _FilterTile(
            label: 'Move-Ins & Move-Outs',
            icon: Icons.swap_horiz,
            color: const Color(0xFF10B981),
            value: _filter.showMoveInOut,
            onChanged: (v) =>
                setState(() => _filter = _filter.copyWith(showMoveInOut: v)),
          ),
          _FilterTile(
            label: 'Contracts',
            icon: Icons.description,
            color: const Color(0xFFF59E0B),
            value: _filter.showContracts,
            onChanged: (v) =>
                setState(() => _filter = _filter.copyWith(showContracts: v)),
          ),
          _FilterTile(
            label: 'Insurance',
            icon: Icons.shield,
            color: const Color(0xFFF97316),
            value: _filter.showInsurance,
            onChanged: (v) =>
                setState(() => _filter = _filter.copyWith(showInsurance: v)),
          ),
          _FilterTile(
            label: 'Communications',
            icon: Icons.schedule_send,
            color: const Color(0xFF6366F1),
            value: _filter.showCommunications,
            onChanged: (v) => setState(
                () => _filter = _filter.copyWith(showCommunications: v)),
          ),
          _FilterTile(
            label: 'Operations',
            icon: Icons.build,
            color: const Color(0xFF6B7280),
            value: _filter.showOperations,
            onChanged: (v) =>
                setState(() => _filter = _filter.copyWith(showOperations: v)),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    setState(() => _filter = const CalendarFilter());
                    widget.onChanged(const CalendarFilter());
                    Navigator.of(context).pop();
                  },
                  child: const Text('Show All'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    widget.onChanged(_filter);
                    Navigator.of(context).pop();
                  },
                  child: const Text('Apply'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FilterTile extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool value;
  final ValueChanged<bool> onChanged;

  const _FilterTile({
    required this.label,
    required this.icon,
    required this.color,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      dense: true,
      contentPadding: EdgeInsets.zero,
      secondary: Icon(icon, color: color, size: 20),
      title: Text(label, style: const TextStyle(fontSize: 14)),
      value: value,
      activeColor: color,
      onChanged: onChanged,
    );
  }
}

// ── Error view ─────────────────────────────────────────────────────────────

class _ErrorView extends StatelessWidget {
  final String error;
  final VoidCallback onRetry;

  const _ErrorView({required this.error, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 64, color: AppTheme.error),
          const SizedBox(height: 16),
          const Text('Failed to load calendar events'),
          const SizedBox(height: 8),
          Text(error,
              style: const TextStyle(color: Colors.grey, fontSize: 12),
              textAlign: TextAlign.center),
          const SizedBox(height: 16),
          ElevatedButton.icon(
            icon: const Icon(Icons.refresh),
            label: const Text('Retry'),
            onPressed: onRetry,
          ),
        ],
      ),
    );
  }
}
