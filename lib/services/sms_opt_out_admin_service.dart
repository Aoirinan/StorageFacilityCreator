import 'package:cloud_functions/cloud_functions.dart';

/// Facility staff: SMS block list + tenant opt-outs (STOP) via Cloud Functions.
class SmsOptOutAdminService {
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  static Future<FacilitySmsOptOutsSnapshot> list(String facilityId) async {
    final callable = _functions.httpsCallable('listFacilitySmsOptOuts');
    final result = await callable.call({'facilityId': facilityId});
    final map = Map<String, dynamic>.from(result.data as Map);

    final blockRaw = map['blockList'];
    final blockList = blockRaw is List ? blockRaw.map((e) => e.toString()).toList() : <String>[];

    final onlyRaw = map['blockListOnly'];
    final blockListOnly = <BlockListOnlyRow>[];
    if (onlyRaw is List) {
      for (final e in onlyRaw) {
        if (e is Map) {
          final m = Map<String, dynamic>.from(e);
          blockListOnly.add(BlockListOnlyRow(
            raw: m['raw']?.toString() ?? '',
            normalized: m['normalized']?.toString(),
          ));
        }
      }
    }

    final tenantsRaw = map['optedOutTenants'];
    final optedOutTenants = <SmsOptedOutTenantRow>[];
    if (tenantsRaw is List) {
      for (final e in tenantsRaw) {
        if (e is Map) {
          final m = Map<String, dynamic>.from(e);
          optedOutTenants.add(SmsOptedOutTenantRow(
            tenantId: m['tenantId']?.toString() ?? '',
            name: m['name']?.toString() ?? 'Tenant',
            phone: m['phone']?.toString() ?? '',
            smsOptOut: m['smsOptOut'] == true,
            smsConsentStatus: m['smsConsentStatus']?.toString(),
            smsConsentSource: m['smsConsentSource']?.toString(),
          ));
        }
      }
    }

    return FacilitySmsOptOutsSnapshot(
      blockList: blockList,
      blockListOnly: blockListOnly,
      optedOutTenants: optedOutTenants,
    );
  }

  static Future<RestoreSmsResult> restore({
    required String facilityId,
    required String phone,
    String? tenantId,
  }) async {
    final callable = _functions.httpsCallable('restoreFacilitySmsForPhone');
    final result = await callable.call({
      'facilityId': facilityId,
      'phone': phone,
      if (tenantId != null && tenantId.isNotEmpty) 'tenantId': tenantId,
    });
    final m = Map<String, dynamic>.from(result.data as Map);
    return RestoreSmsResult(
      ok: m['ok'] == true,
      removedFromBlockList: m['removedFromBlockList'] == true,
      tenantRecordUpdated: m['tenantRecordUpdated'] == true,
      tenantId: m['tenantId']?.toString(),
    );
  }
}

class FacilitySmsOptOutsSnapshot {
  final List<String> blockList;
  final List<BlockListOnlyRow> blockListOnly;
  final List<SmsOptedOutTenantRow> optedOutTenants;

  FacilitySmsOptOutsSnapshot({
    required this.blockList,
    required this.blockListOnly,
    required this.optedOutTenants,
  });
}

class BlockListOnlyRow {
  final String raw;
  final String? normalized;

  BlockListOnlyRow({required this.raw, this.normalized});
}

class SmsOptedOutTenantRow {
  final String tenantId;
  final String name;
  final String phone;
  final bool smsOptOut;
  final String? smsConsentStatus;
  final String? smsConsentSource;

  SmsOptedOutTenantRow({
    required this.tenantId,
    required this.name,
    required this.phone,
    required this.smsOptOut,
    this.smsConsentStatus,
    this.smsConsentSource,
  });
}

class RestoreSmsResult {
  final bool ok;
  final bool removedFromBlockList;
  final bool tenantRecordUpdated;
  final String? tenantId;

  RestoreSmsResult({
    required this.ok,
    required this.removedFromBlockList,
    required this.tenantRecordUpdated,
    this.tenantId,
  });
}
