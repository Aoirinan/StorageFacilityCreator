import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:sfcapp/models/insurance_plan_model.dart';
import 'package:sfcapp/models/tenant_insurance_model.dart';

class InsuranceService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  // Insurance Plans CRUD
  static Future<String> createInsurancePlan({
    required String facilityId,
    required String name,
    required double monthlyPrice,
    required double coverageAmount,
    String? description,
    bool isDefault = false,
    bool isRequired = false,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not signed in');

    final now = DateTime.now();
    final planRef = _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('insurancePlans')
        .doc();

    final plan = InsurancePlanModel(
      id: planRef.id,
      facilityId: facilityId,
      name: name,
      monthlyPrice: monthlyPrice,
      coverageAmount: coverageAmount,
      description: description,
      isDefault: isDefault,
      isRequired: isRequired,
      active: true,
      createdAt: now,
      updatedAt: now,
    );

    await planRef.set(plan.toFirestore());

    // If this is set as default, unset other defaults
    if (isDefault) {
      await _unsetOtherDefaults(facilityId, planRef.id);
    }

    return planRef.id;
  }

  static Future<void> updateInsurancePlan({
    required String facilityId,
    required String planId,
    String? name,
    double? monthlyPrice,
    double? coverageAmount,
    String? description,
    bool? isDefault,
    bool? isRequired,
    bool? active,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not signed in');

    final planRef = _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('insurancePlans')
        .doc(planId);

    final updates = <String, dynamic>{
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (name != null) updates['name'] = name;
    if (monthlyPrice != null) updates['monthlyPrice'] = monthlyPrice;
    if (coverageAmount != null) updates['coverageAmount'] = coverageAmount;
    if (description != null) updates['description'] = description;
    if (isDefault != null) updates['isDefault'] = isDefault;
    if (isRequired != null) updates['isRequired'] = isRequired;
    if (active != null) updates['active'] = active;

    await planRef.update(updates);

    // If setting as default, unset other defaults
    if (isDefault == true) {
      await _unsetOtherDefaults(facilityId, planId);
    }
  }

  static Future<void> deleteInsurancePlan({
    required String facilityId,
    required String planId,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not signed in');

    await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('insurancePlans')
        .doc(planId)
        .delete();
  }

  static Stream<List<InsurancePlanModel>> getInsurancePlansStream(String facilityId) {
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('insurancePlans')
        .where('active', isEqualTo: true)
        .orderBy('name')
        .snapshots()
        .map((snapshot) => snapshot.docs
            .map((doc) => InsurancePlanModel.fromFirestore(doc))
            .toList());
  }

  static Future<List<InsurancePlanModel>> getInsurancePlans(String facilityId) async {
    final snapshot = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('insurancePlans')
        .where('active', isEqualTo: true)
        .orderBy('name')
        .get();

    return snapshot.docs
        .map((doc) => InsurancePlanModel.fromFirestore(doc))
        .toList();
  }

  static Future<void> _unsetOtherDefaults(String facilityId, String currentPlanId) async {
    final snapshot = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('insurancePlans')
        .where('isDefault', isEqualTo: true)
        .get();

    final batch = _firestore.batch();
    for (final doc in snapshot.docs) {
      if (doc.id != currentPlanId) {
        batch.update(doc.reference, {'isDefault': false});
      }
    }
    await batch.commit();
  }

  // Tenant Insurance CRUD
  static Future<String> createTenantInsurance({
    required String tenantId,
    required String facilityId,
    required InsuranceType type,
    String? planId,
    String? providerName,
    String? policyNumber,
    DateTime? expirationDate,
    String? proofUrl,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not signed in');

    final now = DateTime.now();
    final insuranceRef = _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .collection('insurance')
        .doc();

    final insurance = TenantInsuranceModel(
      id: insuranceRef.id,
      tenantId: tenantId,
      facilityId: facilityId,
      type: type,
      planId: planId,
      providerName: providerName,
      policyNumber: policyNumber,
      expirationDate: expirationDate,
      proofUrl: proofUrl,
      createdAt: now,
      updatedAt: now,
    );

    await insuranceRef.set(insurance.toFirestore());
    return insuranceRef.id;
  }

  static Future<void> updateTenantInsurance({
    required String tenantId,
    required String facilityId,
    required String insuranceId,
    InsuranceType? type,
    String? planId,
    String? providerName,
    String? policyNumber,
    DateTime? expirationDate,
    String? proofUrl,
  }) async {
    final user = _auth.currentUser;
    if (user == null) throw Exception('Not signed in');

    final insuranceRef = _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .collection('insurance')
        .doc(insuranceId);

    final updates = <String, dynamic>{
      'updatedAt': FieldValue.serverTimestamp(),
    };

    if (type != null) updates['type'] = type.name;
    if (planId != null) updates['planId'] = planId;
    if (providerName != null) updates['providerName'] = providerName;
    if (policyNumber != null) updates['policyNumber'] = policyNumber;
    if (expirationDate != null) {
      updates['expirationDate'] = Timestamp.fromDate(expirationDate);
    }
    if (proofUrl != null) updates['proofUrl'] = proofUrl;

    await insuranceRef.update(updates);
  }

  static Future<TenantInsuranceModel?> getTenantInsurance({
    required String tenantId,
    required String facilityId,
  }) async {
    final snapshot = await _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .collection('insurance')
        .limit(1)
        .get();

    if (snapshot.docs.isEmpty) return null;
    return TenantInsuranceModel.fromFirestore(snapshot.docs.first);
  }

  static Stream<TenantInsuranceModel?> getTenantInsuranceStream({
    required String tenantId,
    required String facilityId,
  }) {
    return _firestore
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .collection('insurance')
        .limit(1)
        .snapshots()
        .map((snapshot) {
      if (snapshot.docs.isEmpty) return null;
      return TenantInsuranceModel.fromFirestore(snapshot.docs.first);
    });
  }

  // Reporting methods
  static Future<List<Map<String, dynamic>>> getTenantsWithFacilityInsurance({
    required String facilityId,
    String? planId,
  }) async {
    // This would require a more complex query or collection group query
    // For now, return empty list - can be enhanced later
    return [];
  }

  static Future<List<Map<String, dynamic>>> getTenantsWithThirdPartyInsurance({
    required String facilityId,
  }) async {
    // This would require a collection group query
    // For now, return empty list - can be enhanced later
    return [];
  }

  static Future<List<Map<String, dynamic>>> getTenantsWithExpiringInsurance({
    required String facilityId,
    int daysAhead = 30,
  }) async {
    // This would require querying all tenant insurance records
    // For now, return empty list - can be enhanced later
    return [];
  }
}

