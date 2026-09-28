import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';

/// facilities/{fid}/stayExportLinks/{linkId}: an iCal link a channel imports
/// (busy blocks only, no guest data) and its fetch telemetry. The URL itself
/// is fetched through the audited staysGetExportUrl callable.
class StayExportLink {
  const StayExportLink({
    required this.id,
    required this.listingId,
    this.targetProvider = ExportTargetProvider.unknown,
    this.label = '',
    this.scope = ExportScope.blocksOnly,
    this.active = false,
    this.lastFetchedAt,
    this.lastFetcher = ExportTargetProvider.unknown,
    this.lastStatus,
    this.createdAt,
    this.rotatedAt,
    this.revokedAt,
  });

  factory StayExportLink.fromFirestore(DocumentSnapshot<Object?> doc) =>
      StayExportLink.fromMap(doc.id, stayDocData(doc));

  factory StayExportLink.fromMap(String id, Map<String, dynamic> d) {
    final stats = stayMap(d['stats']);
    return StayExportLink(
      id: id,
      listingId: stayStr(d['listingId']),
      targetProvider: ExportTargetProvider.fromWire(d['targetProvider']),
      label: stayStr(d['label']),
      scope: d['scope'] == null ? ExportScope.blocksOnly : ExportScope.fromWire(d['scope']),
      active: stayTrue(d['active']),
      lastFetchedAt: stayTime(stats['lastFetchedAt']),
      lastFetcher: ExportTargetProvider.fromWire(stats['lastFetcher']),
      lastStatus: stayIntOrNull(stats['lastStatus']),
      createdAt: stayTime(d['createdAt']),
      rotatedAt: stayTime(d['rotatedAt']),
      revokedAt: stayTime(d['revokedAt']),
    );
  }

  final String id;
  final String listingId;
  final ExportTargetProvider targetProvider;
  final String label;
  final ExportScope scope;
  final bool active;

  /// When the channel last fetched our calendar ("Airbnb last fetched 2 h ago").
  final DateTime? lastFetchedAt;
  final ExportTargetProvider lastFetcher;
  final int? lastStatus;
  final DateTime? createdAt;
  final DateTime? rotatedAt;
  final DateTime? revokedAt;
}
