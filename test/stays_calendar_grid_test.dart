import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/models/stays/stay_channel_blocks.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/services/stays/stays_calendar_grid.dart';
import 'package:sfcapp/utils/local_date.dart';

// All names and codes here are made up.

Stay _stay(
  String id,
  String checkIn,
  String checkOut, {
  String listingId = 'l1',
  StayKind kind = StayKind.reservation,
  StaySource source = StaySource.airbnb,
  StayStatus status = StayStatus.confirmed,
  int createdAtMs = 1000,
  StayConflict? conflict,
  String guest = '',
}) =>
    Stay(
      id: id,
      facilityId: 'f1',
      listingId: listingId,
      checkIn: checkIn,
      checkOut: checkOut,
      kind: kind,
      source: source,
      status: status,
      createdAtMs: createdAtMs,
      conflict: conflict,
      guestDisplayName: guest,
    );

final _today = LocalDate(2026, 10, 10);
final _october = LocalDate(2026, 10, 1);

StayMonthGrid _grid(List<Stay> stays, {List<StayChannelBlocks> blocks = const []}) =>
    buildStayMonthGrid(listingId: 'l1', month: _october, today: _today, stays: stays, channelBlocks: blocks);

void main() {
  test('the grid is whole weeks, Sunday first', () {
    final (from, to) = monthGridRange(LocalDate(2026, 10, 17));
    expect(from, LocalDate(2026, 9, 27)); // a Sunday
    expect(to, LocalDate(2026, 11, 1)); // Oct 31 is a Saturday
    final grid = _grid(const []);
    expect(grid.weeks.length, 5);
    expect(grid.weeks.every((w) => w.length == 7), isTrue);
    expect(grid.cellFor('2026-09-27')!.inMonth, isFalse);
    expect(grid.cellFor('2026-10-10')!.isToday, isTrue);
    expect(grid.cellFor('2026-10-09')!.isPast, isTrue);
  });

  test('a booking holds check-in up to, not including, checkout', () {
    final grid = _grid([_stay('airbnb_HMFAKE01', '2026-10-03', '2026-10-06', guest: 'Jane D.')]);
    expect(grid.cellFor('2026-10-02')!.style, StayNightStyle.empty);
    expect(grid.cellFor('2026-10-03')!.style, StayNightStyle.booking);
    expect(grid.cellFor('2026-10-03')!.holderArrives, isTrue);
    expect(grid.cellFor('2026-10-05')!.style, StayNightStyle.booking);
    expect(grid.cellFor('2026-10-05')!.holderArrives, isFalse);
    expect(grid.cellFor('2026-10-06')!.style, StayNightStyle.empty);
  });

  test('owner and maintenance blocks are blocks; other listings and cancelled stays are left out', () {
    final grid = _grid([
      _stay('man_a', '2026-10-12', '2026-10-14', kind: StayKind.ownerBlock, source: StaySource.owner),
      _stay('man_b', '2026-10-15', '2026-10-16', kind: StayKind.maintenanceBlock, source: StaySource.owner),
      _stay('man_c', '2026-10-20', '2026-10-22', listingId: 'other'),
      _stay('man_d', '2026-10-24', '2026-10-25', status: StayStatus.cancelled),
    ]);
    expect(grid.cellFor('2026-10-12')!.style, StayNightStyle.block);
    expect(grid.cellFor('2026-10-15')!.style, StayNightStyle.block);
    expect(grid.cellFor('2026-10-20')!.style, StayNightStyle.empty);
    expect(grid.cellFor('2026-10-24')!.style, StayNightStyle.empty);
  });

  test('channel blocks are soft, echoes fainter, and only on free nights', () {
    final blocks = [
      StayChannelBlocks(
        channelId: 'ch1',
        listingId: 'l1',
        provider: ChannelProvider.airbnb,
        ranges: const [
          ChannelBlockRange(checkIn: '2026-10-18', checkOut: '2026-10-21'),
          ChannelBlockRange(checkIn: '2026-10-25', checkOut: '2026-10-26', echo: true),
        ],
      ),
      const StayChannelBlocks(
        channelId: 'ch2',
        listingId: 'other',
        ranges: [ChannelBlockRange(checkIn: '2026-10-27', checkOut: '2026-10-28')],
      ),
    ];
    final grid = _grid([_stay('man_x', '2026-10-20', '2026-10-21', source: StaySource.direct)], blocks: blocks);
    expect(grid.cellFor('2026-10-18')!.style, StayNightStyle.soft);
    expect(grid.cellFor('2026-10-18')!.soft.single.provider, ChannelProvider.airbnb);
    // A booking over a soft block: the booking shows, and it is no conflict.
    expect(grid.cellFor('2026-10-20')!.style, StayNightStyle.booking);
    expect(grid.cellFor('2026-10-20')!.isConflict, isFalse);
    expect(grid.cellFor('2026-10-25')!.style, StayNightStyle.echo);
    expect(grid.cellFor('2026-10-27')!.style, StayNightStyle.empty);
  });

  test('a booking removed from its feed is shown, and holds nothing', () {
    final grid = _grid([
      _stay('airbnb_HMFAKE02', '2026-10-07', '2026-10-09', status: StayStatus.removedFromFeed),
      _stay('man_y', '2026-10-08', '2026-10-09', source: StaySource.walkUp),
    ]);
    expect(grid.cellFor('2026-10-07')!.style, StayNightStyle.removed);
    expect(grid.cellFor('2026-10-08')!.style, StayNightStyle.booking);
    expect(grid.cellFor('2026-10-08')!.removed.single.id, 'airbnb_HMFAKE02');
    expect(grid.cellFor('2026-10-08')!.isConflict, isFalse);
  });

  test('a double booking uses the engine conflict data: the winner holds, the night is striped', () {
    final winner = _stay('airbnb_HMFAKE03', '2026-10-03', '2026-10-06', createdAtMs: 500);
    final loser = _stay(
      'man_z',
      '2026-10-05',
      '2026-10-08',
      source: StaySource.direct,
      status: StayStatus.conflict,
      createdAtMs: 900,
      conflict: const StayConflict(stayIds: ['airbnb_HMFAKE03'], nights: ['2026-10-05']),
    );
    final grid = _grid([loser, winner]);
    final night = grid.cellFor('2026-10-05')!;
    expect(night.style, StayNightStyle.conflict);
    expect(night.holder!.id, 'airbnb_HMFAKE03');
    expect(night.hard.map((s) => s.id), ['airbnb_HMFAKE03', 'man_z']);
    // The loser keeps the nights it did not lose.
    expect(grid.cellFor('2026-10-06')!.style, StayNightStyle.booking);
    expect(grid.cellFor('2026-10-06')!.holder!.id, 'man_z');
  });

  test('summarizeConflicts names who holds the lost nights, soonest first', () {
    final winner = _stay('airbnb_HMFAKE04', '2026-11-01', '2026-11-03', guest: 'Jane D.');
    final early = _stay(
      'man_1',
      '2026-10-10',
      '2026-10-12',
      status: StayStatus.conflict,
      conflict: const StayConflict(stayIds: ['man_9'], nights: ['2026-10-11', '2026-10-10']),
    );
    final late = _stay(
      'man_2',
      '2026-11-02',
      '2026-11-04',
      guest: 'Sam P.',
      status: StayStatus.conflict,
      conflict: StayConflict(stayIds: const ['airbnb_HMFAKE04'], nights: const ['2026-11-02'], acknowledgedAt: DateTime.utc(2026)),
    );
    final out = summarizeConflicts([late, early, winner], others: [winner]);
    expect(out.map((c) => c.stay.id), ['man_1', 'man_2']);
    expect(out.first.nights, ['2026-10-10', '2026-10-11']);
    expect(out.first.holders, isEmpty); // man_9 is not loaded
    expect(out.last.holders.single.guestLabel, 'Jane D.');
    expect(out.last.acknowledged, isTrue);
  });
}
