import 'package:firebase_auth/firebase_auth.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'permission_service.dart';

class AuthService {
  final FirebaseAuth _auth = FirebaseAuth.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  // Get current user
  User? get currentUser => _auth.currentUser;

  // Auth state stream
  Stream<User?> get authStateChanges => _auth.authStateChanges();

  // Sign in with email and password
  Future<UserCredential?> signInWithEmailAndPassword({
    required String email,
    required String password,
  }) async {
    try {
      final credential = await _auth.signInWithEmailAndPassword(
        email: email,
        password: password,
      );
      if (kDebugMode) {
        print('✅ User signed in: ${credential.user?.email}');
      }
      
      // Update last login timestamp
      await updateLastLogin();
      
      return credential;
    } on FirebaseAuthException catch (e) {
      if (kDebugMode) {
        print('❌ Sign in error: ${e.message}');
      }
      rethrow;
    }
  }

  // Create user with email and password (requires email verification)
  Future<UserCredential?> createUserWithEmailAndPassword({
    required String email,
    required String password,
    required bool tosAccepted,
  }) async {
    try {
      final credential = await _auth.createUserWithEmailAndPassword(
        email: email,
        password: password,
      );

      if (credential.user != null) {
        // Send email verification before completing signup
        await credential.user!.sendEmailVerification();
        
        if (kDebugMode) {
          print('✅ Verification email sent to: ${credential.user?.email}');
        }
        
        // Don't create user document until email is verified
        // This prevents fake accounts from being created
        // The user document will be created when they verify their email
        
        if (kDebugMode) {
          print('⏳ Waiting for email verification before completing signup');
        }
      }
      
      return credential;
    } on FirebaseAuthException catch (e) {
      if (kDebugMode) {
        print('❌ Sign up error: ${e.message}');
      }
      rethrow;
    }
  }

  // Complete signup after email verification
  Future<void> completeSignupAfterVerification({
    required String email,
    required bool tosAccepted,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) {
        throw Exception('User not authenticated');
      }

      if (!user.emailVerified) {
        throw Exception('Email not verified');
      }

      // Now create the user document since email is verified
      await _createUserDocument(
        uid: user.uid,
        email: email,
        tosAccepted: tosAccepted,
      );
      
      if (kDebugMode) {
        print('✅ User signup completed after email verification: ${user.email}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error completing signup: $e');
      }
      rethrow;
    }
  }

  // Check if user's email is verified
  Future<bool> isEmailVerified() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    
    // Reload user to get latest verification status
    await user.reload();
    return user.emailVerified;
  }

  // Resend verification email
  Future<void> resendVerificationEmail() async {
    final user = _auth.currentUser;
    if (user == null) {
      throw Exception('User not authenticated');
    }
    
    if (user.emailVerified) {
      throw Exception('Email already verified');
    }
    
    await user.sendEmailVerification();
    
    if (kDebugMode) {
      print('✅ Verification email resent to: ${user.email}');
    }
  }

  // Create user document in Firestore
  Future<void> _createUserDocument({
    required String uid,
    required String email,
    required bool tosAccepted,
  }) async {
    try {
      if (kDebugMode) {
        print('🔄 Attempting to create user document for $email (UID: $uid)');
      }
      
      // Use merge: true to avoid overwriting existing data
      final normalizedEmail = email.toLowerCase();

      await _firestore.collection('users').doc(uid).set({
        'email': email,
        'emailLower': normalizedEmail,
        'tosAccepted': tosAccepted,
        'tosAcceptedAt': tosAccepted ? FieldValue.serverTimestamp() : null,
        'createdAt': FieldValue.serverTimestamp(),
        'lastLoginAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      await PermissionService.fulfillPendingInvitesForUser(
        userId: uid,
        emailLower: normalizedEmail,
        email: email,
        displayName: _auth.currentUser?.displayName,
      );
      
      if (kDebugMode) {
        print('✅ User document created successfully for $email');
        print('📄 Document path: users/$uid');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating user document: $e');
        print('🔍 Error type: ${e.runtimeType}');
        if (e.toString().contains('permission-denied')) {
          print('🚨 PERMISSION DENIED: Check Firestore security rules');
        }
      }
      rethrow;
    }
  }

  // Send password reset email
  Future<void> sendPasswordResetEmail({required String email}) async {
    try {
      await _auth.sendPasswordResetEmail(email: email);
      if (kDebugMode) {
        print('✅ Password reset email sent to $email');
      }
    } on FirebaseAuthException catch (e) {
      if (kDebugMode) {
        print('❌ Password reset error: ${e.message}');
      }
      rethrow;
    }
  }

  // Sign out
  Future<void> signOut() async {
    try {
      await _auth.signOut();
      if (kDebugMode) {
        print('✅ User signed out');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Sign out error: $e');
      }
      rethrow;
    }
  }

  // Update last login timestamp
  Future<void> updateLastLogin() async {
    if (currentUser != null) {
      try {
        await _firestore.collection('users').doc(currentUser!.uid).update({
          'lastLoginAt': FieldValue.serverTimestamp(),
        });
      } catch (e) {
        if (kDebugMode) {
          print('❌ Error updating last login: $e');
        }
      }
    }
  }

  // Get user document from Firestore
  Future<DocumentSnapshot?> getUserDocument(String uid) async {
    try {
      return await _firestore.collection('users').doc(uid).get();
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting user document: $e');
      }
      return null;
    }
  }
}
