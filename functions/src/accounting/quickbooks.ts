import * as admin from 'firebase-admin';
import * as functions from 'firebase-functions/v1';
import * as crypto from 'crypto';

type QuickBooksEnv = 'sandbox' | 'production';

export interface QuickBooksConfig {
  clientId: string;
  clientSecret: string;
  redirectUri: string;
  environment: QuickBooksEnv;
}

interface QuickBooksTokenResponse {
  access_token: string;
  refresh_token: string;
  expires_in: number;
  x_refresh_token_expires_in?: number;
  token_type?: string;
  scope?: string;
}

function facilityRef(facilityId: string) {
  return admin.firestore().collection('facilities').doc(facilityId);
}

function quickBooksIntegrationRef(facilityId: string) {
  return facilityRef(facilityId).collection('integrations').doc('quickbooks');
}

function quickBooksOAuthStateRef(state: string) {
  return admin.firestore().collection('quickbooks_oauth_states').doc(state);
}

function getApiBase(environment: QuickBooksEnv): string {
  return environment === 'sandbox'
    ? 'https://sandbox-quickbooks.api.intuit.com'
    : 'https://quickbooks.api.intuit.com';
}

function getAuthorizeBase(): string {
  return 'https://appcenter.intuit.com/connect/oauth2';
}

function tokenEndpoint(): string {
  return 'https://oauth.platform.intuit.com/oauth2/v1/tokens/bearer';
}

function formatDate(value: unknown): string {
  if (value instanceof admin.firestore.Timestamp) {
    return value.toDate().toISOString().slice(0, 10);
  }
  if (value instanceof Date) {
    return value.toISOString().slice(0, 10);
  }
  return new Date().toISOString().slice(0, 10);
}

function asNumber(value: unknown): number {
  if (typeof value === 'number') return value;
  if (typeof value === 'string') return Number(value) || 0;
  return 0;
}

function toTimestampFromNow(seconds: number): admin.firestore.Timestamp {
  return admin.firestore.Timestamp.fromMillis(Date.now() + (seconds * 1000));
}

function extractMillis(value: unknown): number | null {
  if (value instanceof admin.firestore.Timestamp) return value.toMillis();
  return null;
}

async function assertFacilityAccountingAccess(
  context: functions.https.CallableContext,
  facilityId: string,
): Promise<void> {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'User must be authenticated');
  }
  const facilityDoc = await facilityRef(facilityId).get();
  if (!facilityDoc.exists) {
    throw new functions.https.HttpsError('not-found', 'Facility not found');
  }
  const facilityData = facilityDoc.data() || {};
  const roles = (facilityData.roles || {}) as Record<string, string>;
  const managers = (facilityData.managers || {}) as Record<string, boolean>;
  const uid = context.auth.uid;
  const isOwnerOrManager =
    facilityData.ownerUid === uid ||
    roles[uid] === 'owner' ||
    roles[uid] === 'manager' ||
    managers[uid] === true;
  if (!isOwnerOrManager) {
    throw new functions.https.HttpsError('permission-denied', 'Only facility owner/manager can manage accounting sync');
  }
}

async function exchangeToken(
  config: QuickBooksConfig,
  grantType: 'authorization_code' | 'refresh_token',
  payload: { code?: string; refreshToken?: string },
): Promise<QuickBooksTokenResponse> {
  const params = new URLSearchParams();
  params.set('grant_type', grantType);
  if (grantType === 'authorization_code') {
    params.set('code', payload.code || '');
    params.set('redirect_uri', config.redirectUri);
  } else {
    params.set('refresh_token', payload.refreshToken || '');
  }

  const auth = Buffer.from(`${config.clientId}:${config.clientSecret}`).toString('base64');
  const res = await fetch(tokenEndpoint(), {
    method: 'POST',
    headers: {
      Authorization: `Basic ${auth}`,
      'Content-Type': 'application/x-www-form-urlencoded',
      Accept: 'application/json',
    },
    body: params.toString(),
  });

  const json = await res.json() as Record<string, unknown>;
  if (!res.ok) {
    functions.logger.error('QuickBooks token exchange failed', {
      status: res.status,
      error: json,
      grantType,
    });
    throw new functions.https.HttpsError('internal', 'QuickBooks token exchange failed');
  }

  return json as unknown as QuickBooksTokenResponse;
}

