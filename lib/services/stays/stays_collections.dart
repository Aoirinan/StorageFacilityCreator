import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

/// Every Stays collection under facilities/{facilityId}/, opened through one
/// holder so tests can serve them from fakes (like FacilitySubcollections).
/// Stays code reaches Firestore only through here; it never opens a storage
/// collection (scripts/check_stays_isolation.cjs checks that).
class StaysCollections {
  StaysCollections._();

  static const controls = 'stayControls';
  static const listings = 'stayListings';
  static const listingAccess = 'stayListingAccess';
  static const channels = 'stayChannels';
  static const channelBlocks = 'stayChannelBlocks';
  static const exportLinks = 'stayExportLinks';
  static const syncLog = 'staySyncLog';
  static const stays = 'stays';
  static const private = 'stayPrivate';
  static const access = 'stayAccess';
  static const folios = 'stayFolios';
  static const nightLocks = 'stayNightLocks';
  static const tasks = 'stayTasks';
  static const income = 'stayIncome';
  static const expenses = 'stayExpenses';
  static const importBatches = 'stayImportBatches';
  static const guestProfiles = 'stayGuestProfiles';
  static const messageTemplates = 'stayMessageTemplates';

  /// The single controls doc id.
  static const currentDocId = 'current';

  static CollectionReference<Map<String, dynamic>> Function(String facilityId, String name) _open = _openInFirestore;

  static CollectionReference<Map<String, dynamic>> open(String facilityId, String name) => _open(facilityId, name);

  static DocumentReference<Map<String, dynamic>> controlsDoc(String facilityId) =>
      open(facilityId, controls).doc(currentDocId);

  /// Serves every Stays collection from [open] instead of Firestore; null
  /// restores Firestore.
  @visibleForTesting
  static void overrideForTesting(
    CollectionReference<Map<String, dynamic>> Function(String facilityId, String name)? open,
  ) {
    _open = open ?? _openInFirestore;
  }

  static CollectionReference<Map<String, dynamic>> _openInFirestore(String facilityId, String name) =>
      FirebaseFirestore.instance.collection('facilities').doc(facilityId).collection(name);
}
