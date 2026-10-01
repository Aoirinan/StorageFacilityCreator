/**
 * The public website offers a rental only when the reservation hold would
 * take one.
 *
 * The site under /w/ showed "Reserve online", "Rent now", "Start a rental" and
 * a "Reserve Now" form at every facility, reading only each unit's published
 * isRentable. createPublicReservationHold also refuses every unit while the
 * owner's online rentals switch (settings/public publicRentalsEnabled) is off,
 * so at a facility such as Oakvale, with rentals off, every one of those
 * buttons ended in "This facility is not taking online rentals right now".
 */
import test from 'node:test';
import assert from 'node:assert/strict';
import firebaseFunctionsTest from 'firebase-functions-test';
import { InMemoryFirestore, installInMemoryFirestore } from './support/inMemoryFirestore';
import { MAX_ACTIVE_TENANTS_PER_FACILITY } from '../tenantCapacity';

const testEnv = firebaseFunctionsTest({ projectId: 'in-memory-test' });
const callableContext = { app: { appId: 'test-app-check' } };

const FACILITY = 'fac-oakvale';
const SLUG = 'oakvale';
const UNIT = 'unit-a1';
const PHONE = '(806) 555-0100';

type Scenario = {
  name: string;
  /** settings/public, or null for a facility that never set online rentals up. */
  settings: Record<string, unknown> | null;
  /** Whether createPublicReservationHold takes a rental here. */
  open: boolean;
  activeTenants?: number;
};

const SCENARIOS: Scenario[] = [
  { name: 'online rentals on', settings: { publicRentalsEnabled: true }, open: true },
  { name: 'online rentals off', settings: { publicRentalsEnabled: false }, open: false },
  { name: 'online rentals never set up (no settings doc)', settings: null, open: false },
  { name: 'online rentals never set up (no field)', settings: { enabled: true }, open: false },
  { name: 'a stray non-boolean switch', settings: { publicRentalsEnabled: 'true' }, open: false },
  {
    name: 'online rentals on at a facility at its tenant limit',
    settings: { publicRentalsEnabled: true },
    open: false,
    activeTenants: MAX_ACTIVE_TENANTS_PER_FACILITY,
  },
];

/** Everything a rental action on the page is made of. None may appear while the hold refuses. */
const RENTAL_MARKERS = [
  'data-modal-open="1"',
  'id="rent-modal"',
  'Reserve Now',
  'Rent now',
  'Rent online',
  'Reserve online',
  'Start a rental',
  'id="how-it-works"',
  // The rental flow in the app, which the modal sends the renter to.
  'app.storagefacilitycreator.com/#/f/',
];

function seedSite(
  inMemory: InMemoryFirestore,
  scenario: Pick<Scenario, 'settings' | 'activeTenants'>,
  options: { phone?: string; snapshotRentalsEnabled?: boolean; websiteConfig?: Record<string, unknown> } = {},
) {
  // billingExempt: the site is served without a website subscription.
  inMemory.seed(`facilities/${FACILITY}`, { name: 'Oakvale Storage', billingExempt: true });
  if (scenario.settings) {
    inMemory.seed(`facilities/${FACILITY}/settings/public`, scenario.settings);
  }
  for (let i = 0; i < (scenario.activeTenants ?? 0); i++) {
    inMemory.seed(`facilities/${FACILITY}/tenants/t${i}`, { name: `T${i}`, isActive: true, unitNumber: `X${i}` });
  }
  inMemory.seed(`facilities/${FACILITY}/units/${UNIT}`, {
    status: 'available',
    unitNumber: 'A1',
    unitType: 'standard',
    monthlyRate: 100,
  });
  inMemory.seed(`publicFacilityMaps/${SLUG}`, {
    facilityId: FACILITY,
    facilityName: 'Oakvale Storage',
    facilityPhone: options.phone ?? PHONE,
    publicSettings: {
      enabled: true,
      // The app's copy from its last publish, which can lag the owner's switch.
      publicRentalsEnabled: options.snapshotRentalsEnabled ?? scenario.settings?.publicRentalsEnabled === true,
      websiteConfig: options.websiteConfig ?? {},
    },
    units: [
      {
        unitId: UNIT,
        unitNumber: 'A1',
        status: 'available',
        unitType: 'standard',
        categorySlug: 'standard',
        size: '10x10',
        monthlyRate: 100,
        isRentable: true,
      },
    ],
  });
}

