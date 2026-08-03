export type CancellationPlanType = 'platform' | 'website';

export type CancellationPromo = {
  id: string;
  planTypes: CancellationPlanType[];
  title: string;
  body: string;
  percentOff?: number;
  amountOffCents?: number;
  durationMonths: number;
  active: boolean;
  stripeCouponId?: string | null;
  sortOrder: number;
};

export type CancellationRetentionConfig = {
  primaryReasons: Array<{ id: string; label: string }>;
  detailReasonsByPrimary: Record<string, Array<{ id: string; label: string }>>;
  promos: CancellationPromo[];
  lossCopy: {
    platform: string[];
    website: string[];
  };
};

export const CANCELLATION_RETENTION_DOC = 'cancellationRetention';

export const DEFAULT_CANCELLATION_RETENTION_CONFIG: CancellationRetentionConfig = {
  primaryReasons: [
    { id: 'too_expensive', label: 'Too expensive' },
    { id: 'not_using', label: 'Not using it enough' },
    { id: 'switching', label: 'Switching to another product' },
    { id: 'missing_features', label: 'Missing features I need' },
    { id: 'temporary', label: 'Only need a temporary break' },
    { id: 'other', label: 'Other' },
  ],
  detailReasonsByPrimary: {
    too_expensive: [
      { id: 'budget_cut', label: 'Budget cuts / cash flow' },
      { id: 'cheaper_alt', label: 'Found a cheaper alternative' },
      { id: 'not_worth', label: 'Not enough value for the price' },
      { id: 'seasonal', label: 'Seasonal occupancy / slow season' },
    ],
    not_using: [
      { id: 'too_busy', label: 'Too busy to learn / use it' },
      { id: 'staff_change', label: 'Staff change / no one managing it' },
      { id: 'already_have_process', label: 'Already have another process that works' },
      { id: 'too_complicated', label: 'Felt too complicated' },
    ],
    switching: [
      { id: 'competitor', label: 'Moving to a competitor' },
      { id: 'all_in_one', label: 'Want an all-in-one suite' },
      { id: 'accountant', label: 'Accountant / partner recommended something else' },
      { id: 'custom_build', label: 'Building something custom' },
    ],
    missing_features: [
      { id: 'reporting', label: 'Reporting / analytics' },
      { id: 'integrations', label: 'Integrations (QuickBooks, gates, etc.)' },
      { id: 'website', label: 'Website / online rentals features' },
      { id: 'automation', label: 'Automation / reminders' },
      { id: 'other_feature', label: 'Something else missing' },
    ],
    temporary: [
      { id: 'selling_facility', label: 'Selling or transferring the facility' },
      { id: 'renovation', label: 'Renovation / temporarily closed' },
      { id: 'try_later', label: 'Want to try again later' },
      { id: 'life_event', label: 'Personal / life circumstances' },
    ],
    other: [
      { id: 'support', label: 'Support experience' },
      { id: 'bugs', label: 'Bugs or reliability' },
      { id: 'dont_need', label: 'No longer need software' },
      { id: 'prefer_not_say', label: 'Prefer not to say' },
    ],
  },
  promos: [
    {
      id: 'platform_20_off_3mo',
      planTypes: ['platform'],
      title: 'Stay for 20% off',
      body: 'Keep your facility software for 20% off for the next 3 months.',
      percentOff: 20,
      durationMonths: 3,
      active: true,
      stripeCouponId: null,
      sortOrder: 1,
    },
    {
      id: 'website_1mo_free',
      planTypes: ['website'],
      title: 'One month free on your website',
      body: 'Keep your public website live — we will apply 100% off for 1 month.',
      percentOff: 100,
      durationMonths: 1,
      active: true,
      stripeCouponId: null,
      sortOrder: 1,
    },
  ],
  lossCopy: {
    platform: [
      'Staff will lose access to manage tenants, units, payments, and reports for this facility.',
      'Online payments and day-to-day operations tools will lock after the billing period ends.',
      'Your data stays saved, but you will need an active subscription to use the software again.',
    ],
    website: [
      'Your public marketing / online rental website will stop serving after the billing period ends.',
      'Custom domain and public links will no longer show your live site.',
      'Website Setup settings are kept, but visitors will not see the site until you resubscribe.',
    ],
  },
};
