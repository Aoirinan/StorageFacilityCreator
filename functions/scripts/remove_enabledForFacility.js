const admin = require('firebase-admin');

async function main() {
  const projectId = process.env.GCLOUD_PROJECT || 'storage-facility-creator';
  admin.initializeApp({ projectId });
  const db = admin.firestore();

  const facilitiesSnap = await db.collection('facilities').select().get();
  let scanned = 0;
  let updated = 0;
  let batch = db.batch();
  let ops = 0;

  for (const facilityDoc of facilitiesSnap.docs) {
    scanned += 1;
    const metaRef = facilityDoc.ref.collection('mapEngine').doc('meta');
    const metaSnap = await metaRef.get();
    if (!metaSnap.exists) continue;

    const data = metaSnap.data() || {};
    if (!Object.prototype.hasOwnProperty.call(data, 'enabledForFacility')) {
      continue;
    }

    batch.update(metaRef, {
      enabledForFacility: admin.firestore.FieldValue.delete(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    ops += 1;
    updated += 1;

    if (ops >= 400) {
      await batch.commit();
      batch = db.batch();
      ops = 0;
    }
  }

  if (ops > 0) {
    await batch.commit();
  }

  console.log(
    JSON.stringify(
      {
        ok: true,
        projectId,
        facilitiesScanned: scanned,
        docsUpdated: updated,
      },
      null,
      2,
    ),
  );
}

main().catch((err) => {
  console.error(
    JSON.stringify(
      {
        ok: false,
        error: err?.message || String(err),
      },
      null,
      2,
    ),
  );
  process.exitCode = 1;
});
