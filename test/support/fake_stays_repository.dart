import 'dart:async';

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
import 'package:sfcapp/services/stays/stays_repository.dart';
import 'package:sfcapp/utils/local_date.dart';

/// One direct write a test made through [FakeStaysRepository].
class FakeStaysWrite {
  const FakeStaysWrite(this.op, this.collection, this.id, this.data);

  /// 'update', 'set' or 'delete'.
  final String op;
  final String collection;
  final String id;
  final Map<String, dynamic> data;
}

/// StaysRepository in memory: docs are raw maps (as Firestore would hold
/// them) seeded with [seed], read back through the real models, and every
/// write is recorded in [writes] and applied. Streams emit at once and again
/// after each change.
class FakeStaysRepository implements StaysRepository {
  FakeStaysRepository({this.uid = 'test-uid', DateTime Function()? now}) : _now = now ?? DateTime.now;

  final String uid;
  final DateTime Function() _now;

  /// '{facilityId}/{collection}' → id → data.
  final Map<String, Map<String, Map<String, dynamic>>> _docs = {};
  final List<FakeStaysWrite> writes = [];
  final StreamController<void> _changes = StreamController<void>.broadcast();

  /// When set, every write throws it.
  Object? writeError;

  int _autoId = 0;

  Map<String, Map<String, dynamic>> _col(String facilityId, String collection) =>
      _docs.putIfAbsent('$facilityId/$collection', () => {});

  void seed(String facilityId, String collection, String id, Map<String, dynamic> data) {
    _col(facilityId, collection)[id] = Map<String, dynamic>.from(data);
    _changes.add(null);
  }

  Map<String, dynamic>? read(String facilityId, String collection, String id) => _col(facilityId, collection)[id];

  Stream<T> _watch<T>(T Function() read) async* {
    yield read();
    await for (final _ in _changes.stream) {
      yield read();
    }
  }

  Iterable<MapEntry<String, Map<String, dynamic>>> _entries(String facilityId, String collection) =>
      _col(facilityId, collection).entries;

  void _write(String op, String facilityId, String collection, String id, Map<String, dynamic> data) {
    final error = writeError;
    if (error != null) throw error;
    writes.add(FakeStaysWrite(op, collection, id, data));
    final col = _col(facilityId, collection);
    Object? resolve(Object? v) => v is _ServerTime
        ? _now()
        : v is Map<String, dynamic>
            ? {for (final e in v.entries) e.key: resolve(e.value)}
            : v;
    final resolved = {for (final e in data.entries) e.key: resolve(e.value)};
    switch (op) {
      case 'delete':
        col.remove(id);
      case 'set':
        col[id] = resolved;
      default:
        final doc = col[id];
        if (doc == null) throw StateError('No document to update: $collection/$id');
        for (final e in resolved.entries) {
          if (e.key.contains('.')) {
            final [parent, child] = e.key.split('.');
            final nested = Map<String, dynamic>.from((doc[parent] as Map?) ?? const {});
            nested[child] = e.value;
            doc[parent] = nested;
          } else {
            doc[e.key] = e.value;
          }
        }
    }
    _changes.add(null);
  }

  static const _serverTime = _ServerTime();

  Map<String, dynamic> _stamp() => {'updatedAt': _serverTime, 'updatedBy': uid};

  // --- Reads ---------------------------------------------------------------------

  @override
  Stream<StayControls> watchControls(String facilityId) => _watch(() {
        final d = read(facilityId, StaysCollections.controls, StaysCollections.currentDocId);
        return d == null ? StayControls.defaults(facilityId) : StayControls.fromMap(d, facilityId: facilityId);
      });

  @override
  Stream<List<StayListing>> watchListings(String facilityId) => _watch(() =>
      [for (final e in _entries(facilityId, StaysCollections.listings)) StayListing.fromMap(e.key, e.value)]);

  List<Stay> _staysIn(String facilityId, LocalDate from, LocalDate to) => [
        for (final e in _entries(facilityId, StaysCollections.stays))
          if ((e.value['checkOut'] as String? ?? '').compareTo(from.toYmd()) >= 0 &&
              (e.value['checkIn'] as String? ?? '').compareTo(to.toYmd()) < 0)
            Stay.fromMap(e.key, e.value),
      ]..sort((a, b) => a.checkOut.compareTo(b.checkOut));

  @override
  Stream<List<Stay>> watchStaysInRange(String facilityId, LocalDate from, LocalDate to) =>
      _watch(() => _staysIn(facilityId, from, to));

