/**
 * A renter who pays for an online move-in is moved in whether or not they
 * come back from Stripe.
 *
 * The renter's browser was the only thing that completed a move-in: it filled
 * in the form after paying and called completePublicMoveIn. A renter who paid
 * and closed the tab had paid for no unit, and the owner found out only from
 * Stripe. Checkout now saves the form, the Stripe webhook records the paid
 * Checkout Session, and completePaidCheckout completes the move-in from that
 * record with the code the browser uses. Browser and webhook can arrive in
 * either order, or together, and Stripe can deliver the event again.
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import { Timestamp } from 'firebase-admin/firestore';
import firebaseFunctionsTest from 'firebase-functions-test';
import { paidPublicMoveInCheckoutFromSession } from '@sfc/functions-shared';
import { computePublicMoveInCharges } from '../moveInCharges';
import { PAID_CHECKOUT_RETRY_MS } from '../paidCheckoutCompletion';
import { SAVED_MOVE_IN_FORM_DAYS } from '../moveInForm';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';
import { MOVE_IN_FORM } from './support/moveInForm';

const testEnv = firebaseFunctionsTest({ projectId: 'in-memory-test' });
const callableContext = { app: { appId: 'test-app-check' } };

const FACILITY = 'fac-paid';
const CONNECT_ACCOUNT = 'acct_paid';
const MINUTE = 60 * 1000;
const NOT_ACTIVE = 'Reservation is not active';

const FACILITY_DATA = {
  name: 'Paid Storage',
  ownerUid: 'owner-1',
  stripeConnectAccountId: CONNECT_ACCOUNT,
  stripeConnectOnboardingComplete: true,
};

type Rental = { reservationId: string; unitId: string; unitNumber: string; token: string };

const RENTAL: Rental = {
  reservationId: 'res-paid',
  unitId: 'unit-paid',
  unitNumber: 'P1',
  token: 'paid-move-in-token-0123456789',
};

/** A second reservation, at the same facility, on another unit. */
const OTHER_RENTAL: Rental = {
  reservationId: 'res-paid-other',
  unitId: 'unit-paid-other',
  unitNumber: 'P2',
  token: 'paid-move-in-token-other-0123456789',
};

const unitPath = (r: Rental) => `facilities/${FACILITY}/units/${r.unitId}`;
const reservationPath = (r: Rental) => `publicReservations/${r.reservationId}`;
const formPath = (r: Rental) => `publicMoveInForms/${r.reservationId}`;
const checkoutPath = (sessionId: string) => `publicMoveInCheckouts/${sessionId}`;
const alertPath = (sessionId: string) => `facilities/${FACILITY}/Notifications/paidMoveIn_${sessionId}`;

type StubPaymentIntent = { amount_received: number; status: string; metadata: Record<string, string> };

type Harness = {
  inMemory: InMemoryFirestore;
  paymentIntents: Record<string, StubPaymentIntent>;
  /** Stripe calls made, by method. */
  stripeCalls: string[];
  /** Set to make every PaymentIntent retrieval fail as Stripe being unreachable would. */
  stripeDown: boolean;
  emails: Array<{ to: string; facilityId: string }>;
  checkout: (rental?: Rental, overrides?: Record<string, unknown>) => Promise<unknown>;
  complete: (data: Record<string, unknown>, rental?: Rental) => Promise<Record<string, any>>;
  open: (rental?: Rental) => Promise<Record<string, any>>;
  cancel: (rental?: Rental) => Promise<unknown>;
  /** The trigger's run for a recorded checkout, [minutesLater] after the webhook recorded it. */
  webhook: (sessionId: string, minutesLater?: number) => Promise<string | null>;
};

