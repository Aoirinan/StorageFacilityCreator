import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import 'package:sfcapp/models/stays/stay.dart';
import 'package:sfcapp/models/stays/stay_access.dart';
import 'package:sfcapp/models/stays/stay_channel.dart';
import 'package:sfcapp/models/stays/stay_channel_blocks.dart';
import 'package:sfcapp/models/stays/stay_controls.dart';
import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_export_link.dart';
import 'package:sfcapp/models/stays/stay_folio.dart';
import 'package:sfcapp/models/stays/stay_guest_profile.dart';
import 'package:sfcapp/models/stays/stay_income_entry.dart';
import 'package:sfcapp/models/stays/stay_listing.dart';
import 'package:sfcapp/models/stays/stay_listing_access.dart';
import 'package:sfcapp/models/stays/stay_message_template.dart';
import 'package:sfcapp/models/stays/stay_night_lock_bucket.dart';
import 'package:sfcapp/models/stays/stay_private.dart';
import 'package:sfcapp/models/stays/stay_sync_log_entry.dart';
import 'package:sfcapp/models/stays/stay_task.dart';
import 'package:sfcapp/services/stays/stays_collections.dart';
import 'package:sfcapp/utils/local_date.dart';

/// Keys the rules let staff change on a stay directly (53-stays.rules);
/// everything else goes through the callables.
const Set<String> stayQuickEditKeys = {
  'guestDisplayName',
  'adults',
  'children',
  'pets',
  'rvLengthFt',
  'staffNotes',
  'cleanerNotes',
  'tags',
};

/// Keys an owner or manager may change on a task (54-stayTasks.rules).
const Set<String> stayTaskManagerKeys = {
  'status',
  'checklist',
  'suppliesLow',
  'issueNote',
  'photoPaths',
  'startedAt',
  'completedAt',
  'completedBy',
  'assigneeUid',
  'assigneeName',
  'dueByAt',
  'dueByLocal',
  'priority',
  'title',
  'notes',
  'needsAttention',
};

/// The subset an employee may change on an unassigned task or their own.
const Set<String> stayTaskEmployeeKeys = {
  'status',
  'checklist',
  'suppliesLow',
  'issueNote',
  'photoPaths',
  'startedAt',
  'completedAt',
  'completedBy',
};

/// A new returning-guest profile, written directly (owner/manager).
class StayGuestProfileDraft {
  const StayGuestProfileDraft({
    required this.name,
    this.phoneE164,
    this.email,
    this.vehicle,
    this.notes = '',
    this.doNotRent = false,
    this.doNotRentReason,
    this.consentEmail,
    this.consentSms,
    this.consentMethod,
  });

  final String name;
  final String? phoneE164;
  final String? email;
  final StayGuestVehicle? vehicle;
  final String notes;
  final bool doNotRent;
  final String? doNotRentReason;

  /// Consent is stamped with the server time and the signed-in user; it is
  /// used by nothing in v1.
  final bool? consentEmail;
  final bool? consentSms;
  final ConsentMethod? consentMethod;

  bool get hasConsent => consentEmail != null && consentSms != null && consentMethod != null;

  /// Whether saving this draft over a profile whose consent is [stored]
  /// records new consent. Only a change to what was agreed does: re-saving
  /// the same answers keeps the original recordedAt and recordedBy, which
  /// say when and by whom consent was captured.
  bool changesConsent(StayGuestConsent? stored) =>
      hasConsent &&
      !(stored != null && stored.email == consentEmail && stored.sms == consentSms && stored.method == consentMethod);
}

/// A copy-first message template to save (owner/manager). No auto-send in v1.
class StayMessageTemplateDraft {
  const StayMessageTemplateDraft({
    required this.key,
    required this.name,
    required this.body,
    required this.channelHint,
    this.listingIds = const [],
  });

  final String key;
  final String name;
  final String body;
  final TemplateChannelHint channelHint;
  final List<String> listingIds;
}

/// Reads of every Stays collection, and the few writes the rules allow the
/// app to make directly. Screens reach it through staysRepositoryProvider;
/// tests use test/support/fake_stays_repository.dart. Updates are
/// field-level merges, never whole-document sets of server-owned docs.
abstract class StaysRepository {
  // --- Reads ------------------------------------------------------------------
  Stream<StayControls> watchControls(String facilityId);
  Stream<List<StayListing>> watchListings(String facilityId);

