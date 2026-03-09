#!/usr/bin/env node
/**
 * Simulation: Storage Facility Creator with N paying facilities
 * Outputs estimated Firestore ops, Cloud Function invocations, and third-party usage.
 * Usage: node scripts/simulate_100_facilities.js [facilityCount] [--cost]
 * Default: 100 facilities. --cost adds monthly USD cost estimate.
 */

const args = process.argv.slice(2);
const facilityCount = parseInt(args.find((a) => !a.startsWith('--')) || '100', 10) || 100;
const showCost = args.includes('--cost');

// Tier mix: [small, medium, large] as share of facilities (must sum to 1)
const TIER_SHARES = { small: 0.40, medium: 0.45, large: 0.15 };
const UNITS_RANGE = {
  small: { min: 50, max: 150 },
  medium: { min: 150, max: 400 },
  large: { min: 400, max: 800 },
};
const OCCUPANCY = { small: 0.75, medium: 0.78, large: 0.8 };

function avg(a, b) {
  return (a + b) / 2;
}

function tierCounts(n) {
  return {
    small: Math.round(n * TIER_SHARES.small),
    medium: Math.round(n * TIER_SHARES.medium),
    large: Math.round(n * TIER_SHARES.large),
  };
}

function simulateDataVolume(n) {
  const counts = tierCounts(n);
  let totalUnits = 0;
  let totalTenants = 0;

  for (const [tier, num] of Object.entries(counts)) {
    const u = UNITS_RANGE[tier];
    const unitsPerFacility = avg(u.min, u.max);
    const occ = OCCUPANCY[tier];
    totalUnits += num * unitsPerFacility;
    totalTenants += num * unitsPerFacility * occ;
  }

  const avgUnitsPerFacility = totalUnits / n;
  const avgTenantsPerFacility = totalTenants / n;

  return {
    facilities: n,
    totalUnits: Math.round(totalUnits),
    totalTenants: Math.round(totalTenants),
    avgUnitsPerFacility: Math.round(avgUnitsPerFacility),
    avgTenantsPerFacility: Math.round(avgTenantsPerFacility),
    tierCounts: counts,
  };
}

function simulateDailyOps(data) {
  const { facilities, totalTenants, avgTenantsPerFacility } = data;

  // Manager sessions: 2-4 per facility per day
  const managerSessionsPerDay = facilities * 3;
  const managerReadsPerSession = 50;
  const managerReads = managerSessionsPerDay * managerReadsPerSession;

  // Tenant portal: 5-15% of tenants log in on a given day
  const tenantSessionsPerDay = Math.round(totalTenants * 0.10);
  const tenantReadsPerSession = 15;
  const tenantReads = tenantSessionsPerDay * tenantReadsPerSession;

  // Client-side Firestore reads
  const clientReadsPerDay = managerReads + tenantReads;

  // Firestore triggers: tenant/unit writes trigger stats (each: 2 queries + 2 writes per facility)
  const tenantWritesPerDay = facilities * 4; // move-ins, edits, etc.
  const unitWritesPerDay = facilities * 3;
  const triggerInvocations = tenantWritesPerDay + unitWritesPerDay;
  const readsPerStatsTrigger = avgTenantsPerFacility + Math.round(avgTenantsPerFacility / 0.78); // units ~= tenants/occ
  const triggerReads = triggerInvocations * readsPerStatsTrigger;
  const triggerWrites = triggerInvocations * 2; // stats doc + facility doc

  // Scheduled jobs (per day) - each job: 1 + facilities * (1 + per-facility queries)
  const facilitiesListRead = 1;
  const perFacilityReads = {
    nightlyStats: facilitiesListRead + facilities * (Math.round(avgTenantsPerFacility / 0.78) + avgTenantsPerFacility),
    monthlyRent: 0, // only on 1st
    autopay: facilitiesListRead + facilities * (avgTenantsPerFacility + avgTenantsPerFacility * 0.3),
    delinquency: facilitiesListRead + facilities * (avgTenantsPerFacility * 2),
    paymentReminders: facilitiesListRead + facilities * avgTenantsPerFacility,
    autoProtectMoveIn: facilitiesListRead + facilities * 50,
    insuranceCompliance: facilitiesListRead + facilities * 100,
    dailyDigests: facilitiesListRead + facilities * 20,
  };

  const scheduledReadsPerDay =
    perFacilityReads.nightlyStats +
    perFacilityReads.autopay +
    perFacilityReads.delinquency +
    perFacilityReads.paymentReminders +
    perFacilityReads.autoProtectMoveIn +
    perFacilityReads.insuranceCompliance +
    perFacilityReads.dailyDigests;

  const scheduledWritesPerDay =
    facilities * 2 + // nightly stats: stats doc + facility update
    Math.round(totalTenants * 0.02) + // autopay: ledger + payment docs
    facilities * 5 + // delinquency
    facilities * 2 + // reminders
    facilities * 2; // insurance / move-in

  // Monthly rent (1st): one big spike
  const monthlyRentReads = facilitiesListRead + facilities * (avgTenantsPerFacility + avgTenantsPerFacility * 2);
  const monthlyRentWrites = totalTenants + facilities; // invoice/ledger per tenant + facility

  // Callables: auth, Stripe, SMS, email, overlock, AI, etc.
  const callableInvocationsPerDay = managerSessionsPerDay * 8 + tenantSessionsPerDay * 2;

  const totalReadsPerDay = Math.round(clientReadsPerDay + triggerReads + scheduledReadsPerDay);
  const totalWritesPerDay = Math.round(triggerWrites + scheduledWritesPerDay);
  const totalInvocationsPerDay = Math.round(triggerInvocations + 7 + callableInvocationsPerDay); // 7 = scheduled jobs

  return {
    clientReadsPerDay,
    triggerReads: Math.round(triggerReads),
    scheduledReadsPerDay: Math.round(scheduledReadsPerDay),
    totalReadsPerDay,
    totalWritesPerDay,
    totalInvocationsPerDay,
    triggerInvocations,
    callableInvocationsPerDay: Math.round(callableInvocationsPerDay),
    monthlyRentReads: Math.round(monthlyRentReads),
    monthlyRentWrites: Math.round(monthlyRentWrites),
  };
}

