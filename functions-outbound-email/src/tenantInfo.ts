import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';

export async function getTenantInfo(
  facilityId: string,
  tenantId?: string | null,
  email?: string | null,
  phone?: string | null,
): Promise<{
  tenantId: string | null;
  tenantName: string | null;
  tenantEmail: string | null;
  tenantPhone: string | null;
}> {
  if (!tenantId && !email && !phone) {
    return {
      tenantId: null,
      tenantName: null,
      tenantEmail: email || null,
      tenantPhone: phone || null,
    };
  }

  try {
    let tenantDoc: admin.firestore.DocumentSnapshot | null = null;

    if (tenantId) {
      tenantDoc = await admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .doc(tenantId)
        .get();
    } else if (email) {
      const tenantQuery = await admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .where('email', '==', email)
        .limit(1)
        .get();
      if (!tenantQuery.empty) {
        tenantDoc = tenantQuery.docs[0];
      }
    } else if (phone) {
      const tenantQuery = await admin
        .firestore()
        .collection('facilities')
        .doc(facilityId)
        .collection('tenants')
        .where('phone', '==', phone)
        .limit(1)
        .get();
      if (!tenantQuery.empty) {
        tenantDoc = tenantQuery.docs[0];
      }
    }

    if (tenantDoc && tenantDoc.exists) {
      const tenantData = tenantDoc.data() as Record<string, unknown>;
      return {
        tenantId: tenantDoc.id,
        tenantName: (tenantData.name as string) || null,
        tenantEmail: (tenantData.email as string) || email || null,
        tenantPhone: (tenantData.phone as string) || phone || null,
      };
    }
  } catch (error) {
    functions.logger.warn('Failed to fetch tenant info for message log', {
      error,
      facilityId,
      tenantId,
      email,
      phone,
    });
  }

  return {
    tenantId: tenantId || null,
    tenantName: null,
    tenantEmail: email || null,
    tenantPhone: phone || null,
  };
}