  /// Stays overlapping [from, to): checkOut ≥ from (so today's departures
  /// are included), checkIn < to. At most 500.
  Stream<List<Stay>> watchStaysInRange(String facilityId, LocalDate from, LocalDate to);

  /// Stays the engine marked double booked (status `conflict`), at most 100.
  Stream<List<Stay>> watchConflictStays(String facilityId);
  Stream<Stay?> watchStay(String facilityId, String stayId);
  Future<Stay?> getStay(String facilityId, String stayId);

  /// Lock buckets for [months] ('YYYY-MM', at most 30), optionally one listing's.
  Stream<List<StayNightLockBucket>> watchLockBuckets(String facilityId, List<String> months, {String? listingId});
  Stream<List<StayChannelBlocks>> watchChannelBlocks(String facilityId);

  /// Tasks due in [from, to).
  Stream<List<StayTask>> watchTasksInRange(String facilityId, LocalDate from, LocalDate to);

  /// Open tasks assigned to [uid], due from [from].
  Stream<List<StayTask>> watchMyTasks(String facilityId, String uid, LocalDate from);
  Stream<StayTask?> watchTask(String facilityId, String taskId);
  Future<StayTask?> getTask(String facilityId, String taskId);

  Stream<List<StayIncomeEntry>> watchIncomeByMonth(String facilityId, String month);
  Stream<List<StayIncomeEntry>> watchIncomeForStay(String facilityId, String stayId);
  Stream<StayFolio?> watchFolio(String facilityId, String stayId);
  Future<StayPrivate?> getStayPrivate(String facilityId, String stayId);
  Future<StayAccess?> getStayAccess(String facilityId, String stayId);
  Future<StayListingAccess> getListingAccess(String facilityId, String listingId);
  Stream<List<StayMessageTemplate>> watchTemplates(String facilityId);
  Stream<List<StayGuestProfile>> watchGuests(String facilityId);
  Stream<List<StayChannel>> watchChannels(String facilityId);
  Stream<List<StayExportLink>> watchExportLinks(String facilityId);
  Stream<List<StaySyncLogEntry>> watchSyncLog(String facilityId, String channelId);

  // --- Direct writes the rules allow ------------------------------------------

  /// Staff quick edits; [changes] may only use [stayQuickEditKeys].
  Future<void> updateStayQuickFields(String facilityId, String stayId, Map<String, dynamic> changes);

  /// upcoming → checked_in, stamped with the server time (staff).
  Future<void> checkIn(String facilityId, String stayId);

  /// checked_in → checked_out, stamped with the server time (staff).
  Future<void> checkOut(String facilityId, String stayId);

  /// checked_in → upcoming (owner/manager).
  Future<void> undoCheckIn(String facilityId, String stayId);

  /// checked_out → checked_in (owner/manager).
  Future<void> undoCheckOut(String facilityId, String stayId);

  /// Records that a template was copied or opened for this stay.
  Future<void> markMessage(String facilityId, String stayId, String templateKey);

  /// Owners/managers may use [stayTaskManagerKeys], employees [stayTaskEmployeeKeys].
  Future<void> updateTask(String facilityId, String taskId, Map<String, dynamic> changes);
  Future<void> startTask(String facilityId, String taskId);
  Future<void> completeTask(String facilityId, String taskId);

  /// A manual to-do (owner/manager); returns its id.
  Future<String> createManualTask(
    String facilityId, {
    required StayTaskCategory category,
    required String title,
    required LocalDate dueDate,
    String? listingId,
    String notes = '',
  });

  Future<void> saveListingAccess(StayListingAccess access);
  Future<void> saveStayAccess(String facilityId, String stayId, {String? doorCode, String? gateCode, String accessNotes = ''});
  Future<void> deleteStayAccess(String facilityId, String stayId);
  Future<void> updateStayPrivate(String facilityId, String stayId, {String? fullName, String? privateNotes});
  Future<String> createGuestProfile(String facilityId, StayGuestProfileDraft draft);
  Future<void> updateGuestProfile(String facilityId, String profileId, StayGuestProfileDraft draft);
  Future<void> deleteGuestProfile(String facilityId, String profileId);
  Future<String> saveTemplate(String facilityId, StayMessageTemplateDraft draft, {String? templateId});
  Future<void> deleteTemplate(String facilityId, String templateId);
}

final RegExp _templateKeyPattern = RegExp(r'^[a-z0-9_]{1,40}$');

