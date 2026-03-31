import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/team_note_model.dart';
import 'audit_service.dart';

/// Shared facility notes visible to all facility staff (see Firestore rules).
class TeamNotesService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  static const int maxBodyLength = 8000;

  static Stream<List<TeamNoteModel>> watchNotes(String facilityId) {
    if (facilityId.isEmpty || facilityId == 'all') {
      return Stream.value([]);
    }
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('team_notes')
        .orderBy('updatedAt', descending: true)
        .limit(100)
        .snapshots()
        .map((snap) => snap.docs.map(TeamNoteModel.fromFirestore).toList());
  }

  static Future<void> addNote({
    required String facilityId,
    required String body,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not signed in');
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
    if (trimmed.length > maxBodyLength) {
      throw Exception('Note is too long (max $maxBodyLength characters).');
    }
    final now = DateTime.now();
    await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('team_notes')
        .add({
      'body': trimmed,
      'createdAt': Timestamp.fromDate(now),
      'updatedAt': Timestamp.fromDate(now),
      'createdByUid': user.uid,
      'createdByDisplayName': user.displayName,
      'updatedByUid': user.uid,
    });
    if (kDebugMode) {
      print('✅ Team note added for facility $facilityId');
    }
  }

  static Future<void> updateNote({
    required String facilityId,
    required String noteId,
    required String body,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not signed in');
    final trimmed = body.trim();
    if (trimmed.isEmpty) return;
    if (trimmed.length > maxBodyLength) {
      throw Exception('Note is too long (max $maxBodyLength characters).');
    }
    final now = DateTime.now();
    await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('team_notes')
        .doc(noteId)
        .update({
      'body': trimmed,
      'updatedAt': Timestamp.fromDate(now),
      'updatedByUid': user.uid,
    });
  }

  static Future<void> deleteNote({
    required String facilityId,
    required String noteId,
  }) async {
    final ref = _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('team_notes')
        .doc(noteId);
    final snap = await ref.get();
    final before =
        snap.exists && snap.data() != null ? Map<String, dynamic>.from(snap.data()!) : null;

    await ref.delete();

    await AuditService.logEvent(
      facilityId: facilityId,
      eventType: 'team_note.deleted',
      targetType: 'team_note',
      targetId: noteId,
      before: before,
      metadata: {
        if (before != null && before['body'] != null)
          'bodyPreview': before['body'].toString().length > 200
              ? '${before['body'].toString().substring(0, 200)}…'
              : before['body'].toString(),
      },
    );
  }
}