function load(inMemory: InMemoryFirestore): Harness {
  installInMemoryFirestore(inMemory);
  const harness = {
    inMemory,
    paymentIntents: {} as Record<string, StubPaymentIntent>,
    stripeCalls: [] as string[],
    stripeDown: false,
    emails: [] as Array<{ to: string; facilityId: string }>,
  } as Harness;
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const shared = require('@sfc/functions-shared') as typeof import('@sfc/functions-shared');
  Object.defineProperty(shared, 'getStripeClient', {
    configurable: true,
    writable: true,
    value: () =>
      ({
        checkout: {
          sessions: {
            create: async () => {
              harness.stripeCalls.push('checkout.sessions.create');
              return { id: 'cs_created', url: 'https://checkout.example/cs_created' };
            },
          },
        },
        paymentIntents: {
          retrieve: async (id: string, options: { stripeAccount?: string }) => {
            harness.stripeCalls.push('paymentIntents.retrieve');
            if (harness.stripeDown) throw Object.assign(new Error('connect ECONNRESET'), { type: 'StripeConnectionError' });
            const paymentIntent = harness.paymentIntents[id];
            if (!paymentIntent || options?.stripeAccount !== CONNECT_ACCOUNT) {
              throw Object.assign(new Error(`No such payment_intent: '${id}'`), { type: 'StripeInvalidRequestError' });
            }
            return { id, ...paymentIntent };
          },
        },
      }) as unknown as ReturnType<typeof shared.getStripeClient>,
  });
  // The gated sender every tenant email goes through; recorded, never sent.
  Object.defineProperty(shared, 'sendFacilityEmailWithCompliance', {
    configurable: true,
    writable: true,
    value: async (msg: { to: string }, _html: string, _text: string, context: { facilityId: string }) => {
      harness.emails.push({ to: msg.to, facilityId: context.facilityId });
    },
  });
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const moveIn = require('../publicMoveIn') as typeof import('../publicMoveIn');
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const paid = require('../paidCheckoutCompletion') as typeof import('../paidCheckoutCompletion');

  harness.checkout = (rental = RENTAL, overrides = {}) =>
    testEnv.wrap(moveIn.createPublicMoveInCheckout)(
      {
        reservationId: rental.reservationId,
        token: rental.token,
        amount: amountDueCents(inMemory, rental) / 100,
        moveInForm: MOVE_IN_FORM,
        ...overrides,
      },
      callableContext,
    );
  harness.complete = (data, rental = RENTAL) =>
    testEnv.wrap(moveIn.completePublicMoveIn)(
      { reservationId: rental.reservationId, token: rental.token, ...data },
      callableContext,
    ) as Promise<Record<string, any>>;
  harness.open = (rental = RENTAL) =>
    testEnv.wrap(moveIn.getPublicReservationByToken)({ token: rental.token }, callableContext) as Promise<
      Record<string, any>
    >;
  harness.cancel = (rental = RENTAL) =>
    testEnv.wrap(moveIn.transitionPublicReservationStatus)(
      { reservationId: rental.reservationId, moveInToken: rental.token, status: 'cancelled' },
      callableContext,
    );
  harness.webhook = (sessionId, minutesLater = 0) => {
    const receivedAt = new Date();
    return paid.completePaidCheckout(sessionId, receivedAt, new Date(receivedAt.getTime() + minutesLater * MINUTE));
  };
  return harness;
}

function seedRental(inMemory: InMemoryFirestore, rental: Rental) {
  inMemory.seed(unitPath(rental), {
    status: 'available',
    unitNumber: rental.unitNumber,
    unitType: 'standard',
    monthlyRate: 100,
  });
  const expiresAt = Timestamp.fromDate(new Date(Date.now() + 10 * MINUTE));
  inMemory.seed(reservationPath(rental), {
    facilityId: FACILITY,
    unitId: rental.unitId,
    unitNumber: rental.unitNumber,
    status: 'pending',
    moveInToken: rental.token,
    moveInDate: Timestamp.fromDate(new Date(2026, 8, 25)),
    reservedAt: Timestamp.fromDate(new Date(Date.now() - 5 * MINUTE)),
    expiresAt,
    email: MOVE_IN_FORM.email,
    name: MOVE_IN_FORM.name,
    phone: MOVE_IN_FORM.phone,
    metadata: {},
  });
  inMemory.seed(`facilities/${FACILITY}/mapEngine/activeHolds/items/${rental.unitId}`, {
    facilityId: FACILITY,
    unitId: rental.unitId,
    reservationId: rental.reservationId,
    status: 'pending',
    expiresAt,
  });
}

function amountDueCents(inMemory: InMemoryFirestore, rental: Rental): number {
  const reservation = inMemory.read(reservationPath(rental)) as Record<string, any>;
  return computePublicMoveInCharges({
    reservation,
    unitData: inMemory.read(unitPath(rental)),
    facilityData: FACILITY_DATA,
    moveInDate: (reservation.moveInDate as Timestamp).toDate(),
  }).totalCents;
}