class FirestoreStaysRepository implements StaysRepository {
  FirestoreStaysRepository({String? Function()? currentUid})
      : _currentUid = currentUid ?? (() => FirebaseAuth.instance.currentUser?.uid);

  final String? Function() _currentUid;

  static const int staysReadLimit = 500;

  CollectionReference<Map<String, dynamic>> _col(String facilityId, String name) =>
      StaysCollections.open(facilityId, name);

  String _uid() {
    final uid = _currentUid();
    if (uid == null || uid.isEmpty) throw StateError('Sign in to change Stays.');
    return uid;
  }

  Map<String, dynamic> _stamp() => {'updatedAt': FieldValue.serverTimestamp(), 'updatedBy': _uid()};

  @override
  Stream<StayControls> watchControls(String facilityId) => StaysCollections.controlsDoc(facilityId)
      .snapshots()
      .map((doc) => StayControls.fromFirestore(doc, facilityId: facilityId));

  @override
  Stream<List<StayListing>> watchListings(String facilityId) => _col(facilityId, StaysCollections.listings)
      .snapshots()
      .map((snap) => snap.docs.map(StayListing.fromFirestore).toList()
        ..sort((a, b) {
          final byGroup = a.displayGroup.compareTo(b.displayGroup);
          if (byGroup != 0) return byGroup;
          final byOrder = a.sortOrder.compareTo(b.sortOrder);
          return byOrder != 0 ? byOrder : a.name.compareTo(b.name);
        }));

  @override
  Stream<List<Stay>> watchStaysInRange(String facilityId, LocalDate from, LocalDate to) {
    final toYmd = to.toYmd();
    return _col(facilityId, StaysCollections.stays)
        .where('checkOut', isGreaterThanOrEqualTo: from.toYmd())
        .orderBy('checkOut')
        .limit(staysReadLimit)
        .snapshots()
        .map((snap) => snap.docs.map(Stay.fromFirestore).where((s) => s.checkIn.compareTo(toYmd) < 0).toList());
  }

  @override
  Stream<List<Stay>> watchConflictStays(String facilityId) => _col(facilityId, StaysCollections.stays)
      .where('status', isEqualTo: StayStatus.conflict.wire)
      .limit(100)
      .snapshots()
      .map((snap) => snap.docs.map(Stay.fromFirestore).toList());

  @override
  Stream<Stay?> watchStay(String facilityId, String stayId) => _col(facilityId, StaysCollections.stays)
      .doc(stayId)
      .snapshots()
      .map((doc) => doc.exists ? Stay.fromFirestore(doc) : null);

  @override
  Future<Stay?> getStay(String facilityId, String stayId) async {
    final doc = await _col(facilityId, StaysCollections.stays).doc(stayId).get();
    return doc.exists ? Stay.fromFirestore(doc) : null;
  }

  @override
  Stream<List<StayNightLockBucket>> watchLockBuckets(String facilityId, List<String> months, {String? listingId}) {
    if (months.isEmpty) return Stream.value(const []);
    Query<Map<String, dynamic>> q = _col(facilityId, StaysCollections.nightLocks);
    if (listingId != null) q = q.where('listingId', isEqualTo: listingId);
    q = q.where('month', whereIn: months.take(30).toList());
    return q.snapshots().map((snap) => snap.docs.map(StayNightLockBucket.fromFirestore).toList());
  }

  @override
  Stream<List<StayChannelBlocks>> watchChannelBlocks(String facilityId) =>
      _col(facilityId, StaysCollections.channelBlocks)
          .snapshots()
          .map((snap) => snap.docs.map(StayChannelBlocks.fromFirestore).toList());

  @override
  Stream<List<StayTask>> watchTasksInRange(String facilityId, LocalDate from, LocalDate to) =>
      _col(facilityId, StaysCollections.tasks)
          .where('dueDate', isGreaterThanOrEqualTo: from.toYmd())
          .where('dueDate', isLessThan: to.toYmd())
          .orderBy('dueDate')
          .limit(staysReadLimit)
          .snapshots()
          .map((snap) => snap.docs.map(StayTask.fromFirestore).toList());

