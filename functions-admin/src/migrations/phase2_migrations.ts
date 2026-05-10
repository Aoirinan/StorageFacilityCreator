/**
 * Phase 2: Security Hardening - Data Migration Scripts
 * 
 * These scripts migrate data from unscoped collections to facility/account-scoped collections.
 * 
 * IMPORTANT: Run these scripts in order, test on staging first, and verify data integrity.
 */

import * as admin from 'firebase-admin';
import { getFirestore } from '@sfc/functions-shared/firestoreLazy';

/**
 * Migration 1: Contract Templates
 * Migrates from contract_templates/{templateId} to facilities/{facilityId}/contractTemplates/{templateId}
 */
export async function migrateContractTemplates(): Promise<{
  success: boolean;
  migrated: number;
  errors: string[];
}> {
  const errors: string[] = [];
  let migrated = 0;

  try {
    console.log('🔄 Starting contract templates migration...');

    // Get all contract templates
    const templatesSnapshot = await getFirestore().collection('contract_templates').get();

    if (templatesSnapshot.empty) {
      console.log('✅ No contract templates to migrate');
      return { success: true, migrated: 0, errors: [] };
    }

    console.log(`📦 Found ${templatesSnapshot.docs.length} contract templates to migrate`);

    // Group templates by facilityId (if exists) or ownerUid
    const templatesByFacility = new Map<string, any[]>();

    for (const templateDoc of templatesSnapshot.docs) {
      const templateData = templateDoc.data();
      const facilityId = templateData.facilityId;

      if (!facilityId) {
        // Try to find facility by ownerUid
        const createdBy = templateData.createdBy;
        if (createdBy) {
          const facilitiesSnapshot = await getFirestore()
            .collection('facilities')
            .where('ownerUid', '==', createdBy)
            .limit(1)
            .get();

          if (!facilitiesSnapshot.empty) {
            const facilityId = facilitiesSnapshot.docs[0].id;
            if (!templatesByFacility.has(facilityId)) {
              templatesByFacility.set(facilityId, []);
            }
            templatesByFacility.get(facilityId)!.push({
              id: templateDoc.id,
              data: { ...templateData, facilityId },
            });
          } else {
            errors.push(`Template ${templateDoc.id}: No facility found for owner ${createdBy}`);
          }
        } else {
          errors.push(`Template ${templateDoc.id}: No facilityId or createdBy found`);
        }
      } else {
        if (!templatesByFacility.has(facilityId)) {
          templatesByFacility.set(facilityId, []);
        }
        templatesByFacility.get(facilityId)!.push({
          id: templateDoc.id,
          data: templateData,
        });
      }
    }

    // Migrate templates to facility subcollections
    for (const [facilityId, templates] of templatesByFacility.entries()) {
      const batch = getFirestore().batch();

      for (const template of templates) {
        const newRef = getFirestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('contractTemplates')
          .doc(template.id);

        batch.set(newRef, {
          ...template.data,
          facilityId: facilityId,
          migratedAt: admin.firestore.FieldValue.serverTimestamp(),
          migratedFrom: 'contract_templates',
        });
      }

      try {
        await batch.commit();
        migrated += templates.length;
        console.log(`✅ Migrated ${templates.length} templates to facility ${facilityId}`);
      } catch (error: any) {
        errors.push(`Facility ${facilityId}: ${error.message}`);
      }
    }

    console.log(`✅ Contract templates migration complete: ${migrated} migrated, ${errors.length} errors`);
    return { success: errors.length === 0, migrated, errors };
  } catch (error: any) {
    console.error('❌ Error migrating contract templates:', error);
    return { success: false, migrated, errors: [error.message] };
  }
}

/**
 * Migration 2: Security Collections
 * Migrates from security_events/{eventId}, security_alerts/{alertId}, security_settings/{settingId}
 * to facilityCreatorAccounts/{accountId}/security_* subcollections
 */