function simulateDocumentCounts(data) {
  const { facilities, totalUnits, totalTenants } = data;
  return {
    facilities,
    units: totalUnits,
    tenants: totalTenants,
    contracts: Math.round(totalTenants * 1.25),
    invoices: totalTenants * 3,
    ledgers: totalTenants * 25, // historical
    payments: totalTenants * 5,
    stats: facilities,
    other: Math.round(totalTenants * 2),
    total:
      facilities +
      totalUnits +
      totalTenants +
      Math.round(totalTenants * 1.25) +
      totalTenants * 3 +
      totalTenants * 25 +
      totalTenants * 5 +
      facilities +
      Math.round(totalTenants * 2),
  };
}

function simulateThirdParty(data) {
  const { totalTenants, facilities } = data;
  const paymentsPerDay = Math.round(totalTenants * 0.08);
  // AI: facility owners get 20 questions/day per facility (config maxMessagesPerUser: 20). Max = 20 * facilities.
  // Each AI call also triggers one OpenAI Moderation API call (free).
  const openAiCallsPerDayMax = 20 * facilities;
  // E-signature: built-in (pdf-lib + Firebase Storage). No DocuSign. Cost = $0.
  // Sentry: error monitoring for Cloud Functions + Flutter frontend.
  return {
    stripeConnectAccounts: facilities,
    stripePaymentsPerDay: paymentsPerDay,
    stripeApiCallsPerDay: paymentsPerDay * 5 + facilities * 20,
    sendGridEmailsPerDay: 50 * facilities + Math.round(totalTenants * 0.05),
    // SMS: 4 per tenant/month cap, 1000/facility/month cap, $0.0083/msg (Twilio US long-code)
    twilioSmsPerDay: 10 * facilities,
    openAiCallsPerDay: openAiCallsPerDayMax,
    openAiCallsPerDayNote: '20 questions/day per facility (cap); gpt-4o-mini + moderation API',
    // SaaS billing: $75/mo per facility paid to you; you pay Stripe 2.9%+$0.30 per charge
    saasRevenuePerMonth: 75 * facilities,
    saasStripeFeePerMonth: facilities * (75 * 0.029 + 0.30), // one charge per facility/month
  };
}

// Run simulation
const data = simulateDataVolume(facilityCount);
const ops = simulateDailyOps(data);
const docs = simulateDocumentCounts(data);
const thirdParty = simulateThirdParty(data);

// Print report
console.log('\n=== Storage Facility Creator – Load Simulation ===\n');
console.log(`Scenario: ${facilityCount} paying facilities\n`);

console.log('--- Data volume ---');
console.log(`  Facilities:        ${data.facilities}`);
console.log(`  Total units:       ${data.totalUnits}`);
console.log(`  Active tenants:    ${data.totalTenants}`);
console.log(`  Avg units/facility:   ${data.avgUnitsPerFacility}`);
console.log(`  Avg tenants/facility:  ${data.avgTenantsPerFacility}`);
console.log(`  Tier mix:          small ${data.tierCounts.small}, medium ${data.tierCounts.medium}, large ${data.tierCounts.large}`);

