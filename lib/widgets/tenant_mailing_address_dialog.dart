import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:sfcapp/models/address_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/providers/tenant_provider.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/utils/mailing_address_edit.dart';

/// The tenant page's Mailing Address edit (its pencil): the dialog, then the
/// save. Its own function, out of the page, so a test can run it: the page
/// needs Firebase to build.
///
/// Its own dialog rather than a field in Edit Contact Information: most
/// tenants at a paper-ledger facility have a mailing address and no email,
/// and this is the one thing the owner opens to fix before printing a
/// statement.
Future<void> editTenantMailingAddress(
  BuildContext context,
  WidgetRef ref,
  TenantModel tenant,
) async {
  final result = await showTenantMailingAddressDialog(
    context,
    current: currentMailingAddress(tenant.addresses),
  );
  if (result == null || !context.mounted) return;

  try {
    await ref.read(tenantOperationsProvider.notifier).setMailingAddress(
          facilityId: tenant.facilityId,
          tenantId: tenant.id,
          addresses: replaceMailingAddress(tenant.addresses, result, DateTime.now()),
        );
    if (context.mounted) {
      ref.invalidate(facilityTenantsProvider(tenant.facilityId));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(result.isBlank ? 'Mailing address removed' : 'Mailing address updated'),
        backgroundColor: AppTheme.success,
        duration: const Duration(seconds: 2),
      ));
    }
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString()), backgroundColor: AppTheme.error));
    }
  }
}

/// "Edit Mailing Address": Street, Apt / Suite, City, State and ZIP, filled
/// from [current]. Returns the fields to save, [MailingAddressFields.none]
/// for Remove (offered only when there is a [current] address), or null
/// when cancelled.
Future<MailingAddressFields?> showTenantMailingAddressDialog(
  BuildContext context, {
  Address? current,
}) {
  return showDialog<MailingAddressFields>(
    context: context,
    builder: (_) => _MailingAddressDialog(current: current),
  );
}

class _MailingAddressDialog extends StatefulWidget {
  final Address? current;

  const _MailingAddressDialog({required this.current});

  @override
  State<_MailingAddressDialog> createState() => _MailingAddressDialogState();
}

class _MailingAddressDialogState extends State<_MailingAddressDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _street = TextEditingController(text: widget.current?.street1 ?? '');
  late final _street2 = TextEditingController(text: widget.current?.street2 ?? '');
  late final _city = TextEditingController(text: widget.current?.city ?? '');
  late final _state = TextEditingController(text: widget.current?.state ?? '');
  late final _zip = TextEditingController(text: widget.current?.zipCode ?? '');

  @override
  void dispose() {
    _street.dispose();
    _street2.dispose();
    _city.dispose();
    _state.dispose();
    _zip.dispose();
    super.dispose();
  }

  // City, state and ZIP are required along with the street: a street-only
  // address (what a workbook import often leaves) cannot be mailed to, and
  // the owner opens this to make the statement deliverable.
  String? _required(String? v) => v == null || v.trim().isEmpty ? 'Required' : null;

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    Navigator.pop(
      context,
      MailingAddressFields(
        street1: _street.text,
        street2: _street2.text,
        city: _city.text,
        state: _state.text,
        zipCode: _zip.text,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Edit Mailing Address'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            TextFormField(
              key: const Key('mailing-address-street'),
              controller: _street,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Street *',
                hintText: '123 Main St or PO Box 12',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.home_outlined),
              ),
              validator: _required,
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('mailing-address-street2'),
              controller: _street2,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Apt / Suite',
                helperText: 'Optional',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.apartment_outlined),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('mailing-address-city'),
              controller: _city,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'City *',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.location_city_outlined),
              ),
              validator: _required,
            ),
            const SizedBox(height: 12),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(
                child: TextFormField(
                  key: const Key('mailing-address-state'),
                  controller: _state,
                  textCapitalization: TextCapitalization.characters,
                  decoration: const InputDecoration(
                    labelText: 'State *',
                    border: OutlineInputBorder(),
                  ),
                  validator: _required,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                flex: 2,
                child: TextFormField(
                  key: const Key('mailing-address-zip'),
                  controller: _zip,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: 'ZIP *',
                    border: OutlineInputBorder(),
                  ),
                  validator: _required,
                  onFieldSubmitted: (_) => _save(),
                ),
              ),
            ]),
          ]),
        ),
      ),
      actions: [
        if (widget.current != null)
          TextButton(
            key: const Key('mailing-address-remove'),
            onPressed: () => Navigator.pop(context, MailingAddressFields.none),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            child: const Text('Remove'),
          ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          key: const Key('mailing-address-save'),
          onPressed: _save,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