export async function migrateSecurityCollections(): Promise<{
  success: boolean;
  migrated: {
    events: number;
    alerts: number;
    settings: number;
  };
  errors: string[];
}> {
  const errors: string[] = [];
  const migrated = { events: 0, alerts: 0, settings: 0 };

  try {
    console.log('🔄 Starting security collections migration...');

    // Helper: Get accountId from userId or facilityId
    async function getAccountId(userId?: string, facilityId?: string): Promise<string | null> {
      if (facilityId) {
        const facilityDoc = await getFirestore().collection('facilities').doc(facilityId).get();
        if (facilityDoc.exists) {
          const facilityData = facilityDoc.data();
          return facilityData?.facilityCreatorAccountId || null;
        }
      }

      if (userId) {
        const accountsSnapshot = await getFirestore()
          .collection('facilityCreatorAccounts')
          .where('ownerUid', '==', userId)
          .limit(1)
          .get();

        if (!accountsSnapshot.empty) {
          return accountsSnapshot.docs[0].id;
        }
      }

      return null;
    }

    // Migrate security_events
    console.log('📦 Migrating security_events...');
    const eventsSnapshot = await getFirestore().collection('security_events').get();

    for (const eventDoc of eventsSnapshot.docs) {
      const eventData = eventDoc.data();
      const accountId = await getAccountId(eventData.userId, eventData.facilityId);

      if (!accountId) {
        errors.push(`Security event ${eventDoc.id}: No account found`);
        continue;
      }

      try {
        await getFirestore()
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection('security_events')
          .doc(eventDoc.id)
          .set({
            ...eventData,
            migratedAt: admin.firestore.FieldValue.serverTimestamp(),
            migratedFrom: 'security_events',
          });
        migrated.events++;
      } catch (error: any) {
        errors.push(`Security event ${eventDoc.id}: ${error.message}`);
      }
    }

    // Migrate security_alerts
    console.log('📦 Migrating security_alerts...');
    const alertsSnapshot = await getFirestore().collection('security_alerts').get();

    for (const alertDoc of alertsSnapshot.docs) {
      const alertData = alertDoc.data();
      const accountId = await getAccountId(alertData.userId, alertData.facilityId);

      if (!accountId) {
        errors.push(`Security alert ${alertDoc.id}: No account found`);
        continue;
      }

      try {
        await getFirestore()
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection('security_alerts')
          .doc(alertDoc.id)
          .set({
            ...alertData,
            migratedAt: admin.firestore.FieldValue.serverTimestamp(),
            migratedFrom: 'security_alerts',
          });
        migrated.alerts++;
      } catch (error: any) {
        errors.push(`Security alert ${alertDoc.id}: ${error.message}`);
      }
    }

    // Migrate security_settings
    console.log('📦 Migrating security_settings...');
    const settingsSnapshot = await getFirestore().collection('security_settings').get();

    for (const settingDoc of settingsSnapshot.docs) {
      const settingData = settingDoc.data();
      const accountId = await getAccountId(settingData.userId, settingData.facilityId);

      if (!accountId) {
        errors.push(`Security setting ${settingDoc.id}: No account found`);
        continue;
      }

      try {
        await getFirestore()
          .collection('facilityCreatorAccounts')
          .doc(accountId)
          .collection('security_settings')
          .doc(settingDoc.id === 'global' ? 'default' : settingDoc.id)
          .set({
            ...settingData,
            migratedAt: admin.firestore.FieldValue.serverTimestamp(),
            migratedFrom: 'security_settings',
          });
        migrated.settings++;
      } catch (error: any) {
        errors.push(`Security setting ${settingDoc.id}: ${error.message}`);
      }
    }

    console.log(`✅ Security collections migration complete:`, migrated);
    return { success: errors.length === 0, migrated, errors };
  } catch (error: any) {
    console.error('❌ Error migrating security collections:', error);
    return { success: false, migrated, errors: [error.message] };
  }
}

/**
 * Migration 3: DNR Entries (if global dnr_entries collection exists)
 * Migrates from dnr_entries/{dnrId} to facilities/{facilityId}/dnr/{dnrId}
 */
export async function migrateDNREntries(): Promise<{
  success: boolean;
  migrated: number;
  errors: string[];
}> {
  const errors: string[] = [];
  let migrated = 0;

  try {
    console.log('🔄 Starting DNR entries migration...');

    // Check if global dnr_entries collection exists
    const dnrSnapshot = await getFirestore().collection('dnr_entries').limit(1).get();

    if (dnrSnapshot.empty) {
      console.log('✅ No global DNR entries to migrate (collection may not exist)');
      return { success: true, migrated: 0, errors: [] };
    }

    // Get all DNR entries
    const allDnrSnapshot = await getFirestore().collection('dnr_entries').get();

    console.log(`📦 Found ${allDnrSnapshot.docs.length} DNR entries to migrate`);

    for (const dnrDoc of allDnrSnapshot.docs) {
      const dnrData = dnrDoc.data();
      const createdBy = dnrData.createdBy;

      if (!createdBy) {
        errors.push(`DNR entry ${dnrDoc.id}: No createdBy found`);
        continue;
      }

      // Find facility by ownerUid
      const facilitiesSnapshot = await getFirestore()
        .collection('facilities')
        .where('ownerUid', '==', createdBy)
        .limit(1)
        .get();

      if (facilitiesSnapshot.empty) {
        errors.push(`DNR entry ${dnrDoc.id}: No facility found for owner ${createdBy}`);
        continue;
      }

      const facilityId = facilitiesSnapshot.docs[0].id;

      try {
        await getFirestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('dnr')
          .doc(dnrDoc.id)
          .set({
            ...dnrData,
            facilityId: facilityId,
            migratedAt: admin.firestore.FieldValue.serverTimestamp(),
            migratedFrom: 'dnr_entries',
          });
        migrated++;
      } catch (error: any) {
        errors.push(`DNR entry ${dnrDoc.id}: ${error.message}`);
      }
    }

    console.log(`✅ DNR entries migration complete: ${migrated} migrated, ${errors.length} errors`);
    return { success: errors.length === 0, migrated, errors };
  } catch (error: any) {
    console.error('❌ Error migrating DNR entries:', error);
    return { success: false, migrated, errors: [error.message] };
  }
}

/**
 * Run all migrations in order
 */
export async function runAllMigrations(): Promise<void> {
  console.log('🚀 Starting Phase 2 data migrations...\n');

  const results = {
    contractTemplates: await migrateContractTemplates(),
    securityCollections: await migrateSecurityCollections(),
    dnrEntries: await migrateDNREntries(),
  };

  console.log('\n📊 Migration Summary:');
  console.log('Contract Templates:', results.contractTemplates);
  console.log('Security Collections:', results.securityCollections);
  console.log('DNR Entries:', results.dnrEntries);

  const allSuccess = Object.values(results).every((r) => r.success);
  if (allSuccess) {
    console.log('\n✅ All migrations completed successfully!');
  } else {
    console.log('\n⚠️ Some migrations had errors. Review the errors above.');
  }
}

/**
 * Cloud Function to run migrations (for manual execution)
 * 
 * Usage: Call this function via Firebase Console or CLI
 * firebase functions:call runPhase2Migrations
 * 
 * NOTE: This function is exported from index.ts, not here, to avoid circular dependencies
 */