/** A facility taking card payments, with [rental] held, and the loaded functions. */
function setUp(rentals: Rental[] = [RENTAL]): Harness {
  const inMemory = new InMemoryFirestore();
  inMemory.seed(`facilities/${FACILITY}`, FACILITY_DATA);
  for (const rental of rentals) seedRental(inMemory, rental);
  return load(inMemory);
}

/** Stripe holds a paid PaymentIntent for [rental], tagged by checkout as it tags them. */
function pay(h: Harness, paymentIntentId: string, rental: Rental = RENTAL, metadataFor: Rental = rental) {
  h.paymentIntents[paymentIntentId] = {
    amount_received: amountDueCents(h.inMemory, rental),
    status: 'succeeded',
    metadata: { type: 'public_move_in', reservationId: metadataFor.reservationId, facilityId: FACILITY },
  };
}

/**
 * What the webhook writes for a completed Checkout Session: the record is
 * built by the same shared function functions-integrations uses.
 */
function recordPaidCheckout(
  h: Harness,
  sessionId: string,
  paymentIntentId: string,
  rental: Rental = RENTAL,
  connectedAccountId = CONNECT_ACCOUNT,
) {
  const result = paidPublicMoveInCheckoutFromSession(
    {
      id: sessionId,
      metadata: {
        type: 'public_move_in',
        reservationId: rental.reservationId,
        moveInToken: rental.token,
        facilityId: FACILITY,
      },
      payment_status: 'paid',
      payment_intent: paymentIntentId,
      amount_total: amountDueCents(h.inMemory, rental),
      currency: 'usd',
      livemode: true,
    } as never,
    connectedAccountId,
    `evt_${sessionId}`,
  );
  assert.ok('record' in result);
  h.inMemory.seed(checkoutPath(sessionId), { ...result.record, receivedAt: Timestamp.now() });
}

function tenants(h: Harness): Array<Record<string, any>> {
  return h.inMemory
    .listCollection(`facilities/${FACILITY}/tenants`)
    .map((path) => h.inMemory.read(path) as Record<string, any>);
}

function paymentEntries(h: Harness, paymentIntentId: string) {
  return h.inMemory
    .listCollection(`facilities/${FACILITY}/ledgers`)
    .map((path) => h.inMemory.read(path) as Record<string, any>)
    .filter((entry) => entry.type === 'payment' && entry.referenceId === paymentIntentId);
}

function alerts(h: Harness): Array<Record<string, any>> {
  return h.inMemory
    .listCollection(`facilities/${FACILITY}/Notifications`)
    .map((path) => h.inMemory.read(path) as Record<string, any>);
}

/** [rental] was not moved into: no tenant, its unit and reservation as they were. */
function assertNotMovedIn(h: Harness, rental: Rental = RENTAL, unitStatus = 'available') {
  assert.deepEqual(
    tenants(h).filter((t) => t.unitNumber === rental.unitNumber),
    [],
    `no tenant for unit ${rental.unitNumber}`,
  );
  assert.equal(h.inMemory.read(unitPath(rental))?.status, unitStatus);
  assert.equal(h.inMemory.read(reservationPath(rental))?.status, 'pending');
}

/** The owner's alert for [sessionId]: the in-app banner type, naming the payment to refund. */
function assertOwnerAlerted(h: Harness, sessionId: string, paymentIntentId: string, problem: string) {
  const alert = h.inMemory.read(alertPath(sessionId));
  assert.ok(alert, 'the owner was alerted');
  assert.equal(alert.type, 'ONLINE_MOVE_IN_REVIEW');
  assert.equal(alert.readAt, null);
  assert.equal((alert.metadata as Record<string, unknown>).problem, problem);
  assert.equal((alert.metadata as Record<string, unknown>).paymentIntentId, paymentIntentId);
  assert.match(String(alert.message), new RegExp(`Rita Renter paid \\$\\d+\\.\\d\\d online for unit ${RENTAL.unitNumber}`));
  assert.ok(String(alert.message).includes(paymentIntentId), 'the alert names the payment');
}

// Checkout saves the form