  @override
  Stream<List<StayTask>> watchMyTasks(String facilityId, String uid, LocalDate from) =>
      _col(facilityId, StaysCollections.tasks)
          .where('assigneeUid', isEqualTo: uid)
          .where('status', whereIn: [StayTaskStatus.todo.wire, StayTaskStatus.inProgress.wire])
          .where('dueDate', isGreaterThanOrEqualTo: from.toYmd())
          .orderBy('dueDate')
          .limit(staysReadLimit)
          .snapshots()
          .map((snap) => snap.docs.map(StayTask.fromFirestore).toList());

  @override
  Stream<StayTask?> watchTask(String facilityId, String taskId) => _col(facilityId, StaysCollections.tasks)
      .doc(taskId)
      .snapshots()
      .map((doc) => doc.exists ? StayTask.fromFirestore(doc) : null);

  @override
  Future<StayTask?> getTask(String facilityId, String taskId) async {
    final doc = await _col(facilityId, StaysCollections.tasks).doc(taskId).get();
    return doc.exists ? StayTask.fromFirestore(doc) : null;
  }

  @override
  Stream<List<StayIncomeEntry>> watchIncomeByMonth(String facilityId, String month) =>
      _col(facilityId, StaysCollections.income)
          .where('receivedMonth', isEqualTo: month)
          .snapshots()
          .map((snap) => snap.docs.map(StayIncomeEntry.fromFirestore).toList());

  @override
  Stream<List<StayIncomeEntry>> watchIncomeForStay(String facilityId, String stayId) =>
      _col(facilityId, StaysCollections.income)
          .where('stayId', isEqualTo: stayId)
          .snapshots()
          .map((snap) => snap.docs.map(StayIncomeEntry.fromFirestore).toList());

  @override
  Stream<StayFolio?> watchFolio(String facilityId, String stayId) => _col(facilityId, StaysCollections.folios)
      .doc(stayId)
      .snapshots()
      .map((doc) => doc.exists ? StayFolio.fromFirestore(doc) : null);

  @override
  Future<StayPrivate?> getStayPrivate(String facilityId, String stayId) async {
    final doc = await _col(facilityId, StaysCollections.private).doc(stayId).get();
    return doc.exists ? StayPrivate.fromFirestore(doc) : null;
  }

  @override
  Future<StayAccess?> getStayAccess(String facilityId, String stayId) async {
    final doc = await _col(facilityId, StaysCollections.access).doc(stayId).get();
    return doc.exists ? StayAccess.fromFirestore(doc) : null;
  }

  @override
  Future<StayListingAccess> getListingAccess(String facilityId, String listingId) async {
    final doc = await _col(facilityId, StaysCollections.listingAccess).doc(listingId).get();
    return StayListingAccess.fromFirestore(doc, facilityId: facilityId);
  }

  @override
  Stream<List<StayMessageTemplate>> watchTemplates(String facilityId) =>
      _col(facilityId, StaysCollections.messageTemplates)
          .snapshots()
          .map((snap) => snap.docs.map(StayMessageTemplate.fromFirestore).toList()..sort((a, b) => a.name.compareTo(b.name)));

  @override
  Stream<List<StayGuestProfile>> watchGuests(String facilityId) => _col(facilityId, StaysCollections.guestProfiles)
      .orderBy('nameLower')
      .limit(staysReadLimit)
      .snapshots()
      .map((snap) => snap.docs.map(StayGuestProfile.fromFirestore).toList());

  @override
  Stream<List<StayChannel>> watchChannels(String facilityId) => _col(facilityId, StaysCollections.channels)
      .snapshots()
      .map((snap) => snap.docs.map(StayChannel.fromFirestore).toList());

  @override
  Stream<List<StayExportLink>> watchExportLinks(String facilityId) => _col(facilityId, StaysCollections.exportLinks)
      .snapshots()
      .map((snap) => snap.docs.map(StayExportLink.fromFirestore).toList());

  @override
  Stream<List<StaySyncLogEntry>> watchSyncLog(String facilityId, String channelId) =>
      _col(facilityId, StaysCollections.syncLog)
          .where('channelId', isEqualTo: channelId)
          .orderBy('finishedAt', descending: true)
          .limit(50)
          .snapshots()
          .map((snap) => snap.docs.map(StaySyncLogEntry.fromFirestore).toList());

  // --- Writes -------------------------------------------------------------------

  DocumentReference<Map<String, dynamic>> _stay(String facilityId, String stayId) =>
      _col(facilityId, StaysCollections.stays).doc(stayId);

