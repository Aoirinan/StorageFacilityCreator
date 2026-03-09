import * as functions from 'firebase-functions/v1';
import * as admin from 'firebase-admin';

/**
 * Diagnostic function to check and fix facility ownership issues
 * Call this with: { "userEmail": "russell_Forsyth_1992@outlook.com" }
 */
export const diagnosticFixOwnership = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Must be authenticated');
  }

  const userEmail = data.userEmail || context.auth.token.email;
  const currentUid = context.auth.uid;

  functions.logger.info(`Diagnostic for user: ${userEmail} (UID: ${currentUid})`);

  const db = admin.firestore();
  const results: any = {
    currentUser: {
      uid: currentUid,
      email: context.auth.token.email,
    },
    account: null,
    facilities: [],
    issues: [],
    fixes: [],
  };

  // 1. Check facilityCreatorAccount
  const accountSnapshot = await db
    .collection('facilityCreatorAccounts')
    .where('ownerUid', '==', currentUid)
    .limit(1)
    .get();

  if (accountSnapshot.empty) {
    results.issues.push('No facilityCreatorAccount found for current UID');
    
    // Try to find by email
    const accountByEmailSnapshot = await db
      .collection('facilityCreatorAccounts')
      .where('ownerEmail', '==', userEmail?.toLowerCase())
      .limit(1)
      .get();

    if (!accountByEmailSnapshot.empty) {
      const accountDoc = accountByEmailSnapshot.docs[0];
      const accountData = accountDoc.data();
      results.issues.push(`Found account by email but ownerUid mismatch: ${accountData.ownerUid} vs ${currentUid}`);
      
      // FIX: Update account ownerUid
      await db.collection('facilityCreatorAccounts').doc(accountDoc.id).update({
        ownerUid: currentUid,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      results.fixes.push(`Updated account ${accountDoc.id} ownerUid to ${currentUid}`);
      results.account = { id: accountDoc.id, ...accountData, ownerUid: currentUid };
    }
  } else {
    const accountDoc = accountSnapshot.docs[0];
    results.account = { id: accountDoc.id, ...accountDoc.data() };
  }

  // 2. Check facilities
  const facilitiesSnapshot = await db
    .collection('facilities')
    .where('ownerUid', '==', currentUid)
    .get();

  if (facilitiesSnapshot.empty) {
    results.issues.push('No facilities found for current UID');
    
    // Try to find facilities by other means (email, account linkage)
    const allFacilitiesSnapshot = await db
      .collection('facilities')
      .where('active', '==', true)
      .get();

    for (const facilityDoc of allFacilitiesSnapshot.docs) {
      const facilityData = facilityDoc.data();
      const ownerEmail = facilityData.email?.toLowerCase();
      
      if (ownerEmail === userEmail?.toLowerCase()) {
        results.issues.push(`Found facility ${facilityDoc.id} by email but ownerUid mismatch: ${facilityData.ownerUid} vs ${currentUid}`);
        
        // FIX: Update facility ownerUid
        await db.collection('facilities').doc(facilityDoc.id).update({
          ownerUid: currentUid,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        });
        results.fixes.push(`Updated facility ${facilityDoc.id} ownerUid to ${currentUid}`);
        facilityData.ownerUid = currentUid;
        results.facilities.push({ id: facilityDoc.id, ...facilityData });
      }
    }
  } else {
    for (const facilityDoc of facilitiesSnapshot.docs) {
      results.facilities.push({ id: facilityDoc.id, ...facilityDoc.data() });
    }
  }

  // 3. Update account.facilityIds if needed
  if (results.account && results.facilities.length > 0) {
    const facilityIds = results.facilities.map((f: any) => f.id);
    const currentFacilityIds = results.account.facilityIds || [];
    
    if (JSON.stringify(facilityIds.sort()) !== JSON.stringify(currentFacilityIds.sort())) {
      await db.collection('facilityCreatorAccounts').doc(results.account.id).update({
        facilityIds: facilityIds,
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      results.fixes.push(`Updated account.facilityIds to [${facilityIds.join(', ')}]`);
    }
  }

  functions.logger.info(`Diagnostic complete: ${results.fixes.length} fixes applied`);
  return results;
});
