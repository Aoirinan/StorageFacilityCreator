import type { Timestamp } from 'firebase-admin/firestore';

import type {
  StayChecklistTemplateItem,
  StayListingKind,
  StayMessageTemplateDoc,
  TemplateChannelHint,
  TurnoverMode,
} from '@sfc/functions-shared/stays/contracts';

/**
 * What Stays sets up the first time a facility turns it on (spec §9, §1.1 H):
 * the copy-first message templates and the default turnover checklists.
 * Templates are only ever copied, printed or opened in her own mail or text
 * app; nothing here is sent. Every {{variable}} is one the app's
 * StayMessageRenderer knows, and a value it cannot fill shows as [name].
 */

export interface SeedTemplate {
  key: string;
  name: string;
  channelHint: TemplateChannelHint;
  body: string;
}

export const SEEDED_TEMPLATES: readonly SeedTemplate[] = [
  {
    key: 'airbnb_check_in',
    name: 'Airbnb check-in instructions',
    channelHint: 'airbnb_paste',
    body:
      'Hi {{guestFirstName}}! Check-in at {{listingName}} is {{checkInDate}} after {{checkInTime}}. ' +
      'Address: {{address}}. Door code: {{doorCode}}. Wifi: {{wifiName}} / {{wifiPassword}}. ' +
      'Checkout {{checkOutDate}} by {{checkOutTime}}. {{houseRules}}',
  },
  {
    key: 'checkout_reminder',
    name: 'Checkout reminder',
    channelHint: 'sms',
    body:
      'Hi {{guestFirstName}}, a quick reminder that checkout at {{listingName}} is {{checkOutDate}} by {{checkOutTime}}. ' +
      '{{checkoutInstructions}} Thanks for staying with us!',
  },
  {
    key: 'rv_welcome',
    name: 'RV welcome and park rules',
    channelHint: 'print',
    body:
      'Welcome to {{facilityName}}, {{guestFirstName}}! You are on site {{siteCode}} ({{hookups}}, {{amps}}A). ' +
      'Checkout is {{checkOutDate}} by {{checkOutTime}}.\n\nQuiet hours: {{quietHours}}\n\nPark rules:\n{{parkRules}}\n\n' +
      'Wifi: {{wifiName}} / {{wifiPassword}}\nQuestions? Call {{facilityPhone}}.',
  },
  {
    key: 'direct_confirmation',
    name: 'Direct booking confirmation',
    channelHint: 'email',
    body:
      'Hi {{guestFirstName}},\n\nYou are booked at {{listingName}} from {{checkInDate}} to {{checkOutDate}} ({{nights}} nights). ' +
      'Check-in is after {{checkInTime}} and checkout is by {{checkOutTime}}.\n\nTotal: {{totalDue}}\nBalance due: {{balanceDue}}\n\n' +
      'Address: {{address}}\nDirections: {{directionsUrl}}\n\nCall {{facilityPhone}} with any questions.\n\n{{facilityName}}',
  },
  {
    key: 'thank_you',
    name: 'Thank you / review request',
    channelHint: 'airbnb_paste',
    body:
      'Thanks for staying at {{listingName}}, {{guestFirstName}}! We hope you enjoyed it. ' +
      'If you have a minute, a review would mean a lot to us. {{facilityName}}',
  },
  {
    key: 'payment_reminder',
    name: 'Payment reminder',
    channelHint: 'sms',
    body:
      'Hi {{guestFirstName}}, this is {{facilityName}}. The balance for your stay at {{listingName}} ' +
      '({{checkInDate}} to {{checkOutDate}}) is {{balanceDue}}. You can pay at the office, or call {{facilityPhone}}. Thank you!',
  },
  {
    key: 'cleaning_schedule',
    name: 'Cleaning schedule',
    channelHint: 'print',
    body:
      'Turnover at {{listingName}} ({{siteCode}}): guests check out {{checkOutDate}} by {{checkOutTime}}. ' +
      'Door code: {{doorCode}}. Trash: {{trashNotes}}. {{checkoutInstructions}}',
  },
];

export function seededTemplateDoc(
  facilityId: string,
  template: SeedTemplate,
  actor: string,
  now: Timestamp,
): StayMessageTemplateDoc {
  return {
    facilityId,
    key: template.key,
    name: template.name,
    body: template.body,
    channelHint: template.channelHint,
    listingIds: [],
    kind: 'copy',
    seeded: true,
    createdAt: now,
    createdBy: actor,
    updatedAt: now,
    updatedBy: actor,
  };
}

/** A full clean, for the Airbnbs, the house and cabins. */
export const FULL_CLEAN_CHECKLIST: readonly StayChecklistTemplateItem[] = [
  { id: 'strip_beds', label: 'Strip beds and start laundry' },
  { id: 'make_beds', label: 'Make beds with fresh linens' },
  { id: 'bathrooms', label: 'Clean bathrooms and restock towels, toilet paper and soap' },
  { id: 'kitchen', label: 'Clean kitchen; dishes washed and put away' },
  { id: 'fridge', label: 'Empty the fridge of guest food' },
  { id: 'restock', label: 'Restock coffee and basics' },
  { id: 'floors', label: 'Vacuum and mop floors' },
  { id: 'trash', label: 'Take out trash and recycling' },
  { id: 'damage_check', label: 'Check for damage and left-behind items' },
  { id: 'lock_up', label: 'Reset thermostat, lights off, lock up' },
];

/** A quick site check, for RV and tent sites. */
export const SITE_CHECK_CHECKLIST: readonly StayChecklistTemplateItem[] = [
  { id: 'hookups', label: 'Hookups off and caps on' },
  { id: 'fire_ring', label: 'Fire ring cleared and safe' },
  { id: 'trash', label: 'Trash picked up' },
  { id: 'site_clear', label: 'Site clear of debris' },
  { id: 'pedestal', label: 'Pedestal and picnic table undamaged' },
];

/** A short general check, for a garage or anything else. */
export const GENERAL_CHECKLIST: readonly StayChecklistTemplateItem[] = [
  { id: 'tidy', label: 'Tidy up and sweep' },
  { id: 'trash', label: 'Take out trash' },
  { id: 'damage_check', label: 'Check for damage and left-behind items' },
  { id: 'lock_up', label: 'Lock up' },
];

/** The checklist a listing starts with, by what it is and how it is turned over. */
export function defaultChecklistFor(kind: StayListingKind, mode: TurnoverMode): StayChecklistTemplateItem[] {
  if (mode === 'none') return [];
  if (kind === 'rv_site' || kind === 'tent_site' || mode === 'quick_check') return SITE_CHECK_CHECKLIST.map((i) => ({ ...i }));
  if (kind === 'garage' || kind === 'other') return GENERAL_CHECKLIST.map((i) => ({ ...i }));
  return FULL_CLEAN_CHECKLIST.map((i) => ({ ...i }));
}
