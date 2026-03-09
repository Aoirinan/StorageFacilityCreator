import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import '../models/work_order_model.dart';

class WorkOrderService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Create a new work order
  static Future<String> createWorkOrder({
    required String facilityId,
    required String title,
    String? description,
    String? unitId,
    String? tenantId,
    String? assignedTo,
    WorkOrderPriority priority = WorkOrderPriority.medium,
    DateTime? dueDate,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final now = DateTime.now();
      final workOrderRef = _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('workOrders')
          .doc();

      final workOrderData = {
        'facilityId': facilityId,
        'title': title,
        if (description != null) 'description': description,
        if (unitId != null) 'unitId': unitId,
        if (tenantId != null) 'tenantId': tenantId,
        if (assignedTo != null) 'assignedTo': assignedTo,
        'status': WorkOrderStatus.open.name,
        'priority': priority.name,
        if (dueDate != null) 'dueDate': Timestamp.fromDate(dueDate),
        'comments': [],
        'createdAt': Timestamp.fromDate(now),
        'updatedAt': Timestamp.fromDate(now),
        'createdBy': user.uid,
      };

      await workOrderRef.set(workOrderData);
      return workOrderRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating work order: $e');
      }
      rethrow;
    }
  }

  /// Update work order status
  static Future<void> updateWorkOrderStatus({
    required String facilityId,
    required String workOrderId,
    required WorkOrderStatus status,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('workOrders')
          .doc(workOrderId)
          .update({
        'status': status.name,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating work order status: $e');
      }
      rethrow;
    }
  }

  /// Add comment to work order
  static Future<void> addComment({
    required String facilityId,
    required String workOrderId,
    required String text,
    required String authorName,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final comment = {
        'text': text,
        'authorUid': user.uid,
        'authorName': authorName,
        'createdAt': FieldValue.serverTimestamp(),
      };

      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('workOrders')
          .doc(workOrderId)
          .update({
        'comments': FieldValue.arrayUnion([comment]),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error adding comment: $e');
      }
      rethrow;
    }
  }

  /// Get all work orders for a facility
  static Stream<List<WorkOrderModel>> getWorkOrdersStream(String facilityId) {
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('workOrders')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => WorkOrderModel.fromFirestore(doc))
            .toList());
  }

  /// Get a single work order
  static Future<WorkOrderModel?> getWorkOrder({
    required String facilityId,
    required String workOrderId,
  }) async {
    try {
      final doc = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('workOrders')
          .doc(workOrderId)
          .get();

      if (!doc.exists) return null;
      return WorkOrderModel.fromFirestore(doc);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting work order: $e');
      }
      return null;
    }
  }
}