test('checkout saves the move-in form where no client can read it, before Stripe is called', async () => {
  const h = setUp();

  await h.checkout();

  assert.deepEqual(h.stripeCalls, ['checkout.sessions.create']);
  const saved = h.inMemory.read(formPath(RENTAL)) as Record<string, any>;
  assert.equal(saved.facilityId, FACILITY);
  assert.equal(saved.form.governmentIdNumber, MOVE_IN_FORM.governmentIdNumber);
  assert.equal(saved.form.signaturePngBase64, MOVE_IN_FORM.signaturePngBase64);
  // Kept off the reservation, which facility staff can list.
  const reservationJson = JSON.stringify(h.inMemory.read(reservationPath(RENTAL)));
  assert.equal(reservationJson.includes(MOVE_IN_FORM.governmentIdNumber), false);
  assert.equal(reservationJson.includes(MOVE_IN_FORM.signaturePngBase64), false);
  // Expires on its own if nothing completes or cancels the reservation.
  const expireInDays = ((saved.expireAt as Timestamp).toMillis() - Date.now()) / (24 * 60 * MINUTE);
  assert.ok(Math.abs(expireInDays - SAVED_MOVE_IN_FORM_DAYS) < 0.01, `expires in ${expireInDays} days`);
});

for (const [why, overrides] of [
  ['without a form', { moveInForm: undefined }],
  ['with a form missing its signature', { moveInForm: { ...MOVE_IN_FORM, signaturePngBase64: '' } }],
] as Array<[string, Record<string, unknown>]>) {
  test(`checkout ${why} is refused, and Stripe is not called`, async () => {
    const h = setUp();

    await assert.rejects(() => h.checkout(RENTAL, overrides));

    assert.deepEqual(h.stripeCalls, []);
    assert.equal(h.inMemory.read(formPath(RENTAL)), undefined);
    assert.equal(h.inMemory.read(reservationPath(RENTAL))?.checkoutUpdatedAt, undefined);
  });
}

test('cancelling the reservation deletes its saved form', async () => {
  const h = setUp();
  await h.checkout();

  await h.cancel();

  assert.equal(h.inMemory.read(formPath(RENTAL)), undefined);
});

// The webhook completes the move-in

test('a renter who pays and never comes back is moved in from the webhook, once', async () => {
  const h = setUp();
  await h.checkout();
  pay(h, 'pi_1');
  recordPaidCheckout(h, 'cs_1', 'pi_1');

  const status = await h.webhook('cs_1');

  assert.equal(status, 'completed');
  const [tenant, ...more] = tenants(h);
  assert.equal(more.length, 0);
  // Everything the renter typed before paying.
  assert.equal(tenant.name, MOVE_IN_FORM.name);
  assert.equal(tenant.governmentIdNumber, MOVE_IN_FORM.governmentIdNumber);
  assert.equal(tenant.addresses[0].street1, MOVE_IN_FORM.address);
  assert.equal(tenant.emergencyContacts[0].name, MOVE_IN_FORM.emergencyContactName);
  const contract = h.inMemory.read(h.inMemory.listCollection(`facilities/${FACILITY}/contracts`)[0]) as Record<string, any>;
  assert.equal(contract.customFields.publicMoveInSignature.signaturePngBase64, MOVE_IN_FORM.signaturePngBase64);

  const unit = h.inMemory.read(unitPath(RENTAL));
  assert.equal(unit?.status, 'occupied');
  const reservation = h.inMemory.read(reservationPath(RENTAL));
  assert.equal(reservation?.status, 'completed');
  assert.equal(reservation?.completedVia, 'paidCheckout');
  assert.equal(reservation?.paymentIntentId, 'pi_1');
  assert.equal(h.inMemory.read('publicMoveInPayments/pi_1')?.reservationId, RENTAL.reservationId);
  assert.equal(paymentEntries(h, 'pi_1').length, 1);
  // The government ID and signature are not kept a second time.
  assert.equal(h.inMemory.read(formPath(RENTAL)), undefined);
  const record = h.inMemory.read(checkoutPath('cs_1'));
  assert.equal(record?.status, 'completed');
  assert.equal(record?.tenantId, unit?.tenantId);
  assert.deepEqual(alerts(h), []);
});

test('the renter\'s confirmation email from the webhook goes through the gated sender', async () => {
  const h = setUp();
  await h.checkout();
  pay(h, 'pi_1');
  recordPaidCheckout(h, 'cs_1', 'pi_1');
  const previous = process.env.SENDGRID_SENDER_EMAIL;
  process.env.SENDGRID_SENDER_EMAIL = 'noreply@example.com';
  try {
    await h.webhook('cs_1');
  } finally {
    if (previous === undefined) delete process.env.SENDGRID_SENDER_EMAIL;
    else process.env.SENDGRID_SENDER_EMAIL = previous;
  }

  // sendFacilityEmailWithCompliance drops it unless customer email is switched on.
  assert.deepEqual(h.emails, [{ to: MOVE_IN_FORM.email, facilityId: FACILITY }]);
});

