# Stage 6 Release Notes: Fine-Grained RBAC
**Date:** January 23, 2026  
**Stage:** 6 of 8  
**Status:** ✅ Implementation Complete

---

## Overview

Stage 6 implements fine-grained role-based access control (RBAC) with new permission types and UI gating. Adds `manageTemplates` and `manageAutomation` permissions, creates reusable permission gating widgets, and adds permission checks to key screens. All features are behind feature flags and default to OFF, preserving existing production behavior.

---

## What Changed

### 1. New Permission Types
- **New Permissions:**
  - `manageTemplates` - Manage email/SMS/contract templates
  - `manageAutomation` - Manage automation rules, workflows, schedules

### 2. Permission Model Updates
- **Updated:** `lib/models/permission_model.dart`
- Added `manageTemplates` and `manageAutomation` to `PermissionType` enum
- Added display names for new permissions

### 3. Role Definitions Updated
- **Updated:** `lib/services/permission_service.dart`
- Manager role now includes `manageTemplates` and `manageAutomation`
- Owner role has all permissions (unchanged)
- Employee and Viewer roles unchanged (no template/automation access)

### 4. Permission Gating Widgets
- **New Widget:** `lib/widgets/permission_gate.dart`
- `PermissionGate` - Hides/shows content based on permissions
- `PermissionButton` - Disables buttons based on permissions
- Helper functions for permission checks

### 5. UI Gating Implementation
- **Updated Screens:**
  - `lib/screens/exports_screen.dart` - Export button gated with `exportData` permission
  - `lib/screens/automation_preview_screen.dart` - Execute button gated with `manageAutomation` permission
  - Template screens can be gated with `manageTemplates` (to be added per screen)

### 6. Feature Flag System
- **New Firestore Document:** `appConfig/fineGrainedRBAC`
- **Flags:**
  - `enabled` (default: false)
  - `allowlistFacilityIds` (default: [])
  - `killSwitch` (default: false)

### 7. Cloud Functions Feature Flags
- **Updated:** `functions/src/index.ts`
- Added `getFineGrainedRBACConfig()` function
- Added `isFineGrainedRBACEnabled()` helper
- Ready for use in Cloud Functions (not yet enforced)

---

## Files Modified

### Models
- `lib/models/permission_model.dart`
  - Added `manageTemplates` and `manageAutomation` permissions
  - Added display names

### Services
- `lib/services/permission_service.dart`
  - Updated manager role to include new permissions

### Widgets
- `lib/widgets/permission_gate.dart` - NEW (~150 lines)
  - Permission gating widgets
  - Helper functions

### UI Screens
- `lib/screens/exports_screen.dart`
  - Added permission gate to export button

- `lib/screens/automation_preview_screen.dart`
  - Added permission gate to execute button

### Cloud Functions
- `functions/src/index.ts`
  - Added feature flag system (~50 lines)

---

## Safety & Backward Compatibility

### ✅ All Changes Are Additive
- New permissions are optional (feature flags default to OFF)
- Existing role-based checks continue to work
- No changes to existing data structures

### ✅ Fail-Safe Behavior
- Permission checks fail gracefully (return false if error)
- UI widgets hide content if permission denied (default behavior)
- Existing users retain access (backward compatible)

### ✅ No Breaking Changes
- No changes to existing API contracts
- No changes to existing Firestore rules (yet)
- Permission system is opt-in via feature flags

---

## Deployment Steps

### 1. Deploy Cloud Functions
```bash
cd functions
npm run build
firebase deploy --only functions
```

### 2. Deploy Flutter App
```bash
flutter build web --release
firebase deploy --only hosting
```

### 3. Create Feature Flag Document
Create `appConfig/fineGrainedRBAC` in Firestore:
```json
{
  "enabled": false,
  "allowlistFacilityIds": [],
  "killSwitch": false
}
```

### 4. Test with Allowlist Facility
1. Add test facility ID to `allowlistFacilityIds`
2. Enable `enabled` flag
3. Test permission gating:
   - Export screen → verify export button hidden if no permission
   - Automation preview → verify execute button hidden if no permission
   - Template screens → verify create/edit buttons hidden if no permission

