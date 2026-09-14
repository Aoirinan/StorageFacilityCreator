import test from 'node:test';
import assert from 'node:assert/strict';
import {
  buildPortalAccessCodeReminderEmail,
  buildTenantPortalInviteEmail,
  generatePortalAccessCode,
  maskEmail,
  PORTAL_ACCESS_CODE_ALPHABET,
} from '../portal/portalInviteEmail';

test('generated access codes are eight characters from the phone-safe alphabet', () => {
  for (let i = 0; i < 50; i += 1) {
    const code = generatePortalAccessCode();
    assert.equal(code.length, 8);
    for (const ch of code) assert.ok(PORTAL_ACCESS_CODE_ALPHABET.includes(ch), `bad char ${ch}`);
  }
  // No 0, O, 1 or I: they get misread when a code is dictated.
  for (const ch of '0O1I') assert.equal(PORTAL_ACCESS_CODE_ALPHABET.includes(ch), false);
  // Deterministic with an injected random source.
  assert.equal(generatePortalAccessCode(4, () => 0), 'AAAA');
});

test('invite email carries link, login email, code and the autopay pitch when payments work', () => {
  const m = buildTenantPortalInviteEmail({
    facilityName: 'Keepsake Self Storage',
    tenantName: 'Alicia Smith',
    unitNumber: '204',
    email: 'alicia@example.com',
    accessCode: 'KHHQDKV6',
    portalUrl: 'https://app.storagefacilitycreator.com/#/tenant-portal',
    facilityPhone: '903 715 7504',
    autopayAvailable: true,
  });
  assert.equal(m.subject, 'Your Keepsake Self Storage tenant portal is ready');
  assert.match(m.text, /^Hi Alicia,/);
  assert.match(m.text, /for unit 204/);
  assert.match(m.text, /Access code: KHHQDKV6/);
  assert.match(m.text, /Email: alicia@example.com/);
  assert.match(m.text, /turn on autopay/);
  assert.match(m.text, /or call 903 715 7504/);
  assert.match(m.html, /KHHQDKV6/);
  assert.match(m.html, /href="https:\/\/app\.storagefacilitycreator\.com\/#\/tenant-portal"/);
});

test('reminder email restates the code and reassures the wrong recipient', () => {
  const m = buildPortalAccessCodeReminderEmail({
    facilityName: 'Keepsake Self Storage',
    tenantName: 'Russell Forsyth',
    unitNumber: '201',
    email: 'r@example.com',
    accessCode: 'KHHQDKV6',
    portalUrl: 'https://app.example.com/#/tenant-portal',
    autopayAvailable: true,
  });
  assert.equal(m.subject, 'Your Keepsake Self Storage portal access code');
  assert.match(m.text, /Access code: KHHQDKV6/);
  assert.match(m.text, /\(unit 201\)/);
  assert.match(m.text, /Your code has not changed/);
});

test('maskEmail keeps the first letter and the domain only', () => {
  assert.equal(maskEmail('russell_forsyth_1992@outlook.com'), 'r***@outlook.com');
  assert.equal(maskEmail('not-an-email'), '');
});

test('invite email skips the autopay pitch when the facility cannot take cards', () => {
  const m = buildTenantPortalInviteEmail({
    facilityName: 'North <Lot>',
    tenantName: '',
    email: 't@example.com',
    accessCode: 'ABCDEFGH',
    portalUrl: 'https://app.example.com/#/tenant-portal',
    autopayAvailable: false,
  });
  assert.match(m.text, /^Hi,/);
  assert.equal(/autopay/i.test(m.text), false);
  assert.match(m.html, /North &lt;Lot&gt;/);
});
