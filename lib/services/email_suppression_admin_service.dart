import 'package:cloud_functions/cloud_functions.dart';

/// Facility staff: manage [emailSuppressions] (List-Unsubscribe opt-outs) via Cloud Functions.
class EmailSuppressionAdminService {
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  static Future<List<FacilityEmailOptOutRow>> listSuppressions(String facilityId) async {
    final callable = _functions.httpsCallable('listFacilityEmailSuppressions');
    final result = await callable.call({'facilityId': facilityId});
    final map = Map<String, dynamic>.from(result.data as Map);
    final raw = map['suppressions'];
    if (raw is! List) return [];
    return raw
        .map((e) => FacilityEmailOptOutRow.fromMap(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Removes suppression so facility email can be sent again. [sendConfirmation] triggers a compliance email after removal.
  static Future<RemoveEmailSuppressionResult> removeSuppression({
    required String facilityId,
    required String suppressId,
    bool sendConfirmation = true,
  }) async {
    final callable = _functions.httpsCallable('removeFacilityEmailSuppression');
    final result = await callable.call({
      'facilityId': facilityId,
      'suppressId': suppressId,
      'sendConfirmation': sendConfirmation,
    });
    final map = Map<String, dynamic>.from(result.data as Map);
    return RemoveEmailSuppressionResult(
      ok: map['ok'] == true,
      confirmationSent: map['confirmationSent'] == true,
    );
  }
}

class FacilityEmailOptOutRow {
  final String suppressId;
  final String emailLower;
  final String? tenantId;
  final DateTime? unsubscribedAt;
  final String? source;

  FacilityEmailOptOutRow({
    required this.suppressId,
    required this.emailLower,
    this.tenantId,
    this.unsubscribedAt,
    this.source,
  });

  factory FacilityEmailOptOutRow.fromMap(Map<String, dynamic> m) {
    DateTime? at;
    final iso = m['unsubscribedAt'];
    if (iso is String && iso.isNotEmpty) {
      at = DateTime.tryParse(iso);
    }
    return FacilityEmailOptOutRow(
      suppressId: m['suppressId'] as String? ?? '',
      emailLower: m['emailLower'] as String? ?? '',
      tenantId: m['tenantId'] as String?,
      unsubscribedAt: at,
      source: m['source'] as String?,
    );
  }
}

class RemoveEmailSuppressionResult {
  final bool ok;
  final bool confirmationSent;

  RemoveEmailSuppressionResult({
    required this.ok,
    required this.confirmationSent,
  });
}
