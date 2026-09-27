import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sfcapp/services/unit_service.dart';

Stream<Map<String, dynamic>?> _facilityDocInFirestore(String facilityId) =>
    FirebaseFirestore.instance
        .collection('facilities')
        .doc(facilityId)
        .snapshots()
        .map((doc) => doc.data());

Stream<Map<String, dynamic>?> Function(String facilityId) _facilityDoc =
    _facilityDocInFirestore;

/// Serves [unitLabelsIncludeAreaProvider] from [docs] instead of the
/// facility doc in Firestore; null restores Firestore.
@visibleForTesting
set unitLabelFacilityDocForTesting(
        Stream<Map<String, dynamic>?> Function(String facilityId)? docs) =>
    _facilityDoc = docs ?? _facilityDocInFirestore;

/// Whether the facility names units with their area
/// (`unitNumbersRepeatAcrossAreas`, as `unitLabelsIncludeArea` reads a
/// loaded facility), for screens
/// that show a tenant's unit without otherwise loading the facility.
///
/// Listens to the facility doc, so an owner turning the setting on or off
/// reaches every open screen without a reload. It was a one-off read cached
/// for the session. Disposed when no screen watches it.
///
/// A facility that cannot be read counts as off, the label every facility
/// had before the setting: never an error the screen has to handle, and
/// nothing for Riverpod to retry.
final unitLabelsIncludeAreaProvider =
    StreamProvider.autoDispose.family<bool, String>((ref, facilityId) {
  if (facilityId.isEmpty || facilityId == 'all') return Stream.value(false);
  Stream<Map<String, dynamic>?> docs;
  try {
    docs = _facilityDoc(facilityId);
  } catch (_) {
    return Stream.value(false);
  }
  return docs
      .map(UnitService.repeatsUnitNumbersAcrossAreas)
      .transform(StreamTransformer<bool, bool>.fromHandlers(
        handleError: (_, __, sink) => sink.add(false),
      ));
});

/// [unitLabelsIncludeAreaProvider] for [facilityId], for a tap handler that
/// fills a message: the setting as the facility doc has it now. Listens
/// while it waits, so the autoDispose provider is not dropped mid-read.
Future<bool> readUnitLabelsIncludeArea(WidgetRef ref, String facilityId) async {
  final provider = unitLabelsIncludeAreaProvider(facilityId);
  final sub = ref.listenManual(provider, (_, __) {});
  try {
    return await ref.read(provider.future);
  } finally {
    sub.close();
  }
}
