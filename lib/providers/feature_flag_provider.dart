import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/models/feature_flag_model.dart';

/// Streams the `appConfig/featureFlags` document and returns a list of [FeatureFlagModel].
/// Falls back to [kDefaultFeatureFlags] when the document doesn't exist yet.
final featureFlagsProvider = StreamProvider<List<FeatureFlagModel>>((ref) {
  return FirebaseFirestore.instance
      .collection('appConfig')
      .doc('featureFlags')
      .snapshots()
      .map((snap) {
    if (!snap.exists || snap.data() == null) {
      return kDefaultFeatureFlags;
    }
    final data = snap.data()!;
    return kDefaultFeatureFlags.map((defaultFlag) {
      final stored = data[defaultFlag.key];
      if (stored is Map<String, dynamic>) {
        return FeatureFlagModel.fromMap(defaultFlag.key, {
          'label': defaultFlag.label,
          'description': defaultFlag.description,
          'riskLevel': _riskToString(defaultFlag.riskLevel),
          ...stored,
        });
      }
      return defaultFlag;
    }).toList();
  });
});

String _riskToString(FlagRiskLevel r) {
  switch (r) {
    case FlagRiskLevel.high:
      return 'high';
    case FlagRiskLevel.medium:
      return 'medium';
    case FlagRiskLevel.low:
      return 'low';
  }
}

/// Convenience provider: returns whether a specific flag is enabled.
/// Defaults to `true` (fail-open) when flags haven't loaded yet.
final featureFlagEnabledProvider =
    Provider.family<bool, String>((ref, flagKey) {
  final flags = ref.watch(featureFlagsProvider);
  return flags.when(
    data: (list) {
      final flag = list.where((f) => f.key == flagKey).firstOrNull;
      return flag?.enabled ?? true;
    },
    loading: () => true,
    error: (_, __) => true,
  );
});

/// Whether the app is in maintenance mode (blocks all non-superadmin access).
final maintenanceModeProvider = Provider<bool>((ref) {
  return ref.watch(featureFlagEnabledProvider('maintenanceMode'));
});

/// Service for writing feature flag updates to Firestore.
class FeatureFlagService {
  static final _doc = FirebaseFirestore.instance.collection('appConfig').doc('featureFlags');

  /// Toggle a single flag. [updatedByEmail] is stored for audit purposes.
  static Future<void> setFlag({
    required String key,
    required bool enabled,
    required String updatedByEmail,
  }) async {
    await _doc.set(
      {
        key: {
          'enabled': enabled,
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedBy': updatedByEmail,
        }
      },
      SetOptions(merge: true),
    );
  }

  /// Seeds the Firestore document with all default flags (only writes missing keys).
  static Future<void> seedDefaults() async {
    final snap = await _doc.get();
    final existing = snap.data() ?? {};
    final toWrite = <String, dynamic>{};
    for (final flag in kDefaultFeatureFlags) {
      if (!existing.containsKey(flag.key)) {
        toWrite[flag.key] = {
          'enabled': flag.enabled,
          'updatedAt': FieldValue.serverTimestamp(),
          'updatedBy': 'system',
        };
      }
    }
    if (toWrite.isNotEmpty) {
      await _doc.set(toWrite, SetOptions(merge: true));
    }
  }
}
