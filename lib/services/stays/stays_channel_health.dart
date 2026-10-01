import 'package:flutter/foundation.dart';

import 'package:sfcapp/models/stays/stay_channel.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_export_link.dart';
import 'package:sfcapp/services/stays/stays_display.dart';

// What the channel list says about each imported calendar and each export
// link, worked out from the docs the server writes (pure, unit-tested).

enum ChannelHealthLevel { ok, warning, failing, neverSynced }

@immutable
class ChannelHealthView {
  const ChannelHealthView({
    required this.level,
    required this.checkedLine,
    required this.syncedLine,
    this.problem,
    this.exportFetchLine,
  });

  final ChannelHealthLevel level;

  /// 'Checked 6 min ago', from the last attempt.
  final String checkedLine;

  /// 'Last synced 6 min ago', from the last success, or 'Not synced yet'.
  final String syncedLine;

  /// What went wrong on the last attempt, in words.
  final String? problem;

  /// 'Airbnb last fetched your SFC calendar 2 h ago', when an export link for
  /// that channel exists.
  final String? exportFetchLine;
}

/// A sync status in words, for the line under a calendar.
String channelStatusProblem(ChannelSyncStatus status, {int? httpStatus, String? errorCode}) {
  switch (status) {
    case ChannelSyncStatus.ok:
    case ChannelSyncStatus.notModified:
      return '';
    case ChannelSyncStatus.gone:
      return 'The site says this link no longer works. Copy a fresh Export calendar link and add it again.';
    case ChannelSyncStatus.httpError:
      return httpStatus == null
          ? 'The calendar could not be read.'
          : 'The calendar site answered with an error ($httpStatus).';
    case ChannelSyncStatus.invalidFeed:
      return 'The link did not return a calendar. Copy the Export calendar link again.';
    case ChannelSyncStatus.blockedHost:
      return 'That website is not one Stays can read calendars from.';
    case ChannelSyncStatus.timeout:
      return 'The calendar site took too long to answer.';
    case ChannelSyncStatus.tooLarge:
      return 'The calendar is too large to import.';
    case ChannelSyncStatus.suspicious:
      return 'The calendar suddenly lost bookings. Stays is keeping them until it is sure; check the channel.';
    case ChannelSyncStatus.unknown:
      return errorCode == null || errorCode.isEmpty ? 'The last check failed.' : 'The last check failed ($errorCode).';
  }
}

/// "Airbnb last fetched your SFC calendar 2 h ago", or that it has not yet.
String exportFetchLine(StayExportLink link, DateTime now) {
  final fetched = link.lastFetchedAt;
  final site = exportTargetLabel(link.targetProvider);
  if (fetched == null) return '$site has not fetched your SFC calendar yet';
  final who = link.lastFetcher == ExportTargetProvider.unknown ? site : exportTargetLabel(link.lastFetcher);
  return '$who last fetched your SFC calendar ${agoLabel(fetched, now)}';
}

/// The newest-fetched active export link of [listingId] made for [target].
StayExportLink? exportLinkFor(Iterable<StayExportLink> links, String listingId, ExportTargetProvider target) {
  StayExportLink? best;
  for (final link in links) {
    if (!link.active || link.listingId != listingId || link.targetProvider != target) continue;
    final a = link.lastFetchedAt;
    final b = best?.lastFetchedAt;
    if (best == null || (a != null && (b == null || a.isAfter(b)))) best = link;
  }
  return best;
}

ChannelHealthView describeChannelHealth(
  StayChannel channel, {
  required DateTime now,
  Iterable<StayExportLink> exportLinks = const [],
}) {
  final sync = channel.sync;
  final export = exportLinkFor(exportLinks, channel.listingId, exportTargetFor(channel.provider));
  final fetchLine = export == null ? null : exportFetchLine(export, now);
  if (sync.lastAttemptAt == null && sync.lastSuccessAt == null) {
    return ChannelHealthView(
      level: ChannelHealthLevel.neverSynced,
      checkedLine: 'Not checked yet',
      syncedLine: 'Not synced yet',
      exportFetchLine: fetchLine,
    );
  }
  final checked = 'Checked ${agoLabel(sync.lastAttemptAt ?? sync.lastSuccessAt, now)}';
  final synced = sync.lastSuccessAt == null ? 'Not synced yet' : 'Last synced ${agoLabel(sync.lastSuccessAt, now)}';
  final healthy = sync.lastStatus.isHealthy;
  final problem = healthy
      ? null
      : channelStatusProblem(sync.lastStatus, httpStatus: sync.lastHttpStatus, errorCode: sync.lastErrorCode);
  final ChannelHealthLevel level;
  if (!healthy && (sync.consecutiveFailures >= 3 || sync.lastStatus == ChannelSyncStatus.gone)) {
    level = ChannelHealthLevel.failing;
  } else if (!healthy || channel.isStale(now)) {
    level = ChannelHealthLevel.warning;
  } else {
    level = ChannelHealthLevel.ok;
  }
  final failures = sync.consecutiveFailures;
  final withCount = problem == null
      ? (channel.isStale(now) ? 'Not synced for more than 6 hours.' : null)
      : failures > 1
          ? '$problem ($failures failed checks in a row)'
          : problem;
  return ChannelHealthView(
    level: level,
    checkedLine: checked,
    syncedLine: synced,
    problem: withCount,
    exportFetchLine: fetchLine,
  );
}
