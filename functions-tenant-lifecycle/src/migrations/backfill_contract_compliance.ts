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
    const facilitiesSnapshot = await admin.firestore().collection('facilities').get();

    for (const facilityDoc of facilitiesSnapshot.docs) {
      const facilityId = facilityDoc.id;

      try {
        const contractsSnapshot = await admin
          .firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('contracts')
          .get();

        let contractBatch = admin.firestore().batch();
        let batchCount = 0;

        for (const contractDoc of contractsSnapshot.docs) {
          const data = contractDoc.data();

          if (!data.complianceStatus) {
            const updateData: Record<string, unknown> = {
              complianceStatus: 'active',
              isLicensedForm: false,
            };

            contractBatch.update(contractDoc.ref, updateData);
            batchCount++;
            contractsUpdated++;

            if (batchCount >= 500) {
              await contractBatch.commit();
              contractBatch = admin.firestore().batch();
              batchCount = 0;
            }
          }
        }

        if (batchCount > 0) {
          await contractBatch.commit();
        }

        const templatesSnapshot = await admin
          .firestore()
          .collection('facilities')
          .doc(facilityId)
          .collection('contractTemplates')
          .get();

        let templateBatch = admin.firestore().batch();
        batchCount = 0;

        for (const templateDoc of templatesSnapshot.docs) {
          const data = templateDoc.data();

          if (!data.complianceStatus) {
            const updateData: Record<string, unknown> = {
              complianceStatus: 'active',
              isLicensedForm: false,
            };

            templateBatch.update(templateDoc.ref, updateData);
            batchCount++;
            templatesUpdated++;

            if (batchCount >= 500) {
              await templateBatch.commit();
              templateBatch = admin.firestore().batch();
              batchCount = 0;
            }
          }
        }

        if (batchCount > 0) {
          await templateBatch.commit();
        }
      } catch (facilityError: any) {
        const errorMsg = `Error processing facility ${facilityId}: ${facilityError.message}`;
        errors.push(errorMsg);
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