test('a redelivered webhook changes nothing', async () => {
  const h = setUp();
  await h.checkout();
  pay(h, 'pi_1');
  recordPaidCheckout(h, 'cs_1', 'pi_1');
  await h.webhook('cs_1');
  const stripeCallsAfterFirst = h.stripeCalls.length;

  assert.equal(await h.webhook('cs_1'), 'completed');
  assert.equal(await h.webhook('cs_1'), 'completed');

  assert.equal(tenants(h).length, 1);
  assert.equal(paymentEntries(h, 'pi_1').length, 1);
  assert.equal(h.stripeCalls.length, stripeCallsAfterFirst, 'a settled checkout is not looked at again');
  // Not mistaken for a payment that could not be used.
  assert.equal(h.inMemory.read(checkoutPath('cs_1'))?.status, 'completed');
  assert.deepEqual(alerts(h), []);
});

test('a webhook run again before it recorded its outcome finds the move-in done, and alerts no one', async () => {
  const h = setUp();
  await h.checkout();
  pay(h, 'pi_1');
  recordPaidCheckout(h, 'cs_1', 'pi_1');
  await h.webhook('cs_1');
  // As if the run had stopped between moving the renter in and recording it.
  h.inMemory.seed(checkoutPath('cs_1'), { ...h.inMemory.read(checkoutPath('cs_1')), status: 'paid' });

  assert.equal(await h.webhook('cs_1'), 'alreadyCompleted');

  assert.equal(tenants(h).length, 1);
  assert.equal(paymentEntries(h, 'pi_1').length, 1);
  assert.deepEqual(alerts(h), []);
});

// Webhook and browser

test('webhook first: the renter coming back is told the move-in is done, and no second tenancy is made', async () => {
  const h = setUp();
  await h.checkout();
  pay(h, 'pi_1');
  recordPaidCheckout(h, 'cs_1', 'pi_1');
  await h.webhook('cs_1');

  const opened = await h.open();
  const fromSavedForm = await h.complete({ useSavedForm: true, paymentIntentId: 'pi_1' });
  // A page loaded before this change sends the whole form again.
  const fromOldPage = await h.complete({ ...MOVE_IN_FORM, paymentIntentId: 'pi_1' });

  assert.equal(opened.found, true);
  assert.equal(opened.reservation.status, 'completed');
  assert.deepEqual(fromSavedForm, { success: true, alreadyCompleted: true, reservationId: RENTAL.reservationId });
  assert.deepEqual(fromOldPage, { success: true, alreadyCompleted: true, reservationId: RENTAL.reservationId });
  assert.equal(tenants(h).length, 1);
  assert.equal(paymentEntries(h, 'pi_1').length, 1);
});

test('browser first: the webhook finds the move-in done and changes nothing', async () => {
  const h = setUp();
  await h.checkout();
  pay(h, 'pi_1');
  recordPaidCheckout(h, 'cs_1', 'pi_1');

  const result = await h.complete({ useSavedForm: true, paymentIntentId: 'pi_1' });
  const status = await h.webhook('cs_1');

  assert.equal(result.success, true);
  assert.ok(result.tenantId);
  assert.equal(h.inMemory.read(reservationPath(RENTAL))?.completedVia, 'renter');
  assert.equal(status, 'alreadyCompleted');
  assert.equal(tenants(h).length, 1);
  assert.equal(paymentEntries(h, 'pi_1').length, 1);
  assert.equal(h.inMemory.read(checkoutPath('cs_1'))?.tenantId, result.tenantId);
  assert.deepEqual(alerts(h), []);
});

test('browser and webhook at the same moment make one tenancy', async () => {
  const h = setUp();
  await h.checkout();
  pay(h, 'pi_1');
  recordPaidCheckout(h, 'cs_1', 'pi_1');

  // Both are past every check outside the transaction before either writes.
  const [browser, webhook] = await Promise.all([
    h.complete({ useSavedForm: true, paymentIntentId: 'pi_1' }),
    h.webhook('cs_1'),
  ]);

  assert.equal(browser.success, true);
  assert.ok(['completed', 'alreadyCompleted'].includes(String(webhook)));
  assert.equal(browser.alreadyCompleted === true, webhook === 'completed');
  assert.equal(tenants(h).length, 1);
  assert.equal(paymentEntries(h, 'pi_1').length, 1);
  assert.deepEqual(alerts(h), []);
});

