import 'package:cloud_firestore/cloud_firestore.dart';

class TeamNoteModel {
  final String id;
  final String body;
  final DateTime createdAt;
  final DateTime updatedAt;
  final String createdByUid;
  final String? createdByDisplayName;
  final String? updatedByUid;

  TeamNoteModel({
    required this.id,
    required this.body,
    required this.createdAt,
    required this.updatedAt,
    required this.createdByUid,
    this.createdByDisplayName,
    this.updatedByUid,
  });

  factory TeamNoteModel.fromFirestore(DocumentSnapshot<Map<String, dynamic>> doc) {
    final data = doc.data();
    if (data == null) {
      return TeamNoteModel(
        id: doc.id,
        body: '',
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        createdByUid: '',
      );
    }
    return TeamNoteModel(
      id: doc.id,
      body: data['body'] as String? ?? '',
      createdAt: (data['createdAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      updatedAt: (data['updatedAt'] as Timestamp?)?.toDate() ?? DateTime.now(),
      createdByUid: data['createdByUid'] as String? ?? '',
      createdByDisplayName: data['createdByDisplayName'] as String?,
      updatedByUid: data['updatedByUid'] as String?,
    );
  }

  Map<String, dynamic> toFirestore() {
    return {
      'body': body,
      'createdAt': Timestamp.fromDate(createdAt),
      'updatedAt': Timestamp.fromDate(updatedAt),
      'createdByUid': createdByUid,
      if (createdByDisplayName != null) 'createdByDisplayName': createdByDisplayName,
      if (updatedByUid != null) 'updatedByUid': updatedByUid,
    };
  }
}