  @override
  Future<void> updateStayQuickFields(String facilityId, String stayId, Map<String, dynamic> changes) {
    final bad = changes.keys.where((k) => !stayQuickEditKeys.contains(k)).toList();
    if (bad.isNotEmpty) throw ArgumentError('Not a quick-edit field: ${bad.join(', ')}');
    return _stay(facilityId, stayId).update({...changes, ..._stamp()});
  }

  @override
  Future<void> checkIn(String facilityId, String stayId) => _stay(facilityId, stayId).update({
        'arrivalState': StayArrivalState.checkedIn.wire,
        'checkedInAt': FieldValue.serverTimestamp(),
        ..._stamp(),
      });

  @override
  Future<void> checkOut(String facilityId, String stayId) => _stay(facilityId, stayId).update({
        'arrivalState': StayArrivalState.checkedOut.wire,
        'checkedOutAt': FieldValue.serverTimestamp(),
        ..._stamp(),
      });

  @override
  Future<void> undoCheckIn(String facilityId, String stayId) => _stay(facilityId, stayId).update({
        'arrivalState': StayArrivalState.upcoming.wire,
        'checkedInAt': null,
        ..._stamp(),
      });

  @override
  Future<void> undoCheckOut(String facilityId, String stayId) => _stay(facilityId, stayId).update({
        'arrivalState': StayArrivalState.checkedIn.wire,
        'checkedOutAt': null,
        ..._stamp(),
      });

  @override
  Future<void> markMessage(String facilityId, String stayId, String templateKey) {
    if (!_templateKeyPattern.hasMatch(templateKey)) throw ArgumentError('Bad template key: $templateKey');
    return _stay(facilityId, stayId).update({'messageMarks.$templateKey': FieldValue.serverTimestamp(), ..._stamp()});
  }

  DocumentReference<Map<String, dynamic>> _task(String facilityId, String taskId) =>
      _col(facilityId, StaysCollections.tasks).doc(taskId);

  @override
  Future<void> updateTask(String facilityId, String taskId, Map<String, dynamic> changes) {
    final bad = changes.keys.where((k) => !stayTaskManagerKeys.contains(k)).toList();
    if (bad.isNotEmpty) throw ArgumentError('Not a task field: ${bad.join(', ')}');
    return _task(facilityId, taskId).update({...changes, ..._stamp()});
  }

  @override
  Future<void> startTask(String facilityId, String taskId) => _task(facilityId, taskId).update({
        'status': StayTaskStatus.inProgress.wire,
        'startedAt': FieldValue.serverTimestamp(),
        ..._stamp(),
      });

  @override
  Future<void> completeTask(String facilityId, String taskId) => _task(facilityId, taskId).update({
        'status': StayTaskStatus.done.wire,
        'completedAt': FieldValue.serverTimestamp(),
        'completedBy': _uid(),
        ..._stamp(),
      });

