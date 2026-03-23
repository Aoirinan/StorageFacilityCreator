# Facility Map Overhaul Plan (V2)

## Goals
- Ship a non-breaking map engine upgrade with feature-flagged rollout.
- Keep unit/rental/pricing/availability systems as source of truth.
- Add draft/published/rollback publishing model for maps.
- Publish a safe public map snapshot with stable URL.
- Route available units into the existing rental flow with unit preselected.
- Add a short checkout hold to reduce double-booking risk.

## Guardrails
- Preserve legacy `/units/map` behavior unless v2 is enabled.
- Do not move business authority (status, occupancy, pricing) into map documents.
- Reuse existing `UnitService`, `MoveInWizard`, public reservation flow, and feature flag infrastructure.
- Keep Firestore rule changes additive and least-privilege.

## Existing Baseline
- Current editor: `FacilityMapEditorScreen` writing to `facilities/{facilityId}/mapShapes`.
- Public rental entry: `/rental?facilityId=...` with reservation records in `publicReservations`.
- Move-in completion: Cloud Function `completePublicMoveIn`.
- Feature flags: `appConfig/featureFlags`.

## V2 Architecture

### 1) Data model (additive)
- `facilities/{facilityId}/mapEngine/meta`
  - `publicSlug`
  - `activePublishedVersionId`
  - `activeDraftSource` (`legacyMapShapes`)
  - `enabledForFacility`
  - `statusColorConfig`
  - timestamps
- `facilities/{facilityId}/mapEngine/versions/{versionId}`
  - `facilityId`, `versionNumber`, `status` (`draft|published|archived`)
  - `elements` (rectangle-first map elements linked to `unitId`)
  - `mapSettings` (grid/background/display config)
  - publish metadata
- `publicFacilityMaps/{facilitySlug}`
  - safe public read-model only
  - `facilityId`, `facilitySlug`, `publishedVersionId`, `publishedAt`
  - `elements` (public-safe)
  - `units` (public-safe denormalized display fields)
  - `rentalRouteTemplate`, public settings

### 2) Experience surfaces
- **Admin Builder (v2):** wraps existing editor + publish/rollback/version history + public URL.
- **Internal Operations Map (v2):** read-only ops map using published/draft geometry + live unit statuses, deep links to unit detail and move-in.
- **Public Published Map:** `/public/:facilitySlug/map`, reads only `publicFacilityMaps/{slug}`.

### 3) Feature rollout
- Global flag: `mapEngineV2`.
- Facility-level toggle in `mapEngine/meta.enabledForFacility`.
- Router keeps legacy screen path and conditionally switches to v2.

### 4) Hold/checkout safety
- Add callable function to create a short reservation hold (default 10 min) with transaction-backed unit status validation and active hold conflict checks.
- Route public map CTA through hold creation and then existing `/public-move-in?token=...`.
- Keep final availability validation at move-in completion in existing backend.

## Implementation Phases

### Phase A: Foundation
- Add v2 models/services (`facility_map_v2_*`).
- Add public snapshot service and slug/URL generation.
- Add publish + rollback + version history operations.

### Phase B: UI Integration
- Add v2 map entry screen behind flags.
- Add admin builder v2 controls (publish/rollback/copy URL/history).
- Add internal operations map screen.

### Phase C: Public Experience
- Add public map route and screen.
- Add list fallback view for available units.
- Add Rent Now -> existing rental flow handoff with preselected unit.

### Phase D: Hold Integration
- Add callable hold function and Dart client integration.
- Update public reservation flow to use short hold for map-initiated checkout.

### Phase E: Rules + Verification
- Add Firestore rules for mapEngine docs (owner/manager only).
- Add read-only public access to snapshot collection.
- Run analyzer/lints for touched files.
- Manual verification checklist for compatibility and rollout.

## Manual Acceptance Checklist
- Legacy map route still works when v2 disabled.
- V2 enabled facility can edit map using existing builder interactions.
- Publish creates immutable version + public snapshot.
- Draft edits after publish do not affect public map until republish.
- Rollback re-publishes prior version.
- Public map shows only safe fields and no tenant/private data.
- Rent Now from available unit enters existing flow with correct unit preselected.
- Unavailable/rented units are non-rentable on public map.
- Hold expires and prevents obvious simultaneous take.