console.log('\n--- Firestore (typical day) ---');
console.log(`  Client reads:      ${ops.clientReadsPerDay.toLocaleString()}`);
console.log(`  Trigger reads:     ${ops.triggerReads.toLocaleString()}`);
console.log(`  Scheduled reads:   ${ops.scheduledReadsPerDay.toLocaleString()}`);
console.log(`  Total reads/day:   ${ops.totalReadsPerDay.toLocaleString()}`);
console.log(`  Total writes/day:  ${ops.totalWritesPerDay.toLocaleString()}`);
console.log(`  (On 1st of month:  +${ops.monthlyRentReads.toLocaleString()} reads, +${ops.monthlyRentWrites.toLocaleString()} writes)`);

console.log('\n--- Firestore document count (approx) ---');
console.log(`  Total documents:  ${docs.total.toLocaleString()}`);

console.log('\n--- Cloud Functions ---');
console.log(`  Trigger invocations/day:  ${ops.triggerInvocations}`);
console.log(`  Callable invocations/day: ${ops.callableInvocationsPerDay.toLocaleString()}`);
console.log(`  Scheduled runs/day:       7`);
console.log(`  Total invocations/day:    ${ops.totalInvocationsPerDay.toLocaleString()}`);

console.log('\n--- Third-party (typical day) ---');
console.log(`  Stripe Connect accounts:  ${thirdParty.stripeConnectAccounts}`);
console.log(`  Stripe payments:          ${thirdParty.stripePaymentsPerDay.toLocaleString()}`);
console.log(`  Stripe API calls:         ${thirdParty.stripeApiCallsPerDay.toLocaleString()}`);
console.log(`  SendGrid emails:          ${thirdParty.sendGridEmailsPerDay.toLocaleString()}`);
console.log(`  Twilio SMS:               ${thirdParty.twilioSmsPerDay.toLocaleString()}`);
console.log(`  OpenAI (AI Assistant):    ${thirdParty.openAiCallsPerDay}  (${thirdParty.openAiCallsPerDayNote || 'calls/day'})`);
console.log(`  E-signature:              Built-in (pdf-lib + Firebase Storage) — $0/month`);
console.log(`  SaaS revenue (your MRR):  $${thirdParty.saasRevenuePerMonth.toLocaleString()}/month  (${facilityCount} facilities × $75)`);
console.log(`  Stripe fees on SaaS MRR:  ~$${thirdParty.saasStripeFeePerMonth.toFixed(2)}/month`);

console.log('\n--- Verdict ---');
const freeTierReads = 50000;
const freeTierWrites = 20000;
if (ops.totalReadsPerDay > freeTierReads || ops.totalWritesPerDay > freeTierWrites) {
  console.log(`  Firestore free tier exceeded (50k reads, 20k writes/day). Blaze (pay-as-you-go) required.`);
}
if (ops.scheduledReadsPerDay > 2000000) {
  console.log(`  Scheduled job read volume is high; consider batching facilities (e.g. Cloud Tasks).`);
}
console.log('  Simulation complete.\n');

