# Multi-Facility Scoping + Stripe Connect Fixes

## Summary
Fixed multi-facility scoping issues and Stripe Connect account overwriting by implementing:
1. Global facility switcher with active facility selection
2. Dashboard filtering by active facility
3. Stripe Connect per-facility storage (already correct)
4. Facility unit count computation on-the-fly
5. Billing enforcement (already implemented)

## Files Changed

### New Files
1. **lib/services/active_facility_service.dart**
   - Service to manage active facility selection
   - Stores `activeFacilityId` in Firestore (`users/{uid}`) and localStorage
   - Supports "All Facilities" view (null = all facilities)

2. **lib/providers/active_facility_provider.dart**
   - Riverpod provider for active facility state
   - Provides reactive access to active facility ID

3. **lib/widgets/facility_switcher.dart**
   - Widget for switching between facilities
   - Shows in top bar (desktop) or as icon menu (mobile)
   - Supports "All Facilities" option

4. **lib/services/facility_stats_service.dart**
   - Service to compute facility statistics on-the-fly
   - Ensures facility cards show accurate unit counts

5. **docs/FACILITY_SCOPING_FIXES.md** (this file)
   - Documentation of changes

### Modified Files

1. **lib/models/user_model.dart**
   - Added `activeFacilityId` field to UserModel
   - Updated `fromFirestore`, `toFirestore`, and `copyWith` methods

2. **lib/providers/dashboard_provider.dart**
   - Updated to filter by `activeFacilityId` instead of aggregating all facilities
   - When `activeFacilityId` is null, shows data for all facilities
   - When `activeFacilityId` is set, shows data for that facility only

3. **lib/screens/home_screen_modern.dart**
   - Added `FacilitySwitcher` widget to top bar
   - Updated welcome section to show active facility name or "All Facilities"
   - Added import for `activeFacilityIdProvider` and `FacilitySwitcher`

4. **lib/screens/facility_management_screen.dart**
   - Updated facility cards to compute unit counts on-the-fly using `FacilityStatsService`
   - This ensures accurate counts even if facility document fields are stale

5. **lib/screens/settings_screen.dart**
   - Updated Stripe Connect tile to use active facility instead of `facilities.first`
   - Shows facility name in subtitle for clarity

6. **lib/router/app_router.dart**
   - Updated Stripe Connect route to support:
     - FacilityModel in `extra` parameter (existing)
     - `facilityId` query parameter (new)
     - Active facility from provider (new fallback)
   - Added imports for `activeFacilityIdProvider` and `facility_provider`

## Implementation Details

### Active Facility Selection
- **Storage**: `activeFacilityId` stored in:
  - Firestore: `users/{uid}/activeFacilityId`
  - localStorage: `active_facility_id` (with special value `__ALL__` for "All Facilities")
- **Default**: null (All Facilities)
- **Provider**: `activeFacilityIdProvider` provides reactive state

### Dashboard Filtering
- Dashboard now filters by `activeFacilityId`:
  - If null: aggregates data from all facilities (existing behavior)
  - If set: shows data for that facility only
- All queries (tenants, units, payments, etc.) respect the active facility filter

### Stripe Connect
- **Already per-facility**: Stripe Connect data is stored on `facilities/{facilityId}`:
  - `stripeConnectAccountId`
  - `stripeConnectOnboardingComplete`
- **Routing**: Updated to use active facility if no facility is explicitly provided
- **UI**: Settings screen now shows which facility's Stripe Connect account is being managed

### Facility Unit Counts
- **Problem**: Facility document fields (`totalUnits`, `occupiedUnits`) may be stale
- **Solution**: Facility cards now compute counts on-the-fly using `FacilityStatsService.computeUnitCounts()`
- **Future**: Consider adding Cloud Function triggers to update facility document counts automatically

### Billing Enforcement
- **Already implemented**: 
  - `FacilityService.createFacility()` checks subscription status before allowing creation
  - `FacilityCreatorAccountService.addFacilityToAccount()` calls `_syncSubscriptionQuantity()` after adding facility
  - `updateSubscriptionQuantity` Cloud Function updates Stripe subscription quantity based on facility count
- **Flow**:
  1. User creates facility
  2. Facility is added to account via `addFacilityToAccount()`
  3. `_syncSubscriptionQuantity()` is called automatically
  4. Subscription quantity is updated in Stripe (base + add-on items)

## Testing Checklist

### Facility Switcher
- [ ] Facility switcher appears in top bar when user has 2+ facilities
- [ ] Facility switcher does not appear when user has only 1 facility
- [ ] Selecting a facility updates dashboard data
- [ ] Selecting "All Facilities" shows aggregated data
- [ ] Active facility persists after page refresh
- [ ] Active facility syncs across browser tabs

### Dashboard Filtering
- [ ] Dashboard shows data for active facility when one is selected
- [ ] Dashboard shows aggregated data when "All Facilities" is selected
- [ ] Switching facility updates dashboard metrics immediately
- [ ] Unit counts match between dashboard and facility cards

### Stripe Connect
- [ ] Stripe Connect screen shows correct account for active facility
- [ ] Creating Stripe Connect account for one facility doesn't affect other facilities
- [ ] Each facility can have its own Stripe Connect account
- [ ] Settings screen shows which facility's Stripe account is connected

### Facility Unit Counts
- [ ] Facility cards show accurate unit counts (computed on-the-fly)
- [ ] Unit counts match actual units in Firestore
- [ ] Creating a unit updates facility card count
- [ ] Moving tenant in/out updates occupied unit count

### Billing
- [ ] Creating first facility doesn't require subscription
- [ ] Creating second facility requires subscription (trial users blocked)
- [ ] Creating second facility with active subscription updates subscription quantity
- [ ] Subscription quantity = 1 base + (N-1) add-on items for N facilities

## Migration Notes

### For Existing Users
- Existing users will have `activeFacilityId = null` (All Facilities view)
- No data migration needed
- Users can select a facility to filter dashboard

### For New Users
- Default to "All Facilities" view
- First facility creation works without subscription
- Second facility creation requires subscription

## Future Improvements

1. **Cloud Function Triggers**: Add triggers to automatically update `totalUnits` and `occupiedUnits` on facility document when units are created/deleted or tenants move in/out
2. **Facility Context Menu**: Add right-click menu on facility cards to set as active
3. **Keyboard Shortcuts**: Add keyboard shortcuts to switch between facilities
4. **Facility Bookmarks**: Allow users to bookmark frequently used facilities
5. **Bulk Operations**: Support bulk operations across multiple facilities when "All Facilities" is selected
