import 'package:cloud_functions/cloud_functions.dart';

class QuickBooksService {
  static final FirebaseFunctions _functions = FirebaseFunctions.instance;

  static Future<Map<String, dynamic>> getConnectionStatus({
    required String facilityId,
  }) async {
    final result = await _functions
        .httpsCallable('getQuickBooksConnectionStatus')
        .call({'facilityId': facilityId});
    return Map<String, dynamic>.from(result.data as Map);
  }

  static Future<Map<String, dynamic>> getConnectUrl({
    required String facilityId,
  }) async {
    final result = await _functions
        .httpsCallable('getQuickBooksConnectUrl')
        .call({'facilityId': facilityId});
    return Map<String, dynamic>.from(result.data as Map);
  }

  static Future<Map<String, dynamic>> completeConnect({
    required String facilityId,
    required String code,
    required String realmId,
    required String state,
  }) async {
    final result = await _functions
        .httpsCallable('completeQuickBooksConnect')
        .call({
      'facilityId': facilityId,
      'code': code,
      'realmId': realmId,
      'state': state,
    });
    return Map<String, dynamic>.from(result.data as Map);
  }

  static Future<void> disconnect({
    required String facilityId,
  }) async {
    await _functions
        .httpsCallable('disconnectQuickBooks')
        .call({'facilityId': facilityId});
  }

  static Future<Map<String, dynamic>> setAutoSync({
    required String facilityId,
    required bool enabled,
  }) async {
    final result = await _functions
        .httpsCallable('setQuickBooksAutoSync')
        .call({
      'facilityId': facilityId,
      'enabled': enabled,
    });
    return Map<String, dynamic>.from(result.data as Map);
  }

  static Future<Map<String, dynamic>> syncInvoice({
    required String facilityId,
    required String invoiceId,
  }) async {
    final result = await _functions
        .httpsCallable('syncInvoiceToQuickBooks')
        .call({
      'facilityId': facilityId,
      'invoiceId': invoiceId,
    });
    return Map<String, dynamic>.from(result.data as Map);
  }

  static Future<Map<String, dynamic>> syncPayment({
    required String facilityId,
    required String paymentId,
    String? invoiceId,
  }) async {
    final payload = <String, dynamic>{
      'facilityId': facilityId,
      'paymentId': paymentId,
    };
    if (invoiceId != null && invoiceId.trim().isNotEmpty) {
      payload['invoiceId'] = invoiceId.trim();
    }
    final result = await _functions
        .httpsCallable('syncPaymentToQuickBooks')
        .call(payload);
    return Map<String, dynamic>.from(result.data as Map);
  }
}
