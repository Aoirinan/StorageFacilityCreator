import 'package:cloud_firestore/cloud_firestore.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_fields.dart';

class StayTaskChecklistItem {
  const StayTaskChecklistItem({
    required this.id,
    required this.label,
    this.done = false,
    this.doneAt,
    this.doneBy,
  });

  factory StayTaskChecklistItem.fromMap(Map<String, dynamic> d) => StayTaskChecklistItem(
        id: stayStr(d['id']),
        label: stayStr(d['label']),
        done: stayTrue(d['done']),
        doneAt: stayTime(d['doneAt']),
        doneBy: stayStrOrNull(d['doneBy']),
      );

  final String id;
  final String label;
  final bool done;
  final DateTime? doneAt;
  final String? doneBy;

  /// For the repository's task update; doneAt is a client time (the rules
  /// only stamp the task's own updatedAt).
  Map<String, dynamic> toMap() => {
        'id': id,
        'label': label,
        'done': done,
        'doneAt': doneAt == null ? null : Timestamp.fromDate(doneAt!),
        'doneBy': doneBy,
      };
}

/// facilities/{fid}/stayTasks/{taskId}: a turnover (`turnover_{stayId}`,
/// planned by the staysOnStayWrite trigger) or a manual to-do. Times are
/// shown from the server-written `*Local` strings, never converted in the
/// browser.
class StayTask {
  const StayTask({
    required this.id,
    required this.facilityId,
    this.category = StayTaskCategory.unknown,
    this.listingId,
    this.stayId,
    this.nextStayId,
    this.title = '',
    this.notes = '',
    this.dueStartAt,
    this.dueStartLocal = '',
    this.dueByAt,
    this.dueByLocal,
    this.dueDate = '',
    this.sameDayTurn = false,
    this.priority = StayTaskPriority.normal,
    this.status = StayTaskStatus.unknown,
    this.needsAttention = false,
    this.assigneeUid,
    this.assigneeName,
    this.checklist = const [],
    this.suppliesLow = const [],
    this.issueNote = '',
    this.photoPaths = const [],
    this.startedAt,
    this.completedAt,
    this.completedBy,
    this.updatedAt,
  });

  factory StayTask.fromFirestore(DocumentSnapshot<Object?> doc) => StayTask.fromMap(doc.id, stayDocData(doc));

  factory StayTask.fromMap(String id, Map<String, dynamic> d) => StayTask(
        id: id,
        facilityId: stayStr(d['facilityId']),
        category: StayTaskCategory.fromWire(d['category']),
        listingId: stayStrOrNull(d['listingId']),
        stayId: stayStrOrNull(d['stayId']),
        nextStayId: stayStrOrNull(d['nextStayId']),
        title: stayStr(d['title']),
        notes: stayStr(d['notes']),
        dueStartAt: stayTime(d['dueStartAt']),
        dueStartLocal: stayStr(d['dueStartLocal']),
        dueByAt: stayTime(d['dueByAt']),
        dueByLocal: stayStrOrNull(d['dueByLocal']),
        dueDate: stayStr(d['dueDate']),
        sameDayTurn: stayTrue(d['sameDayTurn']),
        priority: d['priority'] == null ? StayTaskPriority.normal : StayTaskPriority.fromWire(d['priority']),
        status: StayTaskStatus.fromWire(d['status']),
        needsAttention: stayTrue(d['needsAttention']),
        assigneeUid: stayStrOrNull(d['assigneeUid']),
        assigneeName: stayStrOrNull(d['assigneeName']),
        checklist: stayMapList(d['checklist']).map(StayTaskChecklistItem.fromMap).toList(),
        suppliesLow: stayStrList(d['suppliesLow']),
        issueNote: stayStr(d['issueNote']),
        photoPaths: stayStrList(d['photoPaths']),
        startedAt: stayTime(d['startedAt']),
        completedAt: stayTime(d['completedAt']),
        completedBy: stayStrOrNull(d['completedBy']),
        updatedAt: stayTime(d['updatedAt']),
      );

  final String id;
  final String facilityId;
  final StayTaskCategory category;
  final String? listingId;
  final String? stayId;
  final String? nextStayId;
  final String title;
  final String notes;
  final DateTime? dueStartAt;

  /// 'YYYY-MM-DD HH:mm' at the facility, written by the server.
  final String dueStartLocal;
  final DateTime? dueByAt;
  final String? dueByLocal;

  /// 'YYYY-MM-DD'.
  final String dueDate;
  final bool sameDayTurn;
  final StayTaskPriority priority;
  final StayTaskStatus status;
  final bool needsAttention;
  final String? assigneeUid;
  final String? assigneeName;
  final List<StayTaskChecklistItem> checklist;
  final List<String> suppliesLow;
  final String issueNote;
  final List<String> photoPaths;
  final DateTime? startedAt;
  final DateTime? completedAt;
  final String? completedBy;
  final DateTime? updatedAt;

  bool get isTurnover => category == StayTaskCategory.turnover;

  bool get isOpen => status.isOpen;

  bool get hasIssue => issueNote.trim().isNotEmpty;

  /// Checklist progress, 0–1 (1 when there is no checklist and it is done).
  double get progress {
    if (checklist.isEmpty) return status == StayTaskStatus.done ? 1 : 0;
    return checklist.where((i) => i.done).length / checklist.length;
  }
}