// --- Monthly cost estimate (USD) ---
if (showCost) {
  const daysPerMonth = 30;
  const readsPerMonth = ops.totalReadsPerDay * daysPerMonth + ops.monthlyRentReads;
  const writesPerMonth = ops.totalWritesPerDay * daysPerMonth + ops.monthlyRentWrites;
  const freeReadsPerMonth = 50e3 * daysPerMonth;
  const freeWritesPerMonth = 20e3 * daysPerMonth;
  const billableReads = Math.max(0, readsPerMonth - freeReadsPerMonth);
  const billableWrites = Math.max(0, writesPerMonth - freeWritesPerMonth);

  const firestoreReadCost = (billableReads / 100000) * 0.03;
  const firestoreWriteCost = (billableWrites / 100000) * 0.09;
  const firestoreStorageGiB = Math.max(0, (docs.total * 2) / (1024 * 1024 * 1024) - 1); // ~2 KB/doc, 1 GiB free
  const firestoreStorageCost = firestoreStorageGiB * 0.000205479;

  const invocationsPerMonth = ops.totalInvocationsPerDay * daysPerMonth;
  const functionsCost = (invocationsPerMonth / 1e6) * 0.40 + 12; // $0.40/million invocations + ~$12 compute (GB-sec)

  const emailsPerMonth = thirdParty.sendGridEmailsPerDay * daysPerMonth;
  const sendGridCost =
    emailsPerMonth <= 3000 ? 0 : emailsPerMonth <= 40000 ? 19.95 : emailsPerMonth <= 100000 ? 49 : 89.95;

  const smsPerMonth = thirdParty.twilioSmsPerDay * daysPerMonth;
  const twilioCost = smsPerMonth * 0.0083;

  const openAiCallsPerMonth = thirdParty.openAiCallsPerDay * daysPerMonth;
  // gpt-4o-mini: $0.150/1M input tokens, $0.600/1M output tokens (as of 2025)
  // Each call: ~1,500 tokens in (system prompt ~1,100 + user message ~400) + 380 tokens out (MAX_OUTPUT_TOKENS)
  // Moderation API: free (no cost per call)
  const openAiInputCost = (openAiCallsPerMonth * 1500 / 1e6) * 0.150;
  const openAiOutputCost = (openAiCallsPerMonth * 380 / 1e6) * 0.600;
  const openAiCost = openAiInputCost + openAiOutputCost;

  // E-signature: built-in using pdf-lib + Firebase Storage. No third-party cost.
  const eSignCost = 0;

  // Stripe fees on YOUR SaaS billing (2.9% + $0.30 per facility charge per month)
  const stripeSaasCost = thirdParty.saasStripeFeePerMonth;

  // Sentry: free tier covers 5k errors/month. At this scale, Team plan ~$26/mo is sufficient.
  const sentryCost = 26;

  // Firebase Storage: contract PDFs ~500 KB each, ~4 contracts/facility/month
  // 100 facilities × 4 × 0.5 MB = 200 MB/month new storage; total ~2 GB stored
  // Storage: $0.026/GB/month after 5 GB free → $0 at this scale
  // Download: $0.12/GB after 1 GB free → minimal
  const storageGiB = (facilityCount * 4 * 0.5) / 1024; // GB new per month
  const storageCost = Math.max(0, storageGiB - 5) * 0.026; // first 5 GB free

  const total =
    firestoreReadCost +
    firestoreWriteCost +
    firestoreStorageCost +
    functionsCost +
    sendGridCost +
    twilioCost +
    openAiCost +
    eSignCost +
    stripeSaasCost +
    sentryCost +
    storageCost;

  const saasRevenue = thirdParty.saasRevenuePerMonth;
  const netAfterCosts = saasRevenue - total;

  console.log('=== Monthly cost estimate (USD) ===\n');
  console.log('  Firebase / Google Cloud');
  console.log(`    Firestore reads:    $${firestoreReadCost.toFixed(2)}  (${(billableReads / 1e6).toFixed(2)}M billable)`);
  console.log(`    Firestore writes:   $${firestoreWriteCost.toFixed(2)}`);
  console.log(`    Firestore storage:  $${firestoreStorageCost.toFixed(2)}`);
  console.log(`    Cloud Functions:   ~$${functionsCost.toFixed(2)}`);
  console.log(`    Firebase Storage:   $${storageCost.toFixed(2)}  (contract PDFs, ~${(storageGiB * 1024).toFixed(0)} MB/mo new)`);
  console.log('  Third-party services');
  console.log(`    SendGrid:           $${sendGridCost.toFixed(2)}  (${(emailsPerMonth / 1000).toFixed(0)}k emails/mo)`);
  console.log(`    Twilio SMS:         $${twilioCost.toFixed(2)}  (${(smsPerMonth / 1000).toFixed(0)}k SMS/mo @ $0.0083/msg)`);
  console.log(`    OpenAI (gpt-4o-mini): $${openAiCost.toFixed(2)}  (${openAiCallsPerMonth.toLocaleString()} calls/mo, 1500 in + 380 out tokens)`);
  console.log(`    E-signature (built-in): $${eSignCost.toFixed(2)}  (pdf-lib + Firebase Storage — no third-party cost)`);
  console.log(`    Stripe (SaaS billing):  $${stripeSaasCost.toFixed(2)}  (2.9%+$0.30 × ${facilityCount} facility charges/mo)`);
  console.log(`    Sentry (error monitoring): $${sentryCost.toFixed(2)}  (Team plan)`);
  console.log('  ---');
  console.log(`  TOTAL COSTS:         $${total.toFixed(2)}/month`);
  console.log(`  YOUR SaaS REVENUE:   $${saasRevenue.toLocaleString()}/month  (${facilityCount} × $75)`);
  console.log(`  NET (revenue-costs): $${netAfterCosts.toFixed(2)}/month\n`);
}
