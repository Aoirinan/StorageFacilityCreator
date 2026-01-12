import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/foundation.dart';

/// Configure Firebase services to use emulators in development mode
/// 
/// Call this BEFORE Firebase.initializeApp() in main.dart
/// 
/// Usage:
/// ```dart
/// if (kDebugMode && useEmulators) {
///   await configureFirebaseEmulators();
/// }
/// await Firebase.initializeApp(...);
/// ```
Future<void> configureFirebaseEmulators({
  String? host,
  int? firestorePort,
  int? authPort,
  int? storagePort,
  int? functionsPort,
}) async {
  const defaultHost = 'localhost';
  const defaultFirestorePort = 8080;
  const defaultAuthPort = 9099;
  const defaultStoragePort = 9199;
  const defaultFunctionsPort = 5001;

  final firestoreHost = host ?? defaultHost;
  final authHost = host ?? defaultHost;
  final storageHost = host ?? defaultHost;
  final functionsHost = host ?? defaultHost;

  final firestorePortNum = firestorePort ?? defaultFirestorePort;
  final authPortNum = authPort ?? defaultAuthPort;
  final storagePortNum = storagePort ?? defaultStoragePort;
  final functionsPortNum = functionsPort ?? defaultFunctionsPort;

  if (kDebugMode) {
    print('🔧 Configuring Firebase Emulators:');
    print('   Firestore: $firestoreHost:$firestorePortNum');
    print('   Auth: $authHost:$authPortNum');
    print('   Storage: $storageHost:$storagePortNum');
    print('   Functions: $functionsHost:$functionsPortNum');
  }

  // Configure Firestore emulator
  FirebaseFirestore.instance.useFirestoreEmulator(
    firestoreHost,
    firestorePortNum,
    sslEnabled: false,
  );

  // Configure Auth emulator
  await FirebaseAuth.instance.useAuthEmulator(
    authHost,
    authPortNum,
  );

  // Configure Storage emulator
  FirebaseStorage.instance.useStorageEmulator(
    storageHost,
    storagePortNum,
  );

  // Configure Functions emulator
  FirebaseFunctions.instance.useFunctionsEmulator(
    functionsHost,
    functionsPortNum,
  );

  if (kDebugMode) {
    print('✅ Firebase Emulators configured successfully');
  }
}