async function runQboRequest(
  input: {
    config: QuickBooksConfig;
    accessToken: string;
    realmId: string;
    method: 'GET' | 'POST';
    path: string;
    body?: Record<string, unknown>;
  },
): Promise<Record<string, unknown>> {
  const base = getApiBase(input.config.environment);
  const url = `${base}/v3/company/${input.realmId}${input.path}`;
  const res = await fetch(url, {
    method: input.method,
    headers: {
      Authorization: `Bearer ${input.accessToken}`,
      Accept: 'application/json',
      'Content-Type': 'application/json',
    },
    body: input.body ? JSON.stringify(input.body) : undefined,
  });
  const json = await res.json() as Record<string, unknown>;
  if (!res.ok || json.Fault) {
    functions.logger.error('QuickBooks API request failed', {
      status: res.status,
      path: input.path,
      fault: json.Fault || json,
    });
    throw new functions.https.HttpsError('internal', 'QuickBooks API request failed');
  }
  return json;
}

async function getValidConnection(
  facilityId: string,
  config: QuickBooksConfig,
): Promise<{ realmId: string; accessToken: string; ref: FirebaseFirestore.DocumentReference }> {
  const ref = quickBooksIntegrationRef(facilityId);
  const snap = await ref.get();
  if (!snap.exists) {
    throw new functions.https.HttpsError('failed-precondition', 'QuickBooks is not connected for this facility');
  }

  const data = snap.data() || {};
  const realmId = (data.realmId as string | undefined) || '';
  const refreshToken = (data.refreshToken as string | undefined) || '';
  let accessToken = (data.accessToken as string | undefined) || '';
  const accessTokenExpiresAtMillis = extractMillis(data.accessTokenExpiresAt);
  const shouldRefresh = !accessTokenExpiresAtMillis || accessTokenExpiresAtMillis <= Date.now() + (2 * 60 * 1000);

  if (!realmId || !refreshToken) {
    throw new functions.https.HttpsError('failed-precondition', 'QuickBooks connection is incomplete');
  }

  if (shouldRefresh) {
    const refreshed = await exchangeToken(config, 'refresh_token', { refreshToken });
    accessToken = refreshed.access_token;
    await ref.set(
      {
        accessToken: refreshed.access_token,
        refreshToken: refreshed.refresh_token,
        tokenType: refreshed.token_type || 'bearer',
        scope: refreshed.scope || '',
        accessTokenExpiresAt: toTimestampFromNow(refreshed.expires_in || 3600),
        refreshTokenExpiresAt: toTimestampFromNow(refreshed.x_refresh_token_expires_in || (100 * 24 * 3600)),
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
  }

  return { realmId, accessToken, ref };
}

async function ensureQboCustomer(
  config: QuickBooksConfig,
  facilityId: string,
  tenantId: string,
  connection: { realmId: string; accessToken: string },
): Promise<string> {
  const tenantRef = facilityRef(facilityId).collection('tenants').doc(tenantId);
  const tenantSnap = await tenantRef.get();
  if (!tenantSnap.exists) {
    throw new functions.https.HttpsError('not-found', 'Tenant not found');
  }
  const tenant = tenantSnap.data() || {};

  const existing = tenant.quickbooksCustomerId as string | undefined;
  if (existing && existing.trim()) return existing;

  const displayName = (tenant.name as string | undefined) || (tenant.email as string | undefined) || `Tenant ${tenantId}`;
  const escapedDisplayName = displayName.replace(/'/g, "\\'");
  const query = encodeURIComponent(`select * from Customer where DisplayName = '${escapedDisplayName}' maxresults 1`);
  const queryResponse = await runQboRequest({
    config,
    accessToken: connection.accessToken,
    realmId: connection.realmId,
    method: 'GET',
    path: `/query?query=${query}`,
  });
  const existingCustomers = (((queryResponse.QueryResponse as Record<string, unknown> | undefined)?.Customer || []) as Array<Record<string, unknown>>);
  if (existingCustomers.length > 0) {
    const customerId = String(existingCustomers[0].Id || '');
    if (customerId) {
      await tenantRef.set(
        {
          quickbooksCustomerId: customerId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      return customerId;
    }
  }

  const createCustomerResponse = await runQboRequest({
    config,
    accessToken: connection.accessToken,
    realmId: connection.realmId,
    method: 'POST',
    path: '/customer',
    body: {
      DisplayName: displayName,
      PrimaryEmailAddr: tenant.email ? { Address: String(tenant.email) } : undefined,
      PrimaryPhone: tenant.phone ? { FreeFormNumber: String(tenant.phone) } : undefined,
      Notes: `Synced from StorageFacilityCreator tenant ${tenantId}`,
    },
  });

  const customer = createCustomerResponse.Customer as Record<string, unknown> | undefined;
  const customerId = String(customer?.Id || '');
  if (!customerId) {
    throw new functions.https.HttpsError('internal', 'QuickBooks customer sync failed');
  }

  await tenantRef.set(
    {
      quickbooksCustomerId: customerId,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
  return customerId;
}

async function ensureQboServiceItem(
  config: QuickBooksConfig,
  facilityId: string,
  connection: { realmId: string; accessToken: string; ref: FirebaseFirestore.DocumentReference },
): Promise<string> {
  const connectionSnap = await connection.ref.get();
  const defaultItemId = connectionSnap.data()?.defaultItemId as string | undefined;
  if (defaultItemId && defaultItemId.trim()) return defaultItemId;

  const query = encodeURIComponent("select * from Item where Name = 'Storage Rent' maxresults 1");
  const queryResponse = await runQboRequest({
    config,
    accessToken: connection.accessToken,
    realmId: connection.realmId,
    method: 'GET',
    path: `/query?query=${query}`,
  });
  const existingItems = (((queryResponse.QueryResponse as Record<string, unknown> | undefined)?.Item || []) as Array<Record<string, unknown>>);
  if (existingItems.length > 0) {
    const itemId = String(existingItems[0].Id || '');
    if (itemId) {
      await connection.ref.set(
        {
          defaultItemId: itemId,
          updatedAt: admin.firestore.FieldValue.serverTimestamp(),
        },
        { merge: true },
      );
      return itemId;
    }
  }

  const createItemResponse = await runQboRequest({
    config,
    accessToken: connection.accessToken,
    realmId: connection.realmId,
    method: 'POST',
    path: '/item',
    body: {
      Name: `Storage Rent ${facilityId.slice(0, 6)}`,
      Type: 'Service',
      IncomeAccountRef: { value: await getIncomeAccountId(config, connection) },
      Taxable: false,
    },
  });

  const item = createItemResponse.Item as Record<string, unknown> | undefined;
  const itemId = String(item?.Id || '');
  if (!itemId) {
    throw new functions.https.HttpsError('internal', 'QuickBooks item setup failed');
  }
  await connection.ref.set(
    {
      defaultItemId: itemId,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
  return itemId;
}

async function getIncomeAccountId(
  config: QuickBooksConfig,
  connection: { realmId: string; accessToken: string },
): Promise<string> {
  const query = encodeURIComponent("select * from Account where AccountType = 'Income' and Active = true maxresults 1");
  const response = await runQboRequest({
    config,
    accessToken: connection.accessToken,
    realmId: connection.realmId,
    method: 'GET',
    path: `/query?query=${query}`,
  });
  const accounts = (((response.QueryResponse as Record<string, unknown> | undefined)?.Account || []) as Array<Record<string, unknown>>);
  if (accounts.length === 0) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'No active Income account found in QuickBooks. Create one first, then retry sync.',
    );
  }
  const accountId = String(accounts[0].Id || '');
  if (!accountId) {
    throw new functions.https.HttpsError('internal', 'Unable to resolve QuickBooks Income account');
  }
  return accountId;
}

export async function getQuickBooksConnectionStatus(
  data: { facilityId: string },
  context: functions.https.CallableContext,
): Promise<Record<string, unknown>> {
  const facilityId = (data?.facilityId || '').trim();
  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing facilityId');
  }
  await assertFacilityAccountingAccess(context, facilityId);
  const snap = await quickBooksIntegrationRef(facilityId).get();
  if (!snap.exists) {
    return { connected: false };
  }
  const d = snap.data() || {};
  return {
    connected: true,
    realmId: d.realmId || null,
    environment: d.environment || 'sandbox',
    connectedAt: d.connectedAt || null,
    updatedAt: d.updatedAt || null,
    autoSyncEnabled: d.autoSyncEnabled !== false,
    lastSyncAt: d.lastSyncAt || null,
    lastSyncStatus: d.lastSyncStatus || null,
    lastSyncError: d.lastSyncError || null,
  };
}

export async function getQuickBooksConnectUrl(
  data: { facilityId: string },
  context: functions.https.CallableContext,
  config: QuickBooksConfig,
): Promise<Record<string, unknown>> {
  const facilityId = (data?.facilityId || '').trim();
  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing facilityId');
  }
  if (!config.clientId || !config.clientSecret || !config.redirectUri) {
    throw new functions.https.HttpsError('failed-precondition', 'QuickBooks secrets are not configured');
  }
  await assertFacilityAccountingAccess(context, facilityId);

  const state = crypto.randomBytes(24).toString('hex');
  const expiresAt = admin.firestore.Timestamp.fromMillis(Date.now() + (10 * 60 * 1000));
  await quickBooksOAuthStateRef(state).set({
    facilityId,
    uid: context.auth!.uid,
    expiresAt,
    createdAt: admin.firestore.FieldValue.serverTimestamp(),
  });

  const params = new URLSearchParams({
    client_id: config.clientId,
    response_type: 'code',
    scope: 'com.intuit.quickbooks.accounting',
    redirect_uri: config.redirectUri,
    state,
  });

  return {
    authUrl: `${getAuthorizeBase()}?${params.toString()}`,
    state,
    expiresAt,
    environment: config.environment,
  };
}

export async function completeQuickBooksConnect(
  data: { facilityId: string; code: string; realmId: string; state: string },
  context: functions.https.CallableContext,
  config: QuickBooksConfig,
): Promise<Record<string, unknown>> {
  const facilityId = (data?.facilityId || '').trim();
  const code = (data?.code || '').trim();
  const realmId = (data?.realmId || '').trim();
  const state = (data?.state || '').trim();
  if (!facilityId || !code || !realmId || !state) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing facilityId, code, realmId, or state');
  }
  await assertFacilityAccountingAccess(context, facilityId);

  const stateSnap = await quickBooksOAuthStateRef(state).get();
  if (!stateSnap.exists) {
    throw new functions.https.HttpsError('failed-precondition', 'OAuth state not found or expired');
  }
  const stateData = stateSnap.data() || {};
  const stateExpiresAt = extractMillis(stateData.expiresAt);
  if (
    stateData.facilityId !== facilityId ||
    stateData.uid !== context.auth!.uid ||
    !stateExpiresAt ||
    stateExpiresAt < Date.now()
  ) {
    throw new functions.https.HttpsError('failed-precondition', 'Invalid OAuth state');
  }

  const token = await exchangeToken(config, 'authorization_code', { code });
  await quickBooksIntegrationRef(facilityId).set(
    {
      connected: true,
      realmId,
      environment: config.environment,
      accessToken: token.access_token,
      refreshToken: token.refresh_token,
      accessTokenExpiresAt: toTimestampFromNow(token.expires_in || 3600),
      refreshTokenExpiresAt: toTimestampFromNow(token.x_refresh_token_expires_in || (100 * 24 * 3600)),
      tokenType: token.token_type || 'bearer',
      scope: token.scope || '',
      autoSyncEnabled: true,
      connectedByUid: context.auth!.uid,
      connectedAt: admin.firestore.FieldValue.serverTimestamp(),
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      lastSyncAt: null,
      lastSyncStatus: null,
      lastSyncError: null,
    },
    { merge: true },
  );

  await stateSnap.ref.delete();
  return {
    connected: true,
    realmId,
    environment: config.environment,
  };
}

export async function disconnectQuickBooks(
  data: { facilityId: string },
  context: functions.https.CallableContext,
): Promise<Record<string, unknown>> {
  const facilityId = (data?.facilityId || '').trim();
  if (!facilityId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing facilityId');
  }
  await assertFacilityAccountingAccess(context, facilityId);
  await quickBooksIntegrationRef(facilityId).delete();
  return { disconnected: true };
}

async function performInvoiceSync(
  facilityId: string,
  invoiceId: string,
  config: QuickBooksConfig,
): Promise<Record<string, unknown>> {
  const invoiceRef = facilityRef(facilityId).collection('invoices').doc(invoiceId);
  const invoiceSnap = await invoiceRef.get();
  if (!invoiceSnap.exists) {
    throw new functions.https.HttpsError('not-found', 'Invoice not found');
  }
  const invoice = invoiceSnap.data() || {};
  const tenantId = String(invoice.tenantId || '');
  if (!tenantId) {
    throw new functions.https.HttpsError('failed-precondition', 'Invoice missing tenantId');
  }

  const existingQboId = ((invoice.quickbooks as Record<string, unknown> | undefined)?.invoiceId as string | undefined) || '';
  if (existingQboId) {
    return { synced: true, quickbooksInvoiceId: existingQboId, alreadySynced: true };
  }

  const connection = await getValidConnection(facilityId, config);
  const customerId = await ensureQboCustomer(config, facilityId, tenantId, connection);
  const itemId = await ensureQboServiceItem(config, facilityId, connection);

  const total = Number(asNumber(invoice.total).toFixed(2));
  const lineItemsRaw = (invoice.lineItems as Array<Record<string, unknown>> | undefined) || [];
  const lines = lineItemsRaw.length > 0
    ? lineItemsRaw.map((li) => ({
      DetailType: 'SalesItemLineDetail',
      Amount: Number(asNumber(li.amount).toFixed(2)),
      Description: String(li.description || li.name || 'Storage charge'),
      SalesItemLineDetail: {
        ItemRef: { value: itemId },
        Qty: Number(asNumber(li.quantity || 1).toFixed(2)),
      },
    }))
    : [{
      DetailType: 'SalesItemLineDetail',
      Amount: total,
      Description: `Storage invoice ${String(invoice.invoiceNumber || invoiceId)}`,
      SalesItemLineDetail: {
        ItemRef: { value: itemId },
        Qty: 1,
      },
    }];

  const response = await runQboRequest({
    config,
    accessToken: connection.accessToken,
    realmId: connection.realmId,
    method: 'POST',
    path: '/invoice',
    body: {
      CustomerRef: { value: customerId },
      DocNumber: String(invoice.invoiceNumber || invoiceId),
      TxnDate: formatDate(invoice.issueDate),
      DueDate: formatDate(invoice.dueDate),
      PrivateNote: invoice.notes ? String(invoice.notes) : undefined,
      Line: lines,
    },
  });

  const qbInvoice = response.Invoice as Record<string, unknown> | undefined;
  const qbInvoiceId = String(qbInvoice?.Id || '');
  if (!qbInvoiceId) {
    throw new functions.https.HttpsError('internal', 'QuickBooks invoice creation failed');
  }

  await invoiceRef.set(
    {
      quickbooks: {
        invoiceId: qbInvoiceId,
        syncedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  await connection.ref.set(
    {
      lastSyncAt: admin.firestore.FieldValue.serverTimestamp(),
      lastSyncStatus: 'ok',
      lastSyncError: null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  return { synced: true, quickbooksInvoiceId: qbInvoiceId };
}

async function performPaymentSync(
  facilityId: string,
  paymentId: string,
  config: QuickBooksConfig,
  invoiceIdOverride?: string,
): Promise<Record<string, unknown>> {
  const paymentRef = facilityRef(facilityId).collection('payments').doc(paymentId);
  const paymentSnap = await paymentRef.get();
  if (!paymentSnap.exists) {
    throw new functions.https.HttpsError('not-found', 'Payment not found');
  }
  const payment = paymentSnap.data() || {};
  const existingQboPaymentId = ((payment.quickbooks as Record<string, unknown> | undefined)?.paymentId as string | undefined) || '';
  if (existingQboPaymentId) {
    return { synced: true, quickbooksPaymentId: existingQboPaymentId, alreadySynced: true };
  }

  const status = String(payment.status || '').toLowerCase();
  if (status !== 'paid' && status !== 'completed') {
    throw new functions.https.HttpsError('failed-precondition', 'Payment must be paid/completed before sync');
  }

  const tenantId = String(payment.tenantId || '');
  if (!tenantId) {
    throw new functions.https.HttpsError('failed-precondition', 'Payment missing tenantId');
  }
  const amount = Number(asNumber(payment.amount).toFixed(2));
  if (amount <= 0) {
    throw new functions.https.HttpsError('failed-precondition', 'Payment amount must be > 0');
  }

  let qboInvoiceId: string | null = null;
  const invoiceIdFromInput = (invoiceIdOverride || '').trim();
  const invoiceIdFromMetadata = String((payment.metadata as Record<string, unknown> | undefined)?.invoiceId || '');
  const linkedInvoiceId = invoiceIdFromInput || invoiceIdFromMetadata || String(payment.invoiceId || '');
  if (linkedInvoiceId) {
    const invoiceSnap = await facilityRef(facilityId).collection('invoices').doc(linkedInvoiceId).get();
    if (invoiceSnap.exists) {
      const invoiceData = invoiceSnap.data() || {};
      qboInvoiceId = String((invoiceData.quickbooks as Record<string, unknown> | undefined)?.invoiceId || '');
      if (!qboInvoiceId) {
        const syncResult = await performInvoiceSync(facilityId, linkedInvoiceId, config);
        qboInvoiceId = String(syncResult.quickbooksInvoiceId || '');
      }
    }
  }

  const connection = await getValidConnection(facilityId, config);
  const customerId = await ensureQboCustomer(config, facilityId, tenantId, connection);
  const paymentPayload: Record<string, unknown> = {
    CustomerRef: { value: customerId },
    TotalAmt: amount,
    TxnDate: formatDate(payment.paidDate || payment.paidAt || payment.createdAt),
    PrivateNote: `SFC payment ${paymentId}`,
  };
  if (qboInvoiceId) {
    paymentPayload.Line = [{
      Amount: amount,
      LinkedTxn: [{ TxnId: qboInvoiceId, TxnType: 'Invoice' }],
    }];
  }

  const response = await runQboRequest({
    config,
    accessToken: connection.accessToken,
    realmId: connection.realmId,
    method: 'POST',
    path: '/payment',
    body: paymentPayload,
  });

  const qbPayment = response.Payment as Record<string, unknown> | undefined;
  const qbPaymentId = String(qbPayment?.Id || '');
  if (!qbPaymentId) {
    throw new functions.https.HttpsError('internal', 'QuickBooks payment creation failed');
  }

  await paymentRef.set(
    {
      quickbooks: {
        paymentId: qbPaymentId,
        syncedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  await connection.ref.set(
    {
      lastSyncAt: admin.firestore.FieldValue.serverTimestamp(),
      lastSyncStatus: 'ok',
      lastSyncError: null,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );

  return { synced: true, quickbooksPaymentId: qbPaymentId, quickbooksInvoiceId: qboInvoiceId };
}

export async function syncInvoiceToQuickBooks(
  data: { facilityId: string; invoiceId: string },
  context: functions.https.CallableContext,
  config: QuickBooksConfig,
): Promise<Record<string, unknown>> {
  const facilityId = (data?.facilityId || '').trim();
  const invoiceId = (data?.invoiceId || '').trim();
  if (!facilityId || !invoiceId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing facilityId or invoiceId');
  }
  await assertFacilityAccountingAccess(context, facilityId);
  return performInvoiceSync(facilityId, invoiceId, config);
}

export async function syncPaymentToQuickBooks(
  data: { facilityId: string; paymentId: string; invoiceId?: string },
  context: functions.https.CallableContext,
  config: QuickBooksConfig,
): Promise<Record<string, unknown>> {
  const facilityId = (data?.facilityId || '').trim();
  const paymentId = (data?.paymentId || '').trim();
  if (!facilityId || !paymentId) {
    throw new functions.https.HttpsError('invalid-argument', 'Missing facilityId or paymentId');
  }
  await assertFacilityAccountingAccess(context, facilityId);
  return performPaymentSync(facilityId, paymentId, config, data.invoiceId);
}

export async function setQuickBooksAutoSync(
  data: { facilityId: string; enabled: boolean },
  context: functions.https.CallableContext,
): Promise<Record<string, unknown>> {
  const facilityId = (data?.facilityId || '').trim();
  if (!facilityId || typeof data.enabled !== 'boolean') {
    throw new functions.https.HttpsError('invalid-argument', 'Missing facilityId or enabled');
  }
  await assertFacilityAccountingAccess(context, facilityId);
  await quickBooksIntegrationRef(facilityId).set(
    {
      autoSyncEnabled: data.enabled,
      updatedAt: admin.firestore.FieldValue.serverTimestamp(),
    },
    { merge: true },
  );
  return { autoSyncEnabled: data.enabled };
}

async function canAutoSyncFacility(facilityId: string): Promise<boolean> {
  const snap = await quickBooksIntegrationRef(facilityId).get();
  if (!snap.exists) return false;
  const d = snap.data() || {};
  return d.connected === true && d.autoSyncEnabled !== false;
}

export async function autoSyncInvoiceIfEligible(
  facilityId: string,
  invoiceId: string,
  config: QuickBooksConfig,
): Promise<void> {
  if (!facilityId || !invoiceId) return;
  if (!(await canAutoSyncFacility(facilityId))) return;
  try {
    await performInvoiceSync(facilityId, invoiceId, config);
  } catch (error: any) {
    await quickBooksIntegrationRef(facilityId).set(
      {
        lastSyncAt: admin.firestore.FieldValue.serverTimestamp(),
        lastSyncStatus: 'error',
        lastSyncError: error?.message || 'Auto-sync invoice failed',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    functions.logger.error('QuickBooks auto-sync invoice failed', {
      facilityId,
      invoiceId,
      error: error?.message,
    });
  }
}

export async function autoSyncPaymentIfEligible(
  facilityId: string,
  paymentId: string,
  config: QuickBooksConfig,
): Promise<void> {
  if (!facilityId || !paymentId) return;
  if (!(await canAutoSyncFacility(facilityId))) return;
  try {
    await performPaymentSync(facilityId, paymentId, config);
  } catch (error: any) {
    await quickBooksIntegrationRef(facilityId).set(
      {
        lastSyncAt: admin.firestore.FieldValue.serverTimestamp(),
        lastSyncStatus: 'error',
        lastSyncError: error?.message || 'Auto-sync payment failed',
        updatedAt: admin.firestore.FieldValue.serverTimestamp(),
      },
      { merge: true },
    );
    functions.logger.error('QuickBooks auto-sync payment failed', {
      facilityId,
      paymentId,
      error: error?.message,
    });
  }
}
