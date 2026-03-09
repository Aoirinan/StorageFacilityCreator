import * as admin from 'firebase-admin';

/**
 * Migration script to backfill existing contracts and templates with compliance fields
 * Sets default values:
 * - complianceStatus: 'active'
 * - isLicensedForm: false
 * - Other fields remain null/undefined
 */
export async function backfillContractCompliance(): Promise<{ contractsUpdated: number; templatesUpdated: number; errors: string[] }> {
  const errors: string[] = [];
  let contractsUpdated = 0;
  let templatesUpdated = 0;

  try {
    // Get all facilities
    const facilitiesSnapshot = await admin.firestore().collection('facilities').get();

    for (const facilityDoc of facilitiesSnapshot.docs) {
      const facilityId = facilityDoc.id;

      try {
        // Backfill contracts
        const contractsSnapshot = await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .get();

        const contractBatch = admin.firestore().batch();
        let batchCount = 0;

        for (const contractDoc of contractsSnapshot.docs) {
          const data = contractDoc.data();
          
          // Only update if complianceStatus is missing
          if (!data.complianceStatus) {
            const updateData: any = {
              complianceStatus: 'active',
              isLicensedForm: false,
            };
            
            contractBatch.update(contractDoc.ref, updateData);
            batchCount++;
            contractsUpdated++;

            // Firestore batch limit is 500
            if (batchCount >= 500) {
              await contractBatch.commit();
              batchCount = 0;
            }
          }
        }

        if (batchCount > 0) {
          await contractBatch.commit();
        }

        // Backfill templates
        const templatesSnapshot = await admin.firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('contractTemplates')
          .get();

        const templateBatch = admin.firestore().batch();
        batchCount = 0;

        for (const templateDoc of templatesSnapshot.docs) {
          const data = templateDoc.data();
          
          // Only update if complianceStatus is missing
          if (!data.complianceStatus) {
            const updateData: any = {
              complianceStatus: 'active',
              isLicensedForm: false,
            };
            
            templateBatch.update(templateDoc.ref, updateData);
            batchCount++;
            templatesUpdated++;

            // Firestore batch limit is 500
            if (batchCount >= 500) {
              await templateBatch.commit();
              batchCount = 0;
            }
          }
        }

        if (batchCount > 0) {
          await templateBatch.commit();
        }

        console.log(`✅ Backfilled compliance for facility: ${facilityId}`);
      } catch (facilityError: any) {
        const errorMsg = `Error processing facility ${facilityId}: ${facilityError.message}`;
        errors.push(errorMsg);
        console.error(`❌ ${errorMsg}`);
      }
    }

    return {
      contractsUpdated,
      templatesUpdated,
      errors,
    };
  } catch (error: any) {
    errors.push(`Migration failed: ${error.message}`);
    throw error;
  }
}