function seedFor(scenario: Pick<Scenario, 'settings' | 'activeTenants'>, options?: Parameters<typeof seedSite>[2]) {
  const inMemory = new InMemoryFirestore();
  seedSite(inMemory, scenario, options);
  return inMemory;
}

function loadWebsite(inMemory: InMemoryFirestore) {
  installInMemoryFirestore(inMemory);
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  return require('../publicWebsite') as typeof import('../publicWebsite');
}

type Captured = { status: number; body: unknown };

async function callHttp(
  fn: (req: never, res: never) => unknown,
  req: { path: string; query?: Record<string, string> },
): Promise<Captured> {
  const captured: Captured = { status: 200, body: undefined };
  const res = {
    status(code: number) {
      captured.status = code;
      return res;
    },
    type() {
      return res;
    },
    set() {
      return res;
    },
    send(body: unknown) {
      captured.body = body;
      return res;
    },
    json(body: unknown) {
      captured.body = body;
      return res;
    },
  };
  const request = {
    method: 'GET',
    path: req.path,
    originalUrl: req.path,
    query: req.query ?? {},
    headers: {},
    get: () => undefined,
  };
  await fn(request as never, res as never);
  return captured;
}

async function renderSite(inMemory: InMemoryFirestore, path = `/w/${SLUG}`): Promise<Captured & { html: string }> {
  const { renderPublicWebsite } = loadWebsite(inMemory);
  const result = await callHttp(renderPublicWebsite as never, { path });
  return { ...result, html: String(result.body ?? '') };
}

async function holdTakesRental(inMemory: InMemoryFirestore): Promise<boolean> {
  installInMemoryFirestore(inMemory);
  // eslint-disable-next-line @typescript-eslint/no-require-imports
  const moveIn = require('../publicMoveIn') as typeof import('../publicMoveIn');
  try {
    await testEnv.wrap(moveIn.createPublicReservationHold)(
      { facilityId: FACILITY, unitId: UNIT, email: 'renter@example.com', name: 'Rita Renter' },
      callableContext,
    );
    return true;
  } catch (err) {
    assert.equal((err as { code?: string }).code, 'failed-precondition');
    return false;
  }
}

for (const scenario of SCENARIOS) {
  test(`with ${scenario.name}, the site offers a rental exactly when the hold takes one`, async () => {
    const page = await renderSite(seedFor(scenario));
    const holdTakes = await holdTakesRental(seedFor(scenario));

    assert.equal(page.status, 200);
    assert.equal(holdTakes, scenario.open);
    for (const marker of RENTAL_MARKERS) {
      assert.equal(page.html.includes(marker), holdTakes, `${marker} on the page, hold takes: ${holdTakes}`);
    }
    // The unit is listed either way, with its price, for the renter to ask about.
    assert.ok(page.html.includes('10x10 · Standard'));
    assert.ok(page.html.includes('$100 / month'));
  });
}

test('with online rentals off, every rental action becomes a call to the office', async () => {
  const { html } = await renderSite(seedFor({ settings: { publicRentalsEnabled: false } }));

  // Hero, the unit card, and the pricing card's "Start a rental".
  const calls = html.match(/<a class="[^"]*" (?:style="[^"]*" )?href="tel:8065550100">Call to rent<\/a>/g) || [];
  assert.equal(calls.length, 3, html);
  assert.ok(html.includes('class="legend-rent-btn legend-contact-btn" href="tel:8065550100"'));
});

test('with online rentals off and no phone, the rental actions go to the contact section', async () => {
  const { html } = await renderSite(seedFor({ settings: { publicRentalsEnabled: false } }, { phone: '' }));

  assert.ok(html.includes('class="legend-rent-btn legend-contact-btn" href="#contact">Contact us to rent</a>'));
  assert.ok(html.includes('id="contact"'));
  assert.equal(html.includes('href="tel:'), false);
});

