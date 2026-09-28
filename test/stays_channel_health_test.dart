import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/stays/stay_channel.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_export_link.dart';
import 'package:sfcapp/services/stays/stays_channel_health.dart';

final _now = DateTime.utc(2026, 10, 3, 12);

StayChannel _channel(StayChannelSyncHealth sync, {ChannelProvider provider = ChannelProvider.airbnb}) =>
    StayChannel(id: 'ch1', listingId: 'l1', provider: provider, active: true, sync: sync);

void main() {
  test('never synced', () {
    final view = describeChannelHealth(_channel(const StayChannelSyncHealth()), now: _now);
    expect(view.level, ChannelHealthLevel.neverSynced);
    expect(view.syncedLine, 'Not synced yet');
    expect(view.problem, isNull);
  });

  test('healthy: checked and synced times, and when Airbnb last fetched our link', () {
    final view = describeChannelHealth(
      _channel(StayChannelSyncHealth(
        lastAttemptAt: _now.subtract(const Duration(minutes: 6)),
        lastSuccessAt: _now.subtract(const Duration(minutes: 6)),
        lastStatus: ChannelSyncStatus.notModified,
      )),
      now: _now,
      exportLinks: [
        StayExportLink(
          id: 'xl1',
          listingId: 'l1',
          targetProvider: ExportTargetProvider.airbnb,
          active: true,
          lastFetchedAt: _now.subtract(const Duration(hours: 2)),
          lastFetcher: ExportTargetProvider.airbnb,
        ),
        // Another listing's and a revoked link are ignored.
        StayExportLink(id: 'xl2', listingId: 'l2', targetProvider: ExportTargetProvider.airbnb, active: true, lastFetchedAt: _now),
        StayExportLink(id: 'xl3', listingId: 'l1', targetProvider: ExportTargetProvider.airbnb, lastFetchedAt: _now),
      ],
    );
    expect(view.level, ChannelHealthLevel.ok);
    expect(view.checkedLine, 'Checked 6 min ago');
    expect(view.syncedLine, 'Last synced 6 min ago');
    expect(view.problem, isNull);
    expect(view.exportFetchLine, 'Airbnb last fetched your SFC calendar 2 h ago');
  });

  test('one failure is a warning; three in a row, or a dead link, is failing', () {
    final once = describeChannelHealth(
      _channel(StayChannelSyncHealth(
        lastAttemptAt: _now,
        lastSuccessAt: _now.subtract(const Duration(minutes: 40)),
        lastStatus: ChannelSyncStatus.timeout,
        consecutiveFailures: 1,
      )),
      now: _now,
    );
    expect(once.level, ChannelHealthLevel.warning);
    expect(once.problem, 'The calendar site took too long to answer.');

    final thrice = describeChannelHealth(
      _channel(StayChannelSyncHealth(
        lastAttemptAt: _now,
        lastSuccessAt: _now.subtract(const Duration(hours: 2)),
        lastStatus: ChannelSyncStatus.httpError,
        lastHttpStatus: 500,
        consecutiveFailures: 3,
      )),
      now: _now,
    );
    expect(thrice.level, ChannelHealthLevel.failing);
    expect(thrice.problem, contains('(500)'));
    expect(thrice.problem, contains('3 failed checks in a row'));

    final gone = describeChannelHealth(
      _channel(StayChannelSyncHealth(lastAttemptAt: _now, lastStatus: ChannelSyncStatus.gone, consecutiveFailures: 1)),
      now: _now,
    );
    expect(gone.level, ChannelHealthLevel.failing);
    expect(gone.syncedLine, 'Not synced yet');
  });

  test('a healthy feed not synced for over 6 hours is flagged', () {
    final view = describeChannelHealth(
      _channel(StayChannelSyncHealth(
        lastAttemptAt: _now.subtract(const Duration(hours: 7)),
        lastSuccessAt: _now.subtract(const Duration(hours: 7)),
        lastStatus: ChannelSyncStatus.ok,
      )),
      now: _now,
    );
    expect(view.level, ChannelHealthLevel.warning);
    expect(view.problem, 'Not synced for more than 6 hours.');
  });

  test('an export link not fetched yet says so', () {
    const link = StayExportLink(id: 'xl1', listingId: 'l1', targetProvider: ExportTargetProvider.vrbo, active: true);
    expect(exportFetchLine(link, _now), 'VRBO has not fetched your SFC calendar yet');
  });
}
