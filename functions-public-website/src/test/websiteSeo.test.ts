import test from 'node:test';
import assert from 'node:assert/strict';
import {
  categoryNavLabel,
  isHeroImagePlaceholder,
  normalizeState,
  resolveHeroHeadline,
  resolveLocationLabel,
} from '../websiteSeo';

// --- nav labels -------------------------------------------------------------

test('categoryNavLabel turns an internal name into a searchable phrase', () => {
  // The nav previously showed "Standard" and "Outdoor" — internal jargon that
  // matches nothing anyone types into Google.
  assert.equal(categoryNavLabel({ slug: 'standard', name: 'Standard Units' }), 'Standard Self Storage');
  assert.equal(categoryNavLabel({ slug: 'outdoor', name: 'Outdoor Parking' }), 'Outdoor Parking Self Storage');
});

test('categoryNavLabel does not repeat the word storage', () => {
  assert.equal(
    categoryNavLabel({ slug: 'climate', name: 'Climate Controlled Storage' }),
    'Climate Controlled Storage',
  );
});

test('categoryNavLabel falls back to the slug when there is no name', () => {
  assert.equal(categoryNavLabel({ slug: 'climate-controlled' }), 'Climate Controlled Self Storage');
  assert.equal(categoryNavLabel(null, 'drive-up'), 'Drive Up Self Storage');
});

test('categoryNavLabel returns empty when there is nothing to label', () => {
  assert.equal(categoryNavLabel(null, ''), '');
});

// --- state normalising ------------------------------------------------------

test('normalizeState accepts full names and postal codes', () => {
  assert.equal(normalizeState('Texas'), 'TX');
  assert.equal(normalizeState('texas'), 'TX');
  assert.equal(normalizeState('tx'), 'TX');
  assert.equal(normalizeState('New Mexico'), 'NM');
});

test('normalizeState rejects things that are not states', () => {
  assert.equal(normalizeState('East'), '');
  assert.equal(normalizeState('XX'), '');
  assert.equal(normalizeState(''), '');
});

// --- location ---------------------------------------------------------------

test('resolveLocationLabel prefers explicit city and state', () => {
  assert.equal(resolveLocationLabel({ city: 'Anytown', state: 'tx' }), 'Anytown, TX');
});

test('resolveLocationLabel reads the tail of a free-text address', () => {
  // What facilities actually have on file today.
  assert.equal(
    resolveLocationLabel({ address: '1200 US Hwy 9 East Anytown Texas' }),
    'Anytown, TX',
  );
  assert.equal(
    resolveLocationLabel({ address: '123 Main St, Santa Fe, New Mexico 87501' }),
    'Santa Fe, NM',
  );
});

test('resolveLocationLabel returns null rather than guessing badly', () => {
  // A wrong town in the H1 is worse than no town.
  assert.equal(resolveLocationLabel({ address: '1200 US Hwy 9 East' }), null);
  assert.equal(resolveLocationLabel({ address: '' }), null);
  assert.equal(resolveLocationLabel({}), null);
  // Street number where a city should be must not become the city.
  assert.equal(resolveLocationLabel({ address: '82 Texas' }), null);
});

// --- headline ---------------------------------------------------------------

test('resolveHeroHeadline keeps genuine operator copy', () => {
  assert.equal(
    resolveHeroHeadline({ configured: 'Anytown Texas Boat & RV Storage', location: 'Anytown, TX' }),
    'Anytown Texas Boat & RV Storage',
  );
});

test('resolveHeroHeadline replaces the seeded placeholder with a local headline', () => {
  // Existing facilities carry this seeded slogan; treating it as unset is what
  // lets already-onboarded sites gain a location-aware H1 too.
  assert.equal(
    resolveHeroHeadline({
      configured: 'Secure Self Storage, Rented Online in Minutes',
      location: 'Anytown, TX',
      facilityName: 'Pinewood Self Storage',
    }),
    'Self Storage in Anytown, TX',
  );
});

test('resolveHeroHeadline falls back to the facility name without a location', () => {
  assert.equal(
    resolveHeroHeadline({
      configured: 'Secure Self Storage, Rented Online in Minutes',
      location: null,
      facilityName: 'Pinewood Self Storage',
    }),
    'Pinewood Self Storage',
  );
});

test('resolveHeroHeadline builds a local headline when nothing is configured', () => {
  assert.equal(resolveHeroHeadline({ location: 'Anytown, TX' }), 'Self Storage in Anytown, TX');
});

// --- hero image -------------------------------------------------------------

test('isHeroImagePlaceholder flags a missing hero photo', () => {
  assert.equal(isHeroImagePlaceholder(''), true);
  assert.equal(isHeroImagePlaceholder(null), true);
  assert.equal(isHeroImagePlaceholder('   '), true);
  assert.equal(isHeroImagePlaceholder('https://example.com/hero.jpg'), false);
});