// Payments that cannot complete the move-in

test('a payment made for another reservation is refused, and the owner is told', async () => {
  const h = setUp([RENTAL, OTHER_RENTAL]);
  await h.checkout();
  // Tagged for the other reservation, recorded against this one.
  pay(h, 'pi_other', RENTAL, OTHER_RENTAL);
  recordPaidCheckout(h, 'cs_1', 'pi_other');

  const status = await h.webhook('cs_1');

  assert.equal(status, 'refused');
  assertNotMovedIn(h);
  assertNotMovedIn(h, OTHER_RENTAL);
  assert.equal(h.inMemory.read('publicMoveInPayments/pi_other'), undefined);
  assert.equal(
    h.inMemory.read(checkoutPath('cs_1'))?.refusal,
    'This payment was made for a different reservation. Contact the facility.',
  );
  assertOwnerAlerted(h, 'cs_1', 'pi_other', 'refused');
});

test('a payment that already completed another move-in is refused, and the owner is told', async () => {
  const h = setUp();
  await h.checkout();
  // Names no reservation, so only its record of use can refuse it.
  pay(h, 'pi_used');
  h.paymentIntents.pi_used.metadata = {};
  h.inMemory.seed('publicMoveInPayments/pi_used', {
    paymentIntentId: 'pi_used',
    facilityId: FACILITY,
    reservationId: 'res-earlier',
    tenantId: 'tenant-earlier',
  });
  recordPaidCheckout(h, 'cs_1', 'pi_used');

  const status = await h.webhook('cs_1');

  assert.equal(status, 'refused');
  assertNotMovedIn(h);
  assert.equal(h.inMemory.read('publicMoveInPayments/pi_used')?.reservationId, 'res-earlier');
  assertOwnerAlerted(h, 'cs_1', 'pi_used', 'refused');
});

test('a unit rented to someone else meanwhile gets no tenancy, and the owner is told to refund', async () => {
  const h = setUp();
  await h.checkout();
  pay(h, 'pi_1');
  recordPaidCheckout(h, 'cs_1', 'pi_1');
  // Rented at the desk while the renter was on Stripe's page.
  h.inMemory.seed(unitPath(RENTAL), {
    ...h.inMemory.read(unitPath(RENTAL)),
    status: 'occupied',
    tenantId: 'tenant-walk-in',
    tenantName: 'Walk In',
  });

  const status = await h.webhook('cs_1');
  // Retried, or delivered again: still one alert.
  await h.webhook('cs_1');

  assert.equal(status, 'refused');
  assertNotMovedIn(h, RENTAL, 'occupied');
  assert.equal(h.inMemory.read(unitPath(RENTAL))?.tenantId, 'tenant-walk-in');
  assert.equal(h.inMemory.read(checkoutPath('cs_1'))?.refusal, 'Unit is no longer available');
  assertOwnerAlerted(h, 'cs_1', 'pi_1', 'refused');
  assert.match(String(h.inMemory.read(alertPath('cs_1'))?.message), /Refund the payment in Stripe/);
  assert.equal(alerts(h).length, 1);
});

test('a second payment for a reservation already moved in is flagged for refund', async () => {
  const h = setUp();
  await h.checkout();
  pay(h, 'pi_1');
  pay(h, 'pi_2');
  // The renter opened checkout twice and paid on both pages.
  recordPaidCheckout(h, 'cs_1', 'pi_1');
  recordPaidCheckout(h, 'cs_2', 'pi_2');

  assert.equal(await h.webhook('cs_1'), 'completed');
  assert.equal(await h.webhook('cs_2'), 'refused');

  assert.equal(tenants(h).length, 1);
  assert.equal(paymentEntries(h, 'pi_2').length, 0);
  assert.equal(
    h.inMemory.read(checkoutPath('cs_2'))?.refusal,
    'The reservation was already completed with another payment',
  );
  assertOwnerAlerted(h, 'cs_2', 'pi_2', 'refused');
  assert.equal(h.inMemory.read(alertPath('cs_1')), undefined);
});