  @override
  Future<String> createManualTask(
    String facilityId, {
    required StayTaskCategory category,
    required String title,
    required LocalDate dueDate,
    String? listingId,
    String notes = '',
  }) async {
    if (category == StayTaskCategory.turnover || category == StayTaskCategory.unknown) {
      throw ArgumentError('Turnovers are planned by the server.');
    }
    final uid = _uid();
    final ref = _col(facilityId, StaysCollections.tasks).doc();
    await ref.set({
      'facilityId': facilityId,
      'category': category.wire,
      'listingId': listingId,
      'stayId': null,
      'nextStayId': null,
      'title': title,
      'notes': notes,
      'dueDate': dueDate.toYmd(),
      'sameDayTurn': false,
      'priority': StayTaskPriority.normal.wire,
      'status': StayTaskStatus.todo.wire,
      'needsAttention': false,
      'assigneeUid': null,
      'assigneeName': null,
      'checklist': const <Map<String, dynamic>>[],
      'suppliesLow': const <String>[],
      'issueNote': '',
      'photoPaths': const <String>[],
      'createdBy': uid,
      'createdAt': FieldValue.serverTimestamp(),
      'updatedBy': uid,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return ref.id;
  }

  @override
  Future<void> saveListingAccess(StayListingAccess access) =>
      _col(access.facilityId, StaysCollections.listingAccess).doc(access.listingId).set({
        'facilityId': access.facilityId,
        'listingId': access.listingId,
        ...access.toEditableMap(),
        ..._stamp(),
      });

  @override
  Future<void> saveStayAccess(String facilityId, String stayId, {String? doorCode, String? gateCode, String accessNotes = ''}) =>
      _col(facilityId, StaysCollections.access).doc(stayId).set({
        'facilityId': facilityId,
        'stayId': stayId,
        'doorCode': doorCode,
        'gateCode': gateCode,
        'accessNotes': accessNotes,
        'source': StayAccessSource.manual.wire,
        ..._stamp(),
      });

  @override
  Future<void> deleteStayAccess(String facilityId, String stayId) =>
      _col(facilityId, StaysCollections.access).doc(stayId).delete();

  @override
  Future<void> updateStayPrivate(String facilityId, String stayId, {String? fullName, String? privateNotes}) {
    final changes = <String, dynamic>{
      if (fullName != null) 'fullName': fullName,
      if (privateNotes != null) 'privateNotes': privateNotes,
    };
    if (changes.isEmpty) return Future.value();
    return _col(facilityId, StaysCollections.private).doc(stayId).update({...changes, ..._stamp()});
  }

  Map<String, dynamic> _profileFields(StayGuestProfileDraft draft) => {
        'name': draft.name.trim(),
        'nameLower': draft.name.trim().toLowerCase(),
        'phoneE164': draft.phoneE164,
        'email': draft.email,
        'vehicle': draft.vehicle?.toMap(),
        'notes': draft.notes,
        'doNotRent': draft.doNotRent,
        'doNotRentReason': draft.doNotRent ? draft.doNotRentReason : null,
      };

  Map<String, dynamic>? _consent(StayGuestProfileDraft draft) => draft.hasConsent
      ? {
          'email': draft.consentEmail,
          'sms': draft.consentSms,
          'method': draft.consentMethod!.wire,
          'recordedAt': FieldValue.serverTimestamp(),
          'recordedBy': _uid(),
        }
      : null;

  @override
  Future<String> createGuestProfile(String facilityId, StayGuestProfileDraft draft) async {
    final uid = _uid();
    final ref = _col(facilityId, StaysCollections.guestProfiles).doc();
    await ref.set({
      'facilityId': facilityId,
      ..._profileFields(draft),
      'consent': _consent(draft),
      'stayCount': 0,
      'lastStayAt': null,
      'createdAt': FieldValue.serverTimestamp(),
      'createdBy': uid,
      'updatedAt': FieldValue.serverTimestamp(),
      'updatedBy': uid,
    });
    return ref.id;
  }

  @override
  Future<void> updateGuestProfile(String facilityId, String profileId, StayGuestProfileDraft draft) {
    final ref = _col(facilityId, StaysCollections.guestProfiles).doc(profileId);
    final changes = {..._profileFields(draft), ..._stamp()};
    if (!draft.hasConsent) return ref.update(changes);
    // Consent is re-stamped only when the answers change (see changesConsent),
    // read and written in one transaction.
    return ref.firestore.runTransaction((tx) async {
      final snap = await tx.get(ref);
      final stored = snap.exists ? StayGuestProfile.fromFirestore(snap).consent : null;
      tx.update(ref, {...changes, if (draft.changesConsent(stored)) 'consent': _consent(draft)});
    });
  }

  @override
  Future<void> deleteGuestProfile(String facilityId, String profileId) =>
      _col(facilityId, StaysCollections.guestProfiles).doc(profileId).delete();

  @override
  Future<String> saveTemplate(String facilityId, StayMessageTemplateDraft draft, {String? templateId}) async {
    if (!_templateKeyPattern.hasMatch(draft.key)) throw ArgumentError('Bad template key: ${draft.key}');
    final col = _col(facilityId, StaysCollections.messageTemplates);
    final ref = templateId == null ? col.doc() : col.doc(templateId);
    final fields = <String, dynamic>{
      'facilityId': facilityId,
      'key': draft.key,
      'name': draft.name,
      'body': draft.body,
      'channelHint': draft.channelHint.wire,
      'listingIds': draft.listingIds,
      'kind': 'copy',
      ..._stamp(),
    };
    if (templateId == null) {
      await ref.set({...fields, 'seeded': false, 'createdAt': FieldValue.serverTimestamp(), 'createdBy': _uid()});
    } else {
      await ref.update(fields);
    }
    return ref.id;
  }

  @override
  Future<void> deleteTemplate(String facilityId, String templateId) =>
      _col(facilityId, StaysCollections.messageTemplates).doc(templateId).delete();
}