### 5. Monitor for 24-48 Hours
- Monitor permission check performance
- Verify UI gating works correctly
- Check that existing users still have access

### 6. Enable Globally (If Stable)
Update `appConfig/fineGrainedRBAC`:
```json
{
  "enabled": true,
  "allowlistFacilityIds": [],
  "killSwitch": false
}
```

---

## Rollback Steps

### Quick Rollback (Feature Flags)
Set `enabled: false` in `appConfig/fineGrainedRBAC`:
```json
{
  "enabled": false,
  "killSwitch": false
}
```

### Full Rollback (If Needed)
1. Revert Flutter app deployment:
   ```bash
   git revert <commit-hash>
   flutter build web --release
   firebase deploy --only hosting
   ```
2. Revert Cloud Functions (if needed):
   ```bash
   firebase functions:rollback
   ```

**Note:** Permission checks will still run but will return false if feature is disabled.

---

## Testing Checklist

### Manual Testing (UI)
- [ ] Navigate to Exports screen → verify export button visible/hidden based on permission
- [ ] Navigate to Automation Preview → verify execute button visible/hidden based on permission
- [ ] Test with different roles (owner, manager, employee, viewer)
- [ ] Verify permission gates hide content when permission denied
- [ ] Verify permission gates show content when permission granted

### Integration Testing
- [ ] Verify permission checks work correctly
- [ ] Verify feature flag enable/disable works
- [ ] Verify backward compatibility (existing users have access)

### Production Verification
- [ ] Monitor permission check performance (should be fast)
- [ ] Verify no UI flickering (permission checks should be cached)
- [ ] Verify existing users retain access
- [ ] Verify new permission system doesn't break existing functionality

---

## Permission Matrix

### Owner
- ✅ All permissions (including new ones)

### Manager
- ✅ `manageTemplates` - Can manage templates
- ✅ `manageAutomation` - Can manage automation
- ✅ `exportData` - Can export data
- ✅ All existing manager permissions

### Employee
- ❌ `manageTemplates` - No template management
- ❌ `manageAutomation` - No automation management
- ❌ `exportData` - No export access
- ✅ Existing employee permissions (view/edit tenants, create payments)

### Viewer
- ❌ All write permissions
- ✅ Read-only access

---

## Configuration Guide

### Enabling Fine-Grained RBAC
1. Set `enabled: true` in `appConfig/fineGrainedRBAC`
2. Permission gating will be enforced
3. UI will hide/show content based on permissions

### Per-Facility Enablement
1. Add facility ID to `allowlistFacilityIds` array
2. Fine-grained RBAC will be enabled for that facility only
3. Useful for gradual rollout

### Disabling Fine-Grained RBAC
1. Set `enabled: false` in `appConfig/fineGrainedRBAC`
2. System falls back to existing role-based checks
3. All users retain access based on their roles

---

## Known Limitations

1. **Firestore Rules:** Fine-grained permission checks not yet added to Firestore rules (client-side enforcement only)
2. **Performance:** Permission checks are async (FutureBuilder) - may cause slight UI delay
3. **Caching:** Permission checks are not cached (each widget checks independently)
4. **Template Screens:** Not all template screens have permission gating yet (can be added incrementally)

---

## Next Steps

After Stage 6 is stable:
- Proceed to Stage 7: 2FA, Lead Pipeline, Work Orders, Portal Upgrades
- Add permission gating to remaining template screens
- Add Firestore rules for fine-grained permissions (optional)
- Consider caching permission checks for better performance

---

## Support

For questions or issues:
- Check feature flag configuration
- Review permission assignments in user_roles collection
- Verify role definitions in PermissionService
- Check UI widget implementation
- Contact support if issues persist

---

**Status:** ✅ Ready for Testing  
**Next Stage:** Stage 7 (2FA, Lead Pipeline, Work Orders, Portal Upgrades)
