export type PortalAccountTenantFields = {
  portalAccountId?: unknown;
  emailLower?: unknown;
  portalEnabled?: unknown;
  portalAccessCode?: unknown;
};

/** Whether [requested] belongs to the same portal login as [authTenant]. */
export function tenantsSharePortalAccount(
  authTenant: PortalAccountTenantFields,
  requestedTenant: PortalAccountTenantFields,
  emailLower: string,
  accessCode: string,
): boolean {
  const portalAccountId = (authTenant.portalAccountId || '').toString().trim();
  const requestedPortalAccountId = (requestedTenant.portalAccountId || '').toString().trim();
  if (portalAccountId && requestedPortalAccountId) {
    return requestedPortalAccountId === portalAccountId;
  }
  const code = accessCode.trim();
  return (
    (requestedTenant.emailLower || '').toString().trim().toLowerCase() === emailLower &&
    requestedTenant.portalEnabled === true &&
    (requestedTenant.portalAccessCode || '').toString().trim() === code
  );
}

/** Stripe PaymentIntent metadata for tenant portal checkout (webhook persistence). */
export function buildTenantPortalPaymentIntentMetadata(facilityId: string, tenantId: string) {
  return {
    facilityId,
    tenantId,
    type: 'tenant_portal_payment',
  };
}
