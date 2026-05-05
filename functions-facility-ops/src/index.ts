import { ensureFirebaseAdminApp, ensureSentryForFunctions } from '@sfc/functions-shared/init';

ensureFirebaseAdminApp();
ensureSentryForFunctions();

export {
  onTenantWrite,
  onUnitWrite,
  updateAllFacilityStatsNightly,
  updateFacilityStatsManual,
} from './facility_stats';

export {
  setUnitOverlockStatus,
  setUnitsOverlockStatusBulk,
  overlockAllDelinquent,
  clearOverlockByFilter,
} from './overlock';