  @override
  Stream<List<Stay>> watchConflictStays(String facilityId) => _watch(() => [
        for (final e in _entries(facilityId, StaysCollections.stays))
          if (e.value['status'] == StayStatus.conflict.wire) Stay.fromMap(e.key, e.value),
      ]);

  @override
  Stream<Stay?> watchStay(String facilityId, String stayId) => _watch(() {
        final d = read(facilityId, StaysCollections.stays, stayId);
        return d == null ? null : Stay.fromMap(stayId, d);
      });

  @override
  Future<Stay?> getStay(String facilityId, String stayId) async {
    final d = read(facilityId, StaysCollections.stays, stayId);
    return d == null ? null : Stay.fromMap(stayId, d);
  }

  @override
  Stream<List<StayNightLockBucket>> watchLockBuckets(String facilityId, List<String> months, {String? listingId}) =>
      _watch(() => [
            for (final e in _entries(facilityId, StaysCollections.nightLocks))
              if (months.contains(e.value['month']) && (listingId == null || e.value['listingId'] == listingId))
                StayNightLockBucket.fromMap(e.key, e.value),
          ]);

  @override
  Stream<List<StayChannelBlocks>> watchChannelBlocks(String facilityId) => _watch(() =>
      [for (final e in _entries(facilityId, StaysCollections.channelBlocks)) StayChannelBlocks.fromMap(e.key, e.value)]);

  List<StayTask> _tasks(String facilityId) =>
      [for (final e in _entries(facilityId, StaysCollections.tasks)) StayTask.fromMap(e.key, e.value)]
        ..sort((a, b) => a.dueDate.compareTo(b.dueDate));

  @override
  Stream<List<StayTask>> watchTasksInRange(String facilityId, LocalDate from, LocalDate to) => _watch(() => [
        for (final t in _tasks(facilityId))
          if (t.dueDate.compareTo(from.toYmd()) >= 0 && t.dueDate.compareTo(to.toYmd()) < 0) t,
      ]);

  @override
  Stream<List<StayTask>> watchMyTasks(String facilityId, String uid, LocalDate from) => _watch(() => [
        for (final t in _tasks(facilityId))
          if (t.assigneeUid == uid && t.isOpen && t.dueDate.compareTo(from.toYmd()) >= 0) t,
      ]);

  @override
  Stream<StayTask?> watchTask(String facilityId, String taskId) => _watch(() {
        final d = read(facilityId, StaysCollections.tasks, taskId);
        return d == null ? null : StayTask.fromMap(taskId, d);
      });

  @override
  Future<StayTask?> getTask(String facilityId, String taskId) async {
    final d = read(facilityId, StaysCollections.tasks, taskId);
    return d == null ? null : StayTask.fromMap(taskId, d);
  }

  @override
  Stream<List<StayIncomeEntry>> watchIncomeByMonth(String facilityId, String month) => _watch(() => [
        for (final e in _entries(facilityId, StaysCollections.income))
          if (e.value['receivedMonth'] == month) StayIncomeEntry.fromMap(e.key, e.value),
      ]);

  @override
  Stream<List<StayIncomeEntry>> watchIncomeForStay(String facilityId, String stayId) => _watch(() => [
        for (final e in _entries(facilityId, StaysCollections.income))
          if (e.value['stayId'] == stayId) StayIncomeEntry.fromMap(e.key, e.value),
      ]);

  @override
  Stream<StayFolio?> watchFolio(String facilityId, String stayId) => _watch(() {
        final d = read(facilityId, StaysCollections.folios, stayId);
        return d == null ? null : StayFolio.fromMap(stayId, d);
      });

  @override
  Future<StayPrivate?> getStayPrivate(String facilityId, String stayId) async {
    final d = read(facilityId, StaysCollections.private, stayId);
    return d == null ? null : StayPrivate.fromMap(stayId, d);
  }

  @override
  Future<StayAccess?> getStayAccess(String facilityId, String stayId) async {
    final d = read(facilityId, StaysCollections.access, stayId);
    return d == null ? null : StayAccess.fromMap(stayId, d);
  }

  @override
  Future<StayListingAccess> getListingAccess(String facilityId, String listingId) async {
    final d = read(facilityId, StaysCollections.listingAccess, listingId);
    return d == null
        ? StayListingAccess.empty(facilityId, listingId)
        : StayListingAccess.fromMap(d, facilityId: facilityId, listingId: listingId);
  }

