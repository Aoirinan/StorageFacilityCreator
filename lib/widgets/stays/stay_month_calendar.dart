import 'package:flutter/material.dart';

import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/services/stays/stays_calendar_grid.dart';
import 'package:sfcapp/services/stays/stays_display.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/widgets/stays/quick_block_sheet.dart';
import 'package:sfcapp/widgets/stays/stay_peek_sheet.dart';
import 'package:sfcapp/widgets/stays/stay_source_badge.dart';
import 'package:sfcapp/widgets/stays/stay_status_chip.dart';

// The month grid of one listing. Bookings are filled in their source's
// colour, owner and maintenance blocks are hatched grey, a channel's "Not
// available" block is a faint hatch in the channel's colour (fainter still
// when it is only our own block echoed back), a booking removed from its
// channel is outlined in amber, and a double-booked night is striped red.

const List<String> _weekdayHeaders = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

Color channelColor(ChannelProvider provider) => switch (provider) {
      ChannelProvider.airbnb => StaySourceBadge.airbnbColor,
      ChannelProvider.vrbo => StaySourceBadge.vrboColor,
      ChannelProvider.booking => StaySourceBadge.bookingColor,
      ChannelProvider.hipcamp => StaySourceBadge.hipcampColor,
      _ => StaySourceBadge.blockColor,
    };

/// What a cell says, in words (also its semantics label).
String nightCellDescription(StayNightCell cell) {
  final day = weekdayDateLabel(cell.date);
  final holder = cell.holder;
  switch (cell.style) {
    case StayNightStyle.conflict:
      return '$day: double booked (${cell.hard.map((s) => s.guestLabel).join(' and ')})';
    case StayNightStyle.booking:
    case StayNightStyle.block:
      return '$day: ${holder!.guestLabel}';
    case StayNightStyle.removed:
      return '$day: ${cell.removed.first.guestLabel}, removed from its channel';
    case StayNightStyle.soft:
      return '$day: blocked on ${channelProviderLabel(cell.soft.first.provider)}';
    case StayNightStyle.echo:
      return '$day: your own block, as ${channelProviderLabel(cell.soft.first.provider)} shows it';
    case StayNightStyle.empty:
      return '$day: free';
  }
}

class StayMonthCalendar extends StatelessWidget {
  const StayMonthCalendar({super.key, required this.grid, required this.onTapCell});

  final StayMonthGrid grid;
  final void Function(StayNightCell cell) onTapCell;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Row(
          children: [
            for (final d in _weekdayHeaders)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  child: Text(
                    d,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: scheme.onSurfaceVariant),
                  ),
                ),
              ),
          ],
        ),
        for (final week in grid.weeks)
          Row(
            children: [
              for (final cell in week)
                Expanded(child: StayNightCellView(key: Key('stay-night-${cell.ymd}'), cell: cell, onTap: () => onTapCell(cell))),
            ],
          ),
      ],
    );
  }
}

class StayNightCellView extends StatelessWidget {
  const StayNightCellView({super.key, required this.cell, required this.onTap});

  final StayNightCell cell;
  final VoidCallback onTap;

