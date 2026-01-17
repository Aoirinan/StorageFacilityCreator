import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:sfcapp/models/security_model.dart';

class SecurityService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;
  static const String _eventsCollection = 'security_events';
  static const String _alertsCollection = 'security_alerts';
  static const String _rulesCollection = 'security_rules';
  static const String _settingsCollection = 'security_settings';

  // Log a security event (account-scoped)
  static Future<void> logEvent({
    required SecurityEventType type,
    required SecurityLevel level,
    required String description,
    String? facilityId,
    String? tenantId,
    String? contractId,
    String? paymentId,
    String? accountId, // Account ID for scoping
    Map<String, dynamic>? metadata,
    String? ipAddress,
    String? userAgent,
    String? location,
  }) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        if (kDebugMode) {
          print('❌ Cannot log security event: No authenticated user');
        }
        return;
      }

      // Get accountId if not provided (from facilityId or userId)
      String? finalAccountId = accountId;
      if (finalAccountId == null) {
        if (facilityId != null) {
          // Get account from facility
          final facilityDoc = await _firestore.collection('facilities').doc(facilityId).get();
          if (facilityDoc.exists) {
            final facilityData = facilityDoc.data();
            finalAccountId = facilityData?['facilityCreatorAccountId'] as String?;
          }
        }
        if (finalAccountId == null) {
          // Get account from user
          final accountSnapshot = await _firestore
              .collection('facilityCreatorAccounts')
              .where('ownerUid', isEqualTo: currentUser.uid)
              .limit(1)
              .get();
          if (accountSnapshot.docs.isNotEmpty) {
            finalAccountId = accountSnapshot.docs.first.id;
          }
        }
      }

      // If still no accountId, skip logging (shouldn't happen in production)
      if (finalAccountId == null) {
        if (kDebugMode) {
          print('⚠️ Cannot log security event: No account ID found');
        }
        return;
      }

      final event = SecurityEvent(
        id: '', // Firestore will set this
        type: type,
        level: level,
        userId: currentUser.uid,
        facilityId: facilityId,
        tenantId: tenantId,
        contractId: contractId,
        paymentId: paymentId,
        description: description,
        metadata: metadata,
        ipAddress: ipAddress,
        userAgent: userAgent,
        location: location,
        timestamp: DateTime.now(),
      );

      await _firestore
          .collection('facilityCreatorAccounts')
          .doc(finalAccountId)
          .collection(_eventsCollection)
          .add({
        'type': type.name,
        'level': level.name,
        'userId': event.userId,
        'facilityId': event.facilityId,
        'tenantId': event.tenantId,
        'contractId': event.contractId,
        'paymentId': event.paymentId,
        'description': event.description,
        'metadata': event.metadata,
        'ipAddress': event.ipAddress,
        'userAgent': event.userAgent,
        'location': event.location,
        'timestamp': Timestamp.fromDate(event.timestamp),
        'isResolved': event.isResolved,
        'resolvedBy': event.resolvedBy,
        'resolvedAt': event.resolvedAt != null ? Timestamp.fromDate(event.resolvedAt!) : null,
        'resolution': event.resolution,
      });

      if (kDebugMode) {
        print('✅ Security event logged: ${type.displayName} - ${level.displayName}');
      }

      // Check if this event should trigger an alert
      await _checkSecurityRules(event, finalAccountId);
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error logging security event: $e');
      }
    }
  }

  // Get security events with filtering (account-scoped)
  static Future<List<SecurityEvent>> getSecurityEvents({
    required String accountId, // Account ID required for scoping
    SecurityEventType? eventType,
    SecurityLevel? level,
    String? userId,
    String? facilityId,
    DateTime? startDate,
    DateTime? endDate,
    bool? isResolved,
    int limit = 100,
  }) async {
    try {
      Query query = _firestore
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection(_eventsCollection);

      if (eventType != null) {
        query = query.where('type', isEqualTo: eventType.name);
      }
      if (level != null) {
        query = query.where('level', isEqualTo: level.name);
      }
      if (userId != null) {
        query = query.where('userId', isEqualTo: userId);
      }
      if (facilityId != null) {
        query = query.where('facilityId', isEqualTo: facilityId);
      }
      if (startDate != null) {
        query = query.where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(startDate));
      }
      if (endDate != null) {
        query = query.where('timestamp', isLessThanOrEqualTo: Timestamp.fromDate(endDate));
      }
      if (isResolved != null) {
        query = query.where('isResolved', isEqualTo: isResolved);
      }

      query = query.orderBy('timestamp', descending: true).limit(limit);

      final querySnapshot = await query.get();
      return querySnapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        return SecurityEvent(
          id: doc.id,
          type: SecurityEventType.values.firstWhere(
            (e) => e.name == data['type'],
            orElse: () => SecurityEventType.systemError,
          ),
          level: SecurityLevel.values.firstWhere(
            (e) => e.name == data['level'],
            orElse: () => SecurityLevel.low,
          ),
          userId: data['userId'] ?? '',
          facilityId: data['facilityId'],
          tenantId: data['tenantId'],
          contractId: data['contractId'],
          paymentId: data['paymentId'],
          description: data['description'] ?? '',
          metadata: data['metadata'] != null ? Map<String, dynamic>.from(data['metadata']) : null,
          ipAddress: data['ipAddress'],
          userAgent: data['userAgent'],
          location: data['location'],
          timestamp: (data['timestamp'] as Timestamp).toDate(),
          isResolved: data['isResolved'] ?? false,
          resolvedBy: data['resolvedBy'],
          resolvedAt: data['resolvedAt'] != null ? (data['resolvedAt'] as Timestamp).toDate() : null,
          resolution: data['resolution'],
        );
      }).toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting security events: $e');
      }
      return [];
    }
  }

  // Get security alerts (account-scoped)
  static Future<List<SecurityAlert>> getSecurityAlerts({
    required String accountId, // Account ID required for scoping
    SecurityLevel? level,
    bool? isAcknowledged,
    int limit = 50,
  }) async {
    try {
      Query query = _firestore
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection(_alertsCollection);

      if (level != null) {
        query = query.where('level', isEqualTo: level.name);
      }
      if (isAcknowledged != null) {
        query = query.where('isAcknowledged', isEqualTo: isAcknowledged);
      }

      query = query.orderBy('timestamp', descending: true).limit(limit);

      final querySnapshot = await query.get();
      return querySnapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        return SecurityAlert(
          id: doc.id,
          title: data['title'] ?? '',
          description: data['description'] ?? '',
          level: SecurityLevel.values.firstWhere(
            (e) => e.name == data['level'],
            orElse: () => SecurityLevel.medium,
          ),
          eventType: SecurityEventType.values.firstWhere(
            (e) => e.name == data['eventType'],
            orElse: () => SecurityEventType.securityAlert,
          ),
          userId: data['userId'] ?? '',
          facilityId: data['facilityId'],
          metadata: data['metadata'] != null ? Map<String, dynamic>.from(data['metadata']) : null,
          timestamp: (data['timestamp'] as Timestamp).toDate(),
          isAcknowledged: data['isAcknowledged'] ?? false,
          acknowledgedBy: data['acknowledgedBy'],
          acknowledgedAt: data['acknowledgedAt'] != null ? (data['acknowledgedAt'] as Timestamp).toDate() : null,
          acknowledgmentNote: data['acknowledgmentNote'],
        );
      }).toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting security alerts: $e');
      }
      return [];
    }
  }

  // Acknowledge a security alert (account-scoped)
  static Future<bool> acknowledgeAlert({
    required String accountId,
    required String alertId,
    required String acknowledgmentNote,
  }) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        if (kDebugMode) {
          print('❌ Cannot acknowledge alert: No authenticated user');
        }
        return false;
      }

      await _firestore
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection(_alertsCollection)
          .doc(alertId)
          .update({
        'isAcknowledged': true,
        'acknowledgedBy': currentUser.uid,
        'acknowledgedAt': Timestamp.fromDate(DateTime.now()),
        'acknowledgmentNote': acknowledgmentNote,
      });

      if (kDebugMode) {
        print('✅ Security alert acknowledged: $alertId');
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error acknowledging alert: $e');
      }
      return false;
    }
  }

  // Get security settings (account-scoped)
  static Future<SecuritySettings?> getSecuritySettings(String accountId) async {
    try {
      final doc = await _firestore
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection(_settingsCollection)
          .doc('default')
          .get();
      if (!doc.exists) {
        return null;
      }

      final data = doc.data() as Map<String, dynamic>;
      return SecuritySettings(
        id: doc.id,
        enableAuditLogging: data['enableAuditLogging'] ?? true,
        enableRealTimeMonitoring: data['enableRealTimeMonitoring'] ?? true,
        enableSuspiciousActivityDetection: data['enableSuspiciousActivityDetection'] ?? true,
        enableDataEncryption: data['enableDataEncryption'] ?? true,
        enableTwoFactorAuth: data['enableTwoFactorAuth'] ?? false,
        enableSessionTimeout: data['enableSessionTimeout'] ?? true,
        sessionTimeoutMinutes: data['sessionTimeoutMinutes'] ?? 30,
        enableIPWhitelist: data['enableIPWhitelist'] ?? false,
        allowedIPs: List<String>.from(data['allowedIPs'] ?? []),
        enableLocationTracking: data['enableLocationTracking'] ?? false,
        enableDeviceFingerprinting: data['enableDeviceFingerprinting'] ?? false,
        enablePasswordPolicy: data['enablePasswordPolicy'] ?? true,
        passwordMinLength: data['passwordMinLength'] ?? 8,
        requireSpecialCharacters: data['requireSpecialCharacters'] ?? true,
        requireNumbers: data['requireNumbers'] ?? true,
        requireUppercase: data['requireUppercase'] ?? true,
        passwordExpiryDays: data['passwordExpiryDays'] ?? 90,
        enableAccountLockout: data['enableAccountLockout'] ?? true,
        maxLoginAttempts: data['maxLoginAttempts'] ?? 5,
        lockoutDurationMinutes: data['lockoutDurationMinutes'] ?? 30,
        updatedAt: (data['updatedAt'] as Timestamp).toDate(),
        updatedBy: data['updatedBy'] ?? '',
      );
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting security settings: $e');
      }
      return null;
    }
  }

  // Update security settings (account-scoped)
  static Future<bool> updateSecuritySettings({
    required String accountId,
    required SecuritySettings settings,
  }) async {
    try {
      final currentUser = _auth.currentUser;
      if (currentUser == null) {
        if (kDebugMode) {
          print('❌ Cannot update security settings: No authenticated user');
        }
        return false;
      }

      await _firestore
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection(_settingsCollection)
          .doc('default')
          .set({
        'enableAuditLogging': settings.enableAuditLogging,
        'enableRealTimeMonitoring': settings.enableRealTimeMonitoring,
        'enableSuspiciousActivityDetection': settings.enableSuspiciousActivityDetection,
        'enableDataEncryption': settings.enableDataEncryption,
        'enableTwoFactorAuth': settings.enableTwoFactorAuth,
        'enableSessionTimeout': settings.enableSessionTimeout,
        'sessionTimeoutMinutes': settings.sessionTimeoutMinutes,
        'enableIPWhitelist': settings.enableIPWhitelist,
        'allowedIPs': settings.allowedIPs,
        'enableLocationTracking': settings.enableLocationTracking,
        'enableDeviceFingerprinting': settings.enableDeviceFingerprinting,
        'enablePasswordPolicy': settings.enablePasswordPolicy,
        'passwordMinLength': settings.passwordMinLength,
        'requireSpecialCharacters': settings.requireSpecialCharacters,
        'requireNumbers': settings.requireNumbers,
        'requireUppercase': settings.requireUppercase,
        'passwordExpiryDays': settings.passwordExpiryDays,
        'enableAccountLockout': settings.enableAccountLockout,
        'maxLoginAttempts': settings.maxLoginAttempts,
        'lockoutDurationMinutes': settings.lockoutDurationMinutes,
        'updatedAt': Timestamp.fromDate(DateTime.now()),
        'updatedBy': currentUser.uid,
      });

      if (kDebugMode) {
        print('✅ Security settings updated');
      }
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error updating security settings: $e');
      }
      return false;
    }
  }

  // Check security rules and create alerts if needed (account-scoped)
  static Future<void> _checkSecurityRules(SecurityEvent event, String accountId) async {
    try {
      // Get active security rules for this event type (account-scoped)
      final rulesSnapshot = await _firestore
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection(_rulesCollection)
          .where('eventType', isEqualTo: event.type.name)
          .where('isEnabled', isEqualTo: true)
          .get();

      for (final ruleDoc in rulesSnapshot.docs) {
        final ruleData = ruleDoc.data();
        final minimumLevel = SecurityLevel.values.firstWhere(
          (e) => e.name == ruleData['minimumLevel'],
          orElse: () => SecurityLevel.low,
        );

        // Check if event level meets minimum threshold
        if (_compareSecurityLevels(event.level, minimumLevel) >= 0) {
          await _createSecurityAlert(event, ruleData, accountId);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error checking security rules: $e');
      }
    }
  }

  // Create a security alert (account-scoped)
  static Future<void> _createSecurityAlert(SecurityEvent event, Map<String, dynamic> ruleData, String accountId) async {
    try {
      final alert = SecurityAlert(
        id: '', // Firestore will set this
        title: 'Security Alert: ${event.type.displayName}',
        description: event.description,
        level: event.level,
        eventType: event.type,
        userId: event.userId,
        facilityId: event.facilityId,
        metadata: event.metadata,
        timestamp: DateTime.now(),
      );

      await _firestore
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection(_alertsCollection)
          .add({
        'title': alert.title,
        'description': alert.description,
        'level': alert.level.name,
        'eventType': alert.eventType.name,
        'userId': alert.userId,
        'facilityId': alert.facilityId,
        'metadata': alert.metadata,
        'timestamp': Timestamp.fromDate(alert.timestamp),
        'isAcknowledged': alert.isAcknowledged,
        'acknowledgedBy': alert.acknowledgedBy,
        'acknowledgedAt': alert.acknowledgedAt != null ? Timestamp.fromDate(alert.acknowledgedAt!) : null,
        'acknowledgmentNote': alert.acknowledgmentNote,
      });

      if (kDebugMode) {
        print('🚨 Security alert created: ${alert.title}');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error creating security alert: $e');
      }
    }
  }

  // Compare security levels (returns 1 if level1 > level2, 0 if equal, -1 if level1 < level2)
  static int _compareSecurityLevels(SecurityLevel level1, SecurityLevel level2) {
    const levelOrder = [SecurityLevel.low, SecurityLevel.medium, SecurityLevel.high, SecurityLevel.critical];
    final index1 = levelOrder.indexOf(level1);
    final index2 = levelOrder.indexOf(level2);
    return index1.compareTo(index2);
  }

  // Get security statistics (account-scoped)
  static Future<Map<String, int>> getSecurityStatistics({
    required String accountId,
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    try {
      final start = startDate ?? DateTime.now().subtract(const Duration(days: 30));
      final end = endDate ?? DateTime.now();

      final eventsSnapshot = await _firestore
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection(_eventsCollection)
          .where('timestamp', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
          .where('timestamp', isLessThanOrEqualTo: Timestamp.fromDate(end))
          .get();

      final stats = <String, int>{
        'totalEvents': eventsSnapshot.docs.length,
        'criticalEvents': 0,
        'highEvents': 0,
        'mediumEvents': 0,
        'lowEvents': 0,
        'unresolvedAlerts': 0,
      };

      for (final doc in eventsSnapshot.docs) {
        final data = doc.data();
        final level = data['level'] as String;
        
        switch (level) {
          case 'critical':
            stats['criticalEvents'] = (stats['criticalEvents'] ?? 0) + 1;
            break;
          case 'high':
            stats['highEvents'] = (stats['highEvents'] ?? 0) + 1;
            break;
          case 'medium':
            stats['mediumEvents'] = (stats['mediumEvents'] ?? 0) + 1;
            break;
          case 'low':
            stats['lowEvents'] = (stats['lowEvents'] ?? 0) + 1;
            break;
        }
      }

      // Get unresolved alerts count (account-scoped)
      final alertsSnapshot = await _firestore
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection(_alertsCollection)
          .where('isAcknowledged', isEqualTo: false)
          .get();
      
      stats['unresolvedAlerts'] = alertsSnapshot.docs.length;

      return stats;
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error getting security statistics: $e');
      }
      return {};
    }
  }

  // Initialize default security settings (account-scoped)
  static Future<void> initializeDefaultSettings(String accountId) async {
    try {
      final doc = await _firestore
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection(_settingsCollection)
          .doc('default')
          .get();
      if (!doc.exists) {
        final defaultSettings = SecuritySettings(
          id: 'default',
          updatedAt: DateTime.now(),
          updatedBy: 'system',
        );

        await updateSecuritySettings(accountId: accountId, settings: defaultSettings);
        if (kDebugMode) {
          print('✅ Default security settings initialized for account: $accountId');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ Error initializing default security settings: $e');
      }
    }
  }
}
