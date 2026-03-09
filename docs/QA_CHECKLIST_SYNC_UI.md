# Manual QA Checklist – Data-Sync & UI Fixes

Use this after deploying the SFC data-sync and UI fixes.

## Facility totals

- [ ] Create or edit a facility with **totalUnits = 200**. Save.
- [ ] **Facilities list**: Card shows `X/200 units occupied` (not a different total).
- [ ] **Dashboard**: Totals use 200 as the facility’s total (e.g. occupancy %).
- [ ] **Unit List**: Header shows `X / 200 units` for that facility.

## Tenants and units

- [ ] Add tenants and assign them to units. **Unit List** and **Manager Overlock** show correct names and counts.
- [ ] **Delete a tenant** (from Tenants/Client list):  
  - Tenant disappears from Unit List and Manager Overlock.  
  - Unit shows as available (or no tenant name).  
  - Counts (occupied/total) update everywhere.
- [ ] **Unassign tenant from unit** (Unit Details → Unassign, or Unit List row action if added):  
  - Tenant record still exists in Tenants.  
  - Unit becomes available; counts update.  
  - Manager Overlock no longer shows that unit with that tenant.

## Map editor

- [ ] **Tooltip**: Hover on a unit; tenant name and text wrap **horizontally** (no vertical stacked letters).
- [ ] **Button**: Label is **“Add Unit”** (not “Add Rectangle”).
- [ ] Unit dimensions/sizes persist and are editable where implemented.

## Contracts

- [ ] **Contracts tab**: No “View Map” button.
- [ ] **Templates** (Contract Templates): Only **one** sidebar/nav (no duplicated dashboards/facilities).
- [ ] **“Add default templates”** and **“Create template”** are different:  
  - Add default → seeds predefined templates.  
  - Create template → opens builder/upload.
- [ ] **New Contract**: Select facility; tenant dropdown shows **current (active) tenants** for that facility. No “No tenants found” when tenants exist.

## Manager Overlock

- [ ] Only **current** tenants/units for the selected facility (no deleted/historical tenants).
- [ ] After deleting or unassigning a tenant, list updates (no ghost entries).

## Settings

- [ ] **Notifications**: One place for notification settings; toggles persist and affect behavior.
- [ ] **Appearance**: Change theme (light/dark/system); refresh page; theme is still applied and persisted.

## AI Assistant

- [ ] Guardrails are slightly relaxed (configurable); safety filters still apply.