  /// The text written in the cell: a name on its first night in view.
  String? _label() {
    final firstInRow = cell.date.weekday == DateTime.sunday || cell.date.day == 1;
    switch (cell.style) {
      case StayNightStyle.conflict:
        return 'Double booked';
      case StayNightStyle.booking:
      case StayNightStyle.block:
        final holder = cell.holder!;
        return cell.holderArrives || firstInRow ? holder.guestLabel : null;
      case StayNightStyle.removed:
        final removed = cell.removed.first;
        return removed.checkIn == cell.ymd || firstInRow ? 'Removed' : null;
      case StayNightStyle.soft:
      case StayNightStyle.echo:
        final block = cell.soft.first;
        return block.checkIn == cell.ymd || firstInRow ? 'Blocked on ${channelProviderLabel(block.provider)}' : null;
      case StayNightStyle.empty:
        return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final style = cell.style;
    Color? fill;
    Color? hatch;
    Border? border;
    Color textColor = scheme.onSurface;
    TextDecoration? decoration;
    switch (style) {
      case StayNightStyle.conflict:
        fill = AppTheme.error.withValues(alpha: 0.10);
        hatch = AppTheme.error.withValues(alpha: 0.45);
        border = Border.all(color: AppTheme.error, width: 2);
        textColor = AppTheme.error;
      case StayNightStyle.booking:
        final holder = cell.holder!;
        final (_, color) = StaySourceBadge.labelAndColor(holder.source, holder.kind);
        fill = color.withValues(alpha: 0.22);
        border = Border.all(color: color.withValues(alpha: 0.7));
      case StayNightStyle.block:
        fill = StaySourceBadge.blockColor.withValues(alpha: 0.18);
        hatch = StaySourceBadge.blockColor.withValues(alpha: 0.55);
        border = Border.all(color: StaySourceBadge.blockColor.withValues(alpha: 0.7));
      case StayNightStyle.removed:
        border = Border.all(color: AppTheme.warning, width: 1.5);
        textColor = AppTheme.warning;
        decoration = TextDecoration.lineThrough;
      case StayNightStyle.soft:
        hatch = channelColor(cell.soft.first.provider).withValues(alpha: 0.35);
        textColor = scheme.onSurfaceVariant;
      case StayNightStyle.echo:
        hatch = channelColor(cell.soft.first.provider).withValues(alpha: 0.15);
        textColor = scheme.onSurfaceVariant.withValues(alpha: 0.7);
      case StayNightStyle.empty:
        break;
    }
    final label = _label();
    final opacity = !cell.inMonth ? 0.4 : (cell.isPast ? 0.65 : 1.0);

    Widget content = Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: cell.isToday
                ? BoxDecoration(color: scheme.primary, borderRadius: BorderRadius.circular(10))
                : null,
            child: Text(
              '${cell.date.day}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: cell.isToday ? FontWeight.w700 : FontWeight.w500,
                color: cell.isToday ? scheme.onPrimary : scheme.onSurface,
              ),
            ),
          ),
          const Spacer(),
          if (label != null)
            Text(
              label,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 10, height: 1.15, color: textColor, decoration: decoration, fontWeight: FontWeight.w600),
            ),
        ],
      ),
    );
    if (hatch != null) {
      content = CustomPaint(painter: _HatchPainter(hatch), child: content);
    }
    return Semantics(
      button: true,
      label: nightCellDescription(cell),
      child: Opacity(
        opacity: opacity,
        child: InkWell(
          onTap: onTap,
          child: Container(
            height: 68,
            margin: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              color: fill ?? scheme.surface,
              border: border ?? Border.all(color: scheme.outlineVariant.withValues(alpha: 0.6)),
              borderRadius: BorderRadius.circular(4),
            ),
            clipBehavior: Clip.hardEdge,
            child: content,
          ),
        ),
      ),
    );
  }
}

class _HatchPainter extends CustomPainter {
  _HatchPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1.2;
    const gap = 8.0;
    for (var x = -size.height; x < size.width; x += gap) {
      canvas.drawLine(Offset(x, size.height), Offset(x + size.height, 0), paint);
    }
  }

  @override
  bool shouldRepaint(_HatchPainter oldDelegate) => oldDelegate.color != color;
}