test('a payment on another Stripe account is refused before Stripe is asked about it', async () => {
  const h = setUp();
  await h.checkout();
  pay(h, 'pi_1');
  recordPaidCheckout(h, 'cs_1', 'pi_1', RENTAL, 'acct_someone_else');
  h.stripeCalls.length = 0;

  assert.equal(await h.webhook('cs_1'), 'refused');

  assert.deepEqual(h.stripeCalls, []);
  assertNotMovedIn(h);
  assertOwnerAlerted(h, 'cs_1', 'pi_1', 'refused');
});

test('a paid reservation the renter cancelled is refused, and the owner is told', async () => {
  const h = setUp();
  await h.checkout();
  pay(h, 'pi_1');
  recordPaidCheckout(h, 'cs_1', 'pi_1');
  await h.cancel();

  assert.equal(await h.webhook('cs_1'), 'refused');

  assert.equal(tenants(h).length, 0);
  assert.equal(h.inMemory.read(checkoutPath('cs_1'))?.refusal, NOT_ACTIVE);
  assertOwnerAlerted(h, 'cs_1', 'pi_1', 'refused');
});

// No saved form, and failures

test('with no saved form the owner is told, and the renter can still finish from the page', async () => {
  const h = setUp();
  // Checkout created before forms were saved: the session was paid, no form stored.
  await h.checkout();
  h.inMemory.getStore().delete(formPath(RENTAL));
  pay(h, 'pi_1');
  recordPaidCheckout(h, 'cs_1', 'pi_1');

  assert.equal(await h.webhook('cs_1'), 'awaitingForm');
  assertNotMovedIn(h);
  assertOwnerAlerted(h, 'cs_1', 'pi_1', 'formNotSaved');

  // Back from Stripe, the page is told the form was not saved, and sends it.
  await assert.rejects(
    () => h.complete({ useSavedForm: true, paymentIntentId: 'pi_1' }),
    (err: unknown) => {
      const e = err as { code?: string; details?: { reason?: string } };
      assert.equal(e.code, 'failed-precondition');
      assert.equal(e.details?.reason, 'moveInFormNotSaved');
      return true;
    },
  );
  const result = await h.complete({ ...MOVE_IN_FORM, paymentIntentId: 'pi_1' });
  assert.equal(result.success, true);
  assert.equal(tenants(h).length, 1);
});

test('a failure that may pass is retried, and after an hour the owner is told', async () => {
  const h = setUp();
  await h.checkout();
  pay(h, 'pi_1');
  recordPaidCheckout(h, 'cs_1', 'pi_1');
  h.stripeDown = true;

  // Thrown, so the function's failure policy runs it again.
  await assert.rejects(() => h.webhook('cs_1', 5));
  assert.equal(h.inMemory.read(checkoutPath('cs_1'))?.status, 'paid');
  assert.deepEqual(alerts(h), []);

  assert.equal(await h.webhook('cs_1', PAID_CHECKOUT_RETRY_MS / MINUTE + 1), 'failed');
  assertNotMovedIn(h);
  assertOwnerAlerted(h, 'cs_1', 'pi_1', 'failed');
});

test('a retried run completes the move-in once Stripe answers again', async () => {
  const h = setUp();
  await h.checkout();
  pay(h, 'pi_1');
  recordPaidCheckout(h, 'cs_1', 'pi_1');
  h.stripeDown = true;
  await assert.rejects(() => h.webhook('cs_1', 1));

  h.stripeDown = false;
  assert.equal(await h.webhook('cs_1', 2), 'completed');

  assert.equal(tenants(h).length, 1);
  assert.deepEqual(alerts(h), []);
});

// The page reopened after a completed move-in

test('a completed reservation opens as completed, without being expired or showing its details', async () => {
  const h = setUp();
  await h.checkout();
  pay(h, 'pi_1');
  recordPaidCheckout(h, 'cs_1', 'pi_1');
  await h.webhook('cs_1');
  // Long after its hold ran out.
  h.inMemory.seed(reservationPath(RENTAL), {
    ...h.inMemory.read(reservationPath(RENTAL)),
    expiresAt: Timestamp.fromDate(new Date(Date.now() - 48 * 60 * MINUTE)),
  });

  const opened = await h.open();

  assert.equal(opened.found, true);
  assert.equal(opened.reservation.status, 'completed');
  assert.equal(opened.reservation.unitNumber, RENTAL.unitNumber);
  assert.equal(opened.reservation.moveInToken, undefined);
  assert.equal(opened.onlineMoveInLease, undefined);
  assert.equal(h.inMemory.read(reservationPath(RENTAL))?.status, 'completed');
});

test.after(() => {
  testEnv.cleanup();
});