test("with online rentals off, the owner's rental wording for the main button is not used", async () => {
  const { html } = await renderSite(
    seedFor({ settings: { publicRentalsEnabled: false } }, { websiteConfig: { primaryCtaLabel: 'Reserve Your Unit' } }),
  );

  assert.equal(html.includes('Reserve Your Unit'), false);
  assert.ok(html.includes('>View units</a>'));
});

test('with online rentals on, the page keeps its rental actions and the owner wording', async () => {
  const { html } = await renderSite(
    seedFor({ settings: { publicRentalsEnabled: true } }, { websiteConfig: { primaryCtaLabel: 'Reserve Your Unit' } }),
  );

  assert.ok(html.includes('Reserve Your Unit'));
  assert.ok(html.includes('data-rent-base="https://app.storagefacilitycreator.com/#/f/oakvale/standard?embed=1"'));
  assert.equal(html.includes('Call to rent'), false);
});

test("the site reads the owner's switch live, not the snapshot's copy from the last publish", async () => {
  // Turned off without a republish: the snapshot still says on, the hold says no.
  const offLive = await renderSite(seedFor({ settings: { publicRentalsEnabled: false } }, { snapshotRentalsEnabled: true }));
  assert.equal(offLive.html.includes('data-modal-open="1"'), false);
  assert.ok(offLive.html.includes('Call to rent'));

  // And the other way round.
  const onLive = await renderSite(seedFor({ settings: { publicRentalsEnabled: true } }, { snapshotRentalsEnabled: false }));
  assert.ok(onLive.html.includes('data-modal-open="1"'));
});

test('a category page follows the switch too', async () => {
  const websiteConfig = { unitCategories: [{ slug: 'standard', name: 'Standard Units' }] };
  const off = await renderSite(
    seedFor({ settings: { publicRentalsEnabled: false } }, { websiteConfig }),
    `/w/${SLUG}/c/standard`,
  );
  assert.equal(off.status, 200);
  assert.equal(off.html.includes('data-modal-open="1"'), false);
  assert.ok(off.html.includes('Call to rent'));

  const on = await renderSite(seedFor({ settings: { publicRentalsEnabled: true } }, { websiteConfig }), `/w/${SLUG}/c/standard`);
  assert.ok(on.html.includes('data-modal-open="1"'));
});

test('the not-found page offers no rental and no payment button', async () => {
  const page = await renderSite(new InMemoryFirestore(), '/w/no-such-site');

  assert.equal(page.status, 404);
  for (const marker of [...RENTAL_MARKERS, 'Rent Online', 'class="btn-pay"']) {
    assert.equal(page.html.includes(marker), false, marker);
  }
});

for (const scenario of SCENARIOS) {
  test(`with ${scenario.name}, the website config gives a rent link exactly when the hold takes one`, async () => {
    const { getPublicWebsiteConfig } = loadWebsite(seedFor(scenario));
    const result = await callHttp(getPublicWebsiteConfig as never, { path: '/api/public-website', query: { slug: SLUG } });
    const body = result.body as Record<string, unknown>;

    assert.equal(result.status, 200);
    assert.equal(body.onlineRentalsEnabled, scenario.open);
    assert.equal(body.rentUrl, scenario.open ? `https://app.storagefacilitycreator.com/w/${SLUG}#units` : null);
    // Browsing units is not a rental; it stays.
    assert.equal(body.availableUnitsUrl, `https://app.storagefacilitycreator.com/w/${SLUG}#units`);
  });
}

test('a failed settings read shows no rental action, and the page still renders', async () => {
  const inMemory = seedFor({ settings: { publicRentalsEnabled: true } });
  inMemory.docErrors.set(`facilities/${FACILITY}/settings/public`, new Error('unavailable'));

  const page = await renderSite(inMemory);

  assert.equal(page.status, 200);
  assert.equal(page.html.includes('data-modal-open="1"'), false);
  assert.ok(page.html.includes('Call to rent'));
});