/// The legend under the grid.
class StayCalendarLegend extends StatelessWidget {
  const StayCalendarLegend({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    Widget item(String text, {Color? fill, Color? border, Color? hatch}) {
      Widget swatch = Container(
        width: 16,
        height: 16,
        decoration: BoxDecoration(
          color: fill,
          border: Border.all(color: border ?? scheme.outlineVariant),
          borderRadius: BorderRadius.circular(3),
        ),
      );
      if (hatch != null) swatch = CustomPaint(foregroundPainter: _HatchPainter(hatch), child: swatch);
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [swatch, const SizedBox(width: 6), Flexible(child: Text(text, style: const TextStyle(fontSize: 12)))],
      );
    }

    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        item('Booking', fill: StaySourceBadge.airbnbColor.withValues(alpha: 0.22), border: StaySourceBadge.airbnbColor),
        item('Owner or maintenance block',
            fill: StaySourceBadge.blockColor.withValues(alpha: 0.18), hatch: StaySourceBadge.blockColor.withValues(alpha: 0.55)),
        item('Blocked on a channel (Stays can still book it)', hatch: StaySourceBadge.airbnbColor.withValues(alpha: 0.35)),
        item('Removed from its channel', border: AppTheme.warning),
        item('Double booked', fill: AppTheme.error.withValues(alpha: 0.10), border: AppTheme.error, hatch: AppTheme.error.withValues(alpha: 0.45)),
      ],
    );
  }
}

/// Everything on one night: the stays that hold or claim it, bookings the
/// channel removed, and channel blocks. A free night offers "Block".
Future<void> showStayNightSheet(
  BuildContext context, {
  required String facilityId,
  required String listingId,
  required String listingName,
  required StayNightCell cell,
  bool canManage = false,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        final scheme = Theme.of(sheetContext).colorScheme;
        Widget stayTile(Stay stay, {String? extra}) => ListTile(
              key: Key('stay-night-entry-${stay.id}'),
              contentPadding: EdgeInsets.zero,
              title: Text(stay.guestLabel),
              subtitle: Text([stayDatesLabel(stay.checkIn, stay.checkOut), if (extra != null) extra].join('\n')),
              trailing: Wrap(
                spacing: 6,
                children: [
                  StaySourceBadge(source: stay.source, kind: stay.kind, dense: true),
                  StayStatusChip(status: stay.status, dense: true),
                ],
              ),
              onTap: () => showStayPeekSheet(sheetContext, facilityId: facilityId, stay: stay, canManage: canManage),
            );
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${weekdayDateLabel(cell.date)} · $listingName',
                    style: Theme.of(sheetContext).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  if (cell.isConflict)
                    const Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text(
                        'Double booked: more than one booking claims this night. The first one keeps it.',
                        style: TextStyle(color: AppTheme.error),
                      ),
                    ),
                  const SizedBox(height: 8),
                  for (final (i, stay) in cell.hard.indexed)
                    stayTile(
                      stay,
                      extra: cell.hard.length > 1 ? (i == 0 ? 'Holds this night' : 'Lost this night') : null,
                    ),
                  for (final stay in cell.removed) stayTile(stay, extra: 'No longer on its channel'),
                  for (final block in cell.soft)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.event_busy, color: channelColor(block.provider)),
                      title: Text(block.echo
                          ? 'Your own block, as ${channelProviderLabel(block.provider)} shows it'
                          : 'Blocked on ${channelProviderLabel(block.provider)}'),
                      subtitle: Text(
                        '${stayDatesLabel(block.checkIn, block.checkOut)}\n'
                        'A soft block: it keeps Stays from double-booking by accident, but you can book over it.',
                      ),
                    ),
                  if (cell.isFree)
                    Text('Nothing on this night.', style: TextStyle(color: scheme.onSurfaceVariant)),
                  if (canManage && cell.hard.isEmpty && !cell.isPast) ...[
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      key: const Key('stay-night-block'),
                      onPressed: () {
                        Navigator.of(sheetContext).pop();
                        showQuickBlockSheet(
                          context,
                          facilityId: facilityId,
                          listingId: listingId,
                          checkIn: cell.ymd,
                          checkOut: cell.date.addDays(1).toYmd(),
                        );
                      },
                      icon: const Icon(Icons.block),
                      label: const Text('Block this night'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
