import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/facility_provider.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/providers/unit_provider.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/widgets/confirm_free_old_unit_dialog.dart';
import 'package:sfcapp/widgets/tenant_facility_unit_picker.dart';

/// The tenant page's Contact Information edit (its pencil): name, email,
/// phone, unit and rate, then the save. Its own function, out of the page,
/// so a test can run it: the page needs Firebase to build.
///
/// Like Edit Tenant, a different unit asks before freeing the one the
/// tenant still holds, and the save's rent notice (the new rent, or a
/// request to check it) is shown.
Future<void> editTenantContactInfo(
  BuildContext context,
  WidgetRef ref,
  TenantModel tenant,
) async {
  final nameCtrl = TextEditingController(text: tenant.name);
  final emailCtrl = TextEditingController(text: tenant.email);
  final phoneCtrl = TextEditingController(text: tenant.phone);
  final unitCtrl = TextEditingController(text: tenant.unitNumber);
  final rateCtrl = TextEditingController(text: tenant.monthlyRate.toString());
  bool smsConsent = tenant.smsOptInDate != null && !tenant.smsOptOut;
  final formKey = GlobalKey<FormState>();
  void disposeAll() {
    nameCtrl.dispose();
    emailCtrl.dispose();
    phoneCtrl.dispose();
    unitCtrl.dispose();
    rateCtrl.dispose();
  }

  final saved = await showDialog<bool>(
    context: context,
    builder: (ctx) => StatefulBuilder(builder: (ctx, setS) => AlertDialog(
      title: const Text('Edit Contact Information'),
      content: SingleChildScrollView(
        child: Form(
          key: formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(controller: nameCtrl, decoration: const InputDecoration(labelText: 'Full Name *', border: OutlineInputBorder(), prefixIcon: Icon(Icons.person)), validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null),
            const SizedBox(height: 12),
            TextFormField(controller: emailCtrl, decoration: const InputDecoration(labelText: 'Email *', border: OutlineInputBorder(), prefixIcon: Icon(Icons.email)), keyboardType: TextInputType.emailAddress, validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Required';
              if (!RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$').hasMatch(v)) return 'Invalid email';
              return null;
            }),
            const SizedBox(height: 12),
            TextFormField(controller: phoneCtrl, decoration: const InputDecoration(labelText: 'Phone *', border: OutlineInputBorder(), prefixIcon: Icon(Icons.phone)), keyboardType: TextInputType.phone, validator: (v) => v == null || v.trim().isEmpty ? 'Required' : null),
            const SizedBox(height: 12),
            TenantFacilityUnitPicker(
              facilityId: tenant.facilityId,
              unitNumberController: unitCtrl,
              monthlyRateController: rateCtrl,
              forTenantId: tenant.id,
            ),
            const SizedBox(height: 12),
            TextFormField(controller: rateCtrl, decoration: const InputDecoration(labelText: 'Monthly Rate *', border: OutlineInputBorder(), prefixIcon: Icon(Icons.attach_money)), keyboardType: TextInputType.number, validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Required';
              if (double.tryParse(v) == null || double.parse(v) <= 0) return 'Invalid rate';
              return null;
            }),
            const SizedBox(height: 12),
            Consumer(builder: (ctx2, ref2, _) {
              final facilityName = ref2.watch(facilityProvider(tenant.facilityId)).value?.name ?? 'this facility';
              return Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(color: AppTheme.backgroundSecondary, borderRadius: BorderRadius.circular(8), border: Border.all(color: AppTheme.borderLight)),
                child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Checkbox(value: smsConsent && !tenant.smsOptOut, onChanged: tenant.smsOptOut ? null : (v) => setS(() => smsConsent = v ?? false)),
                  Expanded(child: Padding(padding: const EdgeInsets.only(top: 10), child: tenant.smsOptOut
                      ? Text('Tenant opted out of SMS.', style: TextStyle(fontSize: 12, color: AppTheme.error))
                      : Text('SMS consent for $facilityName', style: const TextStyle(fontSize: 12)))),
                ]),
              );
            }),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
        FilledButton(onPressed: () { if (formKey.currentState!.validate()) Navigator.pop(ctx, true); }, child: const Text('Save')),
      ],
    )),
  );

  if (saved != true || !context.mounted) { disposeAll(); return; }

  try {
    final notice = await ref.read(tenantOperationsProvider.notifier).updateTenant(
      facilityId: tenant.facilityId, tenantId: tenant.id,
      name: nameCtrl.text.trim(), email: emailCtrl.text.trim(), phone: phoneCtrl.text.trim(),
      unitNumber: unitCtrl.text.trim(), monthlyRate: double.parse(rateCtrl.text.trim()),
      smsOptInDate: smsConsent && !tenant.smsOptOut ? DateTime.now() : null,
      // As in Edit Tenant: a different unit asks before freeing the old one.
      confirmFreeOldUnit: (oldUnitNumber) => confirmFreeOldUnitDialog(context,
          tenantName: tenant.name, oldUnitNumber: oldUnitNumber, newUnitNumber: unitCtrl.text.trim()),
    );
    if (context.mounted) {
      ref.invalidate(facilityTenantsProvider(tenant.facilityId));
      ref.invalidate(facilityUnitsProvider(tenant.facilityId));
      ref.invalidate(unitsForFacilityProvider(tenant.facilityId));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(notice == null ? 'Contact info updated' : 'Contact info updated. $notice'), backgroundColor: AppTheme.success, duration: Duration(seconds: notice == null ? 2 : 8)));
    }
  } catch (e) {
    if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: AppTheme.error));
  }
  disposeAll();
}
