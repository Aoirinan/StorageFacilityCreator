import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

class FirestoreRulesTester {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  static Future<void> testUserDocumentCreation() async {
    if (kDebugMode) {
      print('🧪 Testing Firestore Rules for User Document Creation');
      print('================================================');
    }

    try {
      // Test 1: Check if user is authenticated
      final user = _auth.currentUser;
      if (user == null) {
        if (kDebugMode) {
          print('❌ No authenticated user found');
        }
        return;
      }

      if (kDebugMode) {
        print('✅ User authenticated: ${user.email} (UID: ${user.uid})');
      }

      // Test 2: Try to create a test user document
      if (kDebugMode) {
        print('🔄 Testing user document creation...');
      }

      await _firestore.collection('users').doc(user.uid).set({
        'email': user.email,
        'tosAccepted': true,
        'tosAcceptedAt': FieldValue.serverTimestamp(),
        'createdAt': FieldValue.serverTimestamp(),
        'lastLoginAt': FieldValue.serverTimestamp(),
        'testDocument': true,
      });

      if (kDebugMode) {
        print('✅ User document created successfully!');
      }

      // Test 3: Try to read the user document
      if (kDebugMode) {
        print('🔄 Testing user document read...');
      }

      final doc = await _firestore.collection('users').doc(user.uid).get();
      if (doc.exists) {
        if (kDebugMode) {
          print('✅ User document read successfully!');
          print('📄 Document data: ${doc.data()}');
        }
      }

      // Test 4: Try to create a test facility
      if (kDebugMode) {
        print('🔄 Testing facility document creation...');
      }

      final facilityId = 'test-facility-${DateTime.now().millisecondsSinceEpoch}';
      await _firestore.collection('facilities').doc(facilityId).set({
        'name': 'Test Facility',
        'ownerUid': user.uid,
        'createdAt': FieldValue.serverTimestamp(),
        'active': true,
        'testDocument': true,
      });

      if (kDebugMode) {
        print('✅ Facility document created successfully!');
      }

      // Test 5: Try to create a test tenant
      if (kDebugMode) {
        print('🔄 Testing tenant document creation...');
      }

      final tenantId = 'test-tenant-${DateTime.now().millisecondsSinceEpoch}';
      await _firestore.collection('facilities').doc(facilityId).collection('tenants').doc(tenantId).set({
        'facilityId': facilityId,
        'name': 'Test Tenant',
        'email': 'test@example.com',
        'phone': '555-0123',
        'unitNumber': '101',
        'monthlyRate': 100.0,
        'createdAt': FieldValue.serverTimestamp(),
        'isActive': true,
        'testDocument': true,
      });

      if (kDebugMode) {
        print('✅ Tenant document created successfully!');
      }

      // Test 6: Clean up test documents
      if (kDebugMode) {
        print('🔄 Cleaning up test documents...');
      }

      await _firestore.collection('facilities').doc(facilityId).delete();
      await _firestore.collection('users').doc(user.uid).update({
        'testDocument': FieldValue.delete(),
      });

      if (kDebugMode) {
        print('✅ Test documents cleaned up!');
        print('🎉 ALL FIRESTORE RULES TESTS PASSED!');
        print('================================================');
      }

    } catch (e) {
      if (kDebugMode) {
        print('❌ Firestore rules test failed: $e');
        print('🔍 Error type: ${e.runtimeType}');
        if (e.toString().contains('permission-denied')) {
          print('🚨 PERMISSION DENIED: Check your Firestore security rules');
        }
        print('================================================');
      }
    }
  }
}
