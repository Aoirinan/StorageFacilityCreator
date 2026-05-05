import * as admin from 'firebase-admin';

const PAGE_SIZE = 200;

/**
 * Recursively delete a Firestore document and all nested subcollections.
 * Uses paginated reads to avoid loading unbounded collections into memory.
 */
export async function adminDeleteDocumentTree(
  docRef: admin.firestore.DocumentReference,
): Promise<void> {
  const subcols = await docRef.listCollections();
  for (const colRef of subcols) {
    await deleteCollectionDocumentsRecursive(colRef);
  }
  await docRef.delete();
}

async function deleteCollectionDocumentsRecursive(
  colRef: admin.firestore.CollectionReference,
): Promise<void> {
  let last: admin.firestore.QueryDocumentSnapshot | undefined;
  for (;;) {
    let q: admin.firestore.Query = colRef
      .orderBy(admin.firestore.FieldPath.documentId())
      .limit(PAGE_SIZE);
    if (last) {
      q = q.startAfter(last);
    }
    const snap = await q.get();
    if (snap.empty) {
      break;
    }
    for (const doc of snap.docs) {
      await adminDeleteDocumentTree(doc.ref);
    }
    if (snap.size < PAGE_SIZE) {
      break;
    }
    last = snap.docs[snap.docs.length - 1];
  }
}