  @override
  Stream<List<StayMessageTemplate>> watchTemplates(String facilityId) => _watch(() => [
        for (final e in _entries(facilityId, StaysCollections.messageTemplates)) StayMessageTemplate.fromMap(e.key, e.value),
      ]);

  @override
  Stream<List<StayGuestProfile>> watchGuests(String facilityId) => _watch(() => [
        for (final e in _entries(facilityId, StaysCollections.guestProfiles)) StayGuestProfile.fromMap(e.key, e.value),
      ]);

  @override
  Stream<List<StayChannel>> watchChannels(String facilityId) =>
      _watch(() => [for (final e in _entries(facilityId, StaysCollections.channels)) StayChannel.fromMap(e.key, e.value)]);

  @override
  Stream<List<StayExportLink>> watchExportLinks(String facilityId) => _watch(
      () => [for (final e in _entries(facilityId, StaysCollections.exportLinks)) StayExportLink.fromMap(e.key, e.value)]);

  @override
  Stream<List<StaySyncLogEntry>> watchSyncLog(String facilityId, String channelId) => _watch(() => [
        for (final e in _entries(facilityId, StaysCollections.syncLog))
          if (e.value['channelId'] == channelId) StaySyncLogEntry.fromMap(e.key, e.value),
      ]);

  // --- Writes (the same keys the rules allow) ----------------------------------------

  @override
  Future<void> updateStayQuickFields(String facilityId, String stayId, Map<String, dynamic> changes) async {
    final bad = changes.keys.where((k) => !stayQuickEditKeys.contains(k)).toList();
    if (bad.isNotEmpty) throw ArgumentError('Not a quick-edit field: ${bad.join(', ')}');
    _write('update', facilityId, StaysCollections.stays, stayId, {...changes, ..._stamp()});
  }

  @override
  Future<void> checkIn(String facilityId, String stayId) async => _write('update', facilityId, StaysCollections.stays, stayId, {
        'arrivalState': StayArrivalState.checkedIn.wire,
        'checkedInAt': _serverTime,
        ..._stamp(),
      });

  @override
  Future<void> checkOut(String facilityId, String stayId) async => _write('update', facilityId, StaysCollections.stays, stayId, {
        'arrivalState': StayArrivalState.checkedOut.wire,
        'checkedOutAt': _serverTime,
        ..._stamp(),
      });

  @override
  Future<void> undoCheckIn(String facilityId, String stayId) async => _write('update', facilityId, StaysCollections.stays, stayId, {
        'arrivalState': StayArrivalState.upcoming.wire,
        'checkedInAt': null,
        ..._stamp(),
      });

  @override
  Future<void> undoCheckOut(String facilityId, String stayId) async => _write('update', facilityId, StaysCollections.stays, stayId, {
        'arrivalState': StayArrivalState.checkedIn.wire,
        'checkedOutAt': null,
        ..._stamp(),
      });

  @override
  Future<void> markMessage(String facilityId, String stayId, String templateKey) async =>
      _write('update', facilityId, StaysCollections.stays, stayId, {'messageMarks.$templateKey': _serverTime, ..._stamp()});

  @override
  Future<void> updateTask(String facilityId, String taskId, Map<String, dynamic> changes) async {
    final bad = changes.keys.where((k) => !stayTaskManagerKeys.contains(k)).toList();
    if (bad.isNotEmpty) throw ArgumentError('Not a task field: ${bad.join(', ')}');
    _write('update', facilityId, StaysCollections.tasks, taskId, {...changes, ..._stamp()});
  }

  @override
  Future<void> startTask(String facilityId, String taskId) async => _write('update', facilityId, StaysCollections.tasks, taskId, {
        'status': StayTaskStatus.inProgress.wire,
        'startedAt': _serverTime,
        ..._stamp(),
      });

