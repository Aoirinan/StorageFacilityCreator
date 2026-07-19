import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import 'facility_creator_account_service.dart';
import 'superadmin_service.dart';

/// One-time Do Not Rent terms acceptance ("DNR participation").
///
/// Firestore rules gate all shared DNR reads/creates on a `dnr_participants/{uid}`
/// doc that can only be written while the user holds an active paid subscription.
/// This service checks/records that acceptance and shows the acceptance dialog.
class DnrTermsService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  static const String termsVersion = '1.0';
  static const String _collection = 'dnr_participants';

  /// Summary shown in the acceptance dialog. Keep aligned with the published
  /// Do Not Rent Data Policy (marketing site /dnr-policy) and ToS section 9.
  static const String termsSummary =
      'The Do Not Rent (DNR) list is shared between participating Storage Facility Creator '
      'operators. By participating you agree that:\n\n'
      '• Entries you submit must be factual, based on your facility\'s direct business '
      'experience, and supported by your internal records.\n'
      '• Entries must not be based on race, color, religion, national origin, sex, familial '
      'status, disability, age, or any other protected characteristic, and must not be used '
      'for harassment or retaliation.\n'
      '• You are solely responsible for your entries and must promptly correct or deactivate '
      'any entry you learn is inaccurate or unsupported.\n'
      '• Entries from other facilities are provided "as is" and are not verified by Storage '
      'Facility Creator. This list is not a consumer report and may not be used as one, nor '
      'as the sole basis for a rental decision where the law requires more.\n'
      '• Storage Facility Creator is a technology provider only. It does not create, verify, '
      'endorse, or adopt entries and, to the maximum extent permitted by law, is not liable '
      'for any claims, damages, or losses arising from entries submitted by operators. You '
      'agree to defend, indemnify, and hold harmless Storage Facility Creator from any claim '
      'arising from entries you or your staff submit, as set out in the Terms of Service.\n'
      '• Storage Facility Creator may deactivate or remove any entry at any time, at its '
      'sole discretion, without notice.\n'
      '• Disputed entries follow the dispute and correction process in the Do Not Rent Data '
      'Policy, and entries that cannot be substantiated will be removed.';

  /// Whether the current user has recorded DNR terms acceptance.
  /// Superadmins bypass (rules also bypass for them).
  static Future<bool> hasAccepted() async {
    final user = _auth.currentUser;
    if (user == null) return false;
    if (SuperAdminService.isSuperAdmin()) return true;

    try {
      final doc = await _firestore.collection(_collection).doc(user.uid).get();
      return doc.exists && (doc.data()?['accepted'] == true);
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [DnrTerms] Error checking acceptance: $e');
      }
      return false;
    }
  }

  /// Record acceptance. Requires an active paid subscription (enforced by
  /// Firestore rules; this will throw permission-denied otherwise).
  static Future<void> recordAcceptance() async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not signed in');

    final account =
        await FacilityCreatorAccountService.getAccountByOwnerUid(user.uid);
    if (account == null) {
      throw Exception(
          'No subscription account found. DNR participation requires an active subscription.');
    }

    await _firestore.collection(_collection).doc(user.uid).set({
      'accepted': true,
      'termsVersion': termsVersion,
      'acceptedAt': FieldValue.serverTimestamp(),
      'acceptedByEmail': user.email,
      'accountId': account.accountId,
    });

    if (kDebugMode) {
      print('✅ [DnrTerms] Acceptance recorded for ${user.uid}');
    }
  }

  /// Ensure the user has accepted the DNR terms, prompting with a dialog if
  /// needed. Returns true when accepted (now or previously).
  static Future<bool> ensureAccepted(BuildContext context) async {
    if (await hasAccepted()) return true;
    if (!context.mounted) return false;

    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Do Not Rent Terms'),
        content: const SingleChildScrollView(
          child: Text(termsSummary, style: TextStyle(fontSize: 14)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Not Now'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: AppTheme.textOnDark,
            ),
            child: const Text('I Agree'),
          ),
        ],
      ),
    );

    if (accepted != true) return false;

    try {
      await recordAcceptance();
      return true;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [DnrTerms] Failed to record acceptance: $e');
      }
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not record DNR terms acceptance: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
      return false;
    }
  }
}
