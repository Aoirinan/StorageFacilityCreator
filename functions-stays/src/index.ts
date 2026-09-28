import { ensureFirebaseAdminApp, ensureSentryForFunctions } from '@sfc/functions-shared/init';

ensureFirebaseAdminApp();
ensureSentryForFunctions();

// Stays (short-term rentals). Codebase `stays`: no VPC connector, no
// secrets, no Stripe (scripts/check_stays_isolation.cjs enforces it).
export * from './bookings';
export * from './tasks';
export * from './sync';
export * from './money';
