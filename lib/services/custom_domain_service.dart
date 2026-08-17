import 'package:cloud_functions/cloud_functions.dart';

/// One DNS row the operator has to create at their registrar.
class CustomDomainRecord {
  final String type;
  final String name;
  final String value;

  /// 'ADD' when Firebase is still waiting on this row. Anything else means
  /// Firebase already sees it and it is shown for reference only.
  final String? requiredAction;

  const CustomDomainRecord({
    required this.type,
    required this.name,
    required this.value,
    this.requiredAction,
  });

  bool get needsAction => (requiredAction ?? '').toUpperCase() == 'ADD';

  factory CustomDomainRecord.fromMap(Map<String, dynamic> map) {
    return CustomDomainRecord(
      type: (map['type'] as String? ?? '').toUpperCase(),
      name: map['name'] as String? ?? '',
      value: map['value'] as String? ?? '',
      requiredAction: map['requiredAction'] as String?,
    );
  }
}

/// Per-hostname progress, so apex and www can be reported separately rather
/// than collapsed into one number the operator cannot act on.
class CustomDomainHostname {
  final String hostname;
  final String status;

  const CustomDomainHostname({required this.hostname, required this.status});

  factory CustomDomainHostname.fromMap(Map<String, dynamic> map) {
    return CustomDomainHostname(
      hostname: map['hostname'] as String? ?? '',
      status: map['status'] as String? ?? 'unknown',
    );
  }
}

class CustomDomainState {
  final String? domain;
  final String status;
  final bool live;
  final List<CustomDomainRecord> records;
  final List<CustomDomainHostname> hostnames;

  const CustomDomainState({
    this.domain,
    required this.status,
    required this.live,
    this.records = const [],
    this.hostnames = const [],
  });

  bool get isConfigured => (domain ?? '').isNotEmpty;

  /// Rows the operator still has to create. Everything else is reference.
  List<CustomDomainRecord> get outstandingRecords =>
      records.where((r) => r.needsAction).toList();

  static List<T> _list<T>(
    Object? raw,
    T Function(Map<String, dynamic>) build,
  ) {
    if (raw is! List) return const [];
    return raw
        .whereType<Object>()
        .map((e) => Map<String, dynamic>.from(e as Map))
        .map(build)
        .toList();
  }

  factory CustomDomainState.fromMap(Map<String, dynamic> map) {
    return CustomDomainState(
      domain: map['domain'] as String?,
      status: map['status'] as String? ?? 'unknown',
      live: map['live'] == true,
      records: _list(map['records'], CustomDomainRecord.fromMap),
      hostnames: _list(map['hostnameStates'], CustomDomainHostname.fromMap),
    );
  }
}

/// Calls the self-serve custom domain callables.
///
/// Deliberately no super-admin path: connecting a domain is something the
/// facility does for itself. SFC cannot make DNS changes on an operator's
/// behalf in any case — registrars require a code texted to the domain owner
/// for every change — so the product's job is to say exactly what to enter and
/// then notice when it is done.
class CustomDomainService {
  static FirebaseFunctions get _functions => FirebaseFunctions.instance;

  static Future<CustomDomainState> connect({
    required String facilityId,
    required String domain,
  }) async {
    final result = await _functions
        .httpsCallable('provisionFacilityCustomDomain')
        .call<Map<String, dynamic>>({
      'facilityId': facilityId,
      'domain': domain,
    });
    return CustomDomainState.fromMap(Map<String, dynamic>.from(result.data));
  }

  static Future<CustomDomainState> refresh({required String facilityId}) async {
    final result = await _functions
        .httpsCallable('getFacilityCustomDomainStatus')
        .call<Map<String, dynamic>>({'facilityId': facilityId});
    return CustomDomainState.fromMap(Map<String, dynamic>.from(result.data));
  }
}