  @override
  Future<void> completeTask(String facilityId, String taskId) async => _write('update', facilityId, StaysCollections.tasks, taskId, {
        'status': StayTaskStatus.done.wire,
        'completedAt': _serverTime,
        'completedBy': uid,
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
    final id = 'task_${++_autoId}';
    _write('set', facilityId, StaysCollections.tasks, id, {
      'facilityId': facilityId,
      'category': category.wire,
      'listingId': listingId,
      'title': title,
      'notes': notes,
      'dueDate': dueDate.toYmd(),
      'status': StayTaskStatus.todo.wire,
      'createdBy': uid,
      'createdAt': _serverTime,
      ..._stamp(),
    });
    return id;
  }

  @override
  Future<void> saveListingAccess(StayListingAccess access) async =>
      _write('set', access.facilityId, StaysCollections.listingAccess, access.listingId, {
        'facilityId': access.facilityId,
        'listingId': access.listingId,
        ...access.toEditableMap(),
        ..._stamp(),
      });

  @override
  Future<void> saveStayAccess(String facilityId, String stayId, {String? doorCode, String? gateCode, String accessNotes = ''}) async =>
      _write('set', facilityId, StaysCollections.access, stayId, {
        'facilityId': facilityId,
        'stayId': stayId,
        'doorCode': doorCode,
        'gateCode': gateCode,
        'accessNotes': accessNotes,
        'source': StayAccessSource.manual.wire,
        ..._stamp(),
      });

  @override
  Future<void> deleteStayAccess(String facilityId, String stayId) async =>
      _write('delete', facilityId, StaysCollections.access, stayId, const {});

  @override
  Future<void> updateStayPrivate(String facilityId, String stayId, {String? fullName, String? privateNotes}) async {
    final changes = <String, dynamic>{
      if (fullName != null) 'fullName': fullName,
      if (privateNotes != null) 'privateNotes': privateNotes,
    };
    if (changes.isEmpty) return;
    _write('update', facilityId, StaysCollections.private, stayId, {...changes, ..._stamp()});
  }

  Map<String, dynamic> _profile(StayGuestProfileDraft draft) => {
        'name': draft.name.trim(),
        'nameLower': draft.name.trim().toLowerCase(),
        'phoneE164': draft.phoneE164,
        'email': draft.email,
        'vehicle': draft.vehicle?.toMap(),
        'notes': draft.notes,
        'doNotRent': draft.doNotRent,
        'doNotRentReason': draft.doNotRent ? draft.doNotRentReason : null,
      };

  @override
  Future<String> createGuestProfile(String facilityId, StayGuestProfileDraft draft) async {
    final id = 'gp_${++_autoId}';
    _write('set', facilityId, StaysCollections.guestProfiles, id, {
      'facilityId': facilityId,
      ..._profile(draft),
      'consent': draft.hasConsent ? _consent(draft) : null,
      'stayCount': 0,
      'lastStayAt': null,
      'createdBy': uid,
      'createdAt': _serverTime,
      ..._stamp(),
    });
    return id;
  }

  /// Consent as the real repository writes it: stamped with the server time and the user.
  Map<String, dynamic> _consent(StayGuestProfileDraft draft) => {
        'email': draft.consentEmail,
        'sms': draft.consentSms,
        'method': draft.consentMethod!.wire,
        'recordedAt': _serverTime,
        'recordedBy': uid,
      };

  @override
  Future<void> updateGuestProfile(String facilityId, String profileId, StayGuestProfileDraft draft) async {
    final stored = read(facilityId, StaysCollections.guestProfiles, profileId);
    final storedConsent = stored == null ? null : StayGuestProfile.fromMap(profileId, stored).consent;
    _write('update', facilityId, StaysCollections.guestProfiles, profileId, {
      ..._profile(draft),
      if (draft.changesConsent(storedConsent)) 'consent': _consent(draft),
      ..._stamp(),
    });
  }

  @override
  Future<void> deleteGuestProfile(String facilityId, String profileId) async =>
      _write('delete', facilityId, StaysCollections.guestProfiles, profileId, const {});

  @override
  Future<String> saveTemplate(String facilityId, StayMessageTemplateDraft draft, {String? templateId}) async {
    final id = templateId ?? 'tpl_${++_autoId}';
    _write(templateId == null ? 'set' : 'update', facilityId, StaysCollections.messageTemplates, id, {
      'facilityId': facilityId,
      'key': draft.key,
      'name': draft.name,
      'body': draft.body,
      'channelHint': draft.channelHint.wire,
      'listingIds': draft.listingIds,
      'kind': 'copy',
      ..._stamp(),
    });
    return id;
  }

  @override
  Future<void> deleteTemplate(String facilityId, String templateId) async =>
      _write('delete', facilityId, StaysCollections.messageTemplates, templateId, const {});
}

/// Stands in for FieldValue.serverTimestamp(); resolved to "now" on write.
class _ServerTime {
  const _ServerTime();
}
