import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:sfcapp/models/pricing_rule_model.dart';
import 'package:sfcapp/models/unit_model.dart';
import 'package:sfcapp/services/facility_service.dart';
import 'package:sfcapp/services/unit_service.dart';

/// Service for dynamic pricing calculations and recommendations
class DynamicPricingService {
  static final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  static final FirebaseAuth _auth = FirebaseAuth.instance;

  /// Get pricing rules for a facility
  static Future<List<PricingRule>> getPricingRules(String facilityId) async {
    try {
      final snapshot = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('pricingRules')
          .where('isActive', isEqualTo: true)
          .orderBy('createdAt', descending: true)
          .get();

      return snapshot.docs
          .map((doc) => PricingRule.fromMap(doc.id, doc.data()))
          .where((rule) => rule.isValid)
          .toList();
    } catch (e) {
      if (kDebugMode) {
        print('❌ [DynamicPricing] Error getting pricing rules: $e');
      }
      return [];
    }
  }

  /// Create a new pricing rule
  static Future<String> createPricingRule({
    required String facilityId,
    required String name,
    String? description,
    required PricingRuleType type,
    required PricingAdjustmentMethod adjustmentMethod,
    required double adjustmentValue,
    DateTime? validFrom,
    DateTime? validUntil,
    Map<String, dynamic>? conditions,
  }) async {
    try {
      final user = _auth.currentUser;
      if (user == null) throw Exception('User not authenticated');

      final rule = PricingRule(
        id: '',
        facilityId: facilityId,
        name: name,
        description: description,
        type: type,
        adjustmentMethod: adjustmentMethod,
        adjustmentValue: adjustmentValue,
        validFrom: validFrom,
        validUntil: validUntil,
        conditions: conditions,
        createdAt: DateTime.now(),
        createdBy: user.uid,
      );

      final docRef = await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('pricingRules')
          .add(rule.toMap());

      if (kDebugMode) {
        print('✅ [DynamicPricing] Created pricing rule: ${docRef.id}');
      }

      return docRef.id;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [DynamicPricing] Error creating pricing rule: $e');
      }
      rethrow;
    }
  }

  /// Calculate pricing recommendations for all units in a facility
  static Future<List<PricingRecommendation>> calculateRecommendations({
    required String facilityId,
  }) async {
    try {
      // Get facility and units
      final facility = await FacilityService.getFacility(facilityId);
      if (facility == null) return [];

      final units = await UnitService.getUnitsForFacility(facilityId);
      final rules = await getPricingRules(facilityId);

      // Calculate occupancy rate
      final totalUnits = units.length;
      final occupiedUnits = units.where((u) => u.status == UnitStatus.occupied).length;
      final occupancyRate = totalUnits > 0 ? (occupiedUnits / totalUnits) * 100 : 0.0;

      final recommendations = <PricingRecommendation>[];

      for (final unit in units) {
        // Only recommend for available units
        if (unit.status != UnitStatus.available) continue;

        double adjustedPrice = unit.monthlyRate;
        final appliedRules = <String>[];
        final reasons = <String>[];

        // Apply each applicable rule
        for (final rule in rules) {
          if (_ruleAppliesToUnit(rule, unit, occupancyRate)) {
            adjustedPrice = rule.calculateAdjustedPrice(adjustedPrice);
            appliedRules.add(rule.name);

            // Build reason
            reasons.add('${rule.name}: ${rule.adjustmentDescription}');
          }
        }

        final adjustmentAmount = adjustedPrice - unit.monthlyRate;
        final adjustmentPercentage = unit.monthlyRate > 0
            ? (adjustmentAmount / unit.monthlyRate) * 100
            : 0.0;

        // Only create recommendation if price would change
        if (adjustmentAmount.abs() > 0.01) {
          recommendations.add(PricingRecommendation(
            unitId: unit.id,
            unitNumber: unit.unitNumber,
            currentPrice: unit.monthlyRate,
            recommendedPrice: adjustedPrice,
            adjustmentAmount: adjustmentAmount,
            adjustmentPercentage: adjustmentPercentage,
            appliedRules: appliedRules,
            reason: reasons.join(', '),
          ));
        }
      }

      return recommendations;
    } catch (e) {
      if (kDebugMode) {
        print('❌ [DynamicPricing] Error calculating recommendations: $e');
      }
      return [];
    }
  }

  /// Check if a rule applies to a unit
  static bool _ruleAppliesToUnit(
    PricingRule rule,
    UnitModel unit,
    double occupancyRate,
  ) {
    switch (rule.type) {
      case PricingRuleType.occupancyBased:
        final conditions = rule.conditions ?? {};
        final minOccupancy = (conditions['minOccupancy'] as num?)?.toDouble();
        final maxOccupancy = (conditions['maxOccupancy'] as num?)?.toDouble();
        
        if (minOccupancy != null && occupancyRate < minOccupancy) return false;
        if (maxOccupancy != null && occupancyRate > maxOccupancy) return false;
        return true;

      case PricingRuleType.seasonal:
        final now = DateTime.now();
        final month = now.month;
        final conditions = rule.conditions ?? {};
        final months = conditions['months'] as List<dynamic>?;
        
        if (months != null && !months.contains(month)) return false;
        return true;

      case PricingRuleType.unitType:
        final conditions = rule.conditions ?? {};
        final unitTypes = conditions['unitTypes'] as List<dynamic>?;
        
        if (unitTypes != null && !unitTypes.contains(unit.unitType)) return false;
        return true;

      case PricingRuleType.demandBased:
        // Would need demand data - for now, return true
        return true;

      case PricingRuleType.marketRate:
        // Would need market rate data - for now, return true
        return true;
    }
  }

  /// Apply pricing recommendations to units
  static Future<void> applyRecommendations({
    required String facilityId,
    required List<String> unitIds,
  }) async {
    try {
      final recommendations = await calculateRecommendations(facilityId: facilityId);
      final toApply = recommendations.where((r) => unitIds.contains(r.unitId)).toList();

      for (final rec in toApply) {
        await UnitService.updateUnit(
          facilityId: facilityId,
          unitId: rec.unitId,
          monthlyRate: rec.recommendedPrice,
        );
      }

      if (kDebugMode) {
        print('✅ [DynamicPricing] Applied ${toApply.length} pricing recommendations');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [DynamicPricing] Error applying recommendations: $e');
      }
      rethrow;
    }
  }

  /// Delete a pricing rule
  static Future<void> deletePricingRule({
    required String facilityId,
    required String ruleId,
  }) async {
    try {
      await _firestore
          .collection('facilities')
          .doc(facilityId)
          .collection('pricingRules')
          .doc(ruleId)
          .update({'isActive': false});

      if (kDebugMode) {
        print('✅ [DynamicPricing] Deleted pricing rule: $ruleId');
      }
    } catch (e) {
      if (kDebugMode) {
        print('❌ [DynamicPricing] Error deleting pricing rule: $e');
      }
      rethrow;
    }
  }
}

