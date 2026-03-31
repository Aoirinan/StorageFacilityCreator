import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter/material.dart';
import 'package:sfcapp/services/sms_opt_out_admin_service.dart';
import 'package:sfcapp/theme/app_theme.dart';
import 'package:sfcapp/widgets/keyboard_scrollable.dart';

/// Tenants / numbers blocked from SMS (STOP, block list). Staff can re-allow after obtaining consent.
class SmsOptOutsSettingsScreen extends StatefulWidget {
  final String facilityId;

  const SmsOptOutsSettingsScreen({
    super.key,
    required this.facilityId,
  });

  @override
  State<SmsOptOutsSettingsScreen> createState() => _SmsOptOutsSettingsScreenState();
}

class _SmsOptOutsSettingsScreenState extends State<SmsOptOutsSettingsScreen> {
  Future<FacilitySmsOptOutsSnapshot>? _loadFuture;

  @override
  void initState() {
    super.initState();
    _loadFuture = SmsOptOutAdminService.list(widget.facilityId);
  }

  void _reload() {
    setState(() {
      _loadFuture = SmsOptOutAdminService.list(widget.facilityId);
    });
  }

  Future<void> _confirmRestoreTenant(SmsOptedOutTenantRow row) async {
    final phoneForApi = row.phone.trim();
    if (phoneForApi.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('This tenant has no phone on file. Add a phone number before restoring SMS.'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Allow SMS again'),
        content: Text(
          'This clears SMS opt-out for ${row.name} ($phoneForApi) and removes the number from the '
          'facility block list (if present).\n\n'
          'Only do this if the person asked to receive texts again (e.g. they replied START or told your office). '
          'TCPA requires consent for marketing texts.',
          style: Theme.of(ctx).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Allow SMS')),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    try {
      final result = await SmsOptOutAdminService.restore(
        facilityId: widget.facilityId,
        phone: phoneForApi,
        tenantId: row.tenantId,
      );
      if (!mounted) return;
      if (result.ok) {
        final parts = <String>[];
        if (result.tenantRecordUpdated) parts.add('tenant opt-out cleared');
        if (result.removedFromBlockList) parts.add('removed from block list');
        final msg = parts.isEmpty ? 'No changes were necessary.' : parts.join('; ');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: AppTheme.success),
        );
        _reload();
      }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Request failed'), backgroundColor: AppTheme.error),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: AppTheme.error),
      );
    }
  }

  Future<void> _confirmRestoreBlockOnly(BlockListOnlyRow row) async {
    final phoneForApi = (row.normalized != null && row.normalized!.isNotEmpty) ? row.normalized! : row.raw;
    final proceed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove from SMS block list'),
        content: Text(
          'Removes $phoneForApi from the facility SMS block list. '
          'If this number belongs to a tenant who is still marked opted out, use their row under '
          '“Tenants” instead, or clear the tenant record after confirming consent.',
          style: Theme.of(ctx).textTheme.bodyMedium,
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Remove block')),
        ],
      ),
    );
    if (proceed != true || !mounted) return;

    try {
      final result = await SmsOptOutAdminService.restore(
        facilityId: widget.facilityId,
        phone: phoneForApi,
      );
      if (!mounted) return;
      if (result.ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.removedFromBlockList
                  ? 'Number removed from block list.'
                  : 'No matching block list entry (may already be cleared).',
            ),
            backgroundColor: AppTheme.success,
          ),
        );
        _reload();
      }
    } on FirebaseFunctionsException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message ?? 'Request failed'), backgroundColor: AppTheme.error),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$e'), backgroundColor: AppTheme.error),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<FacilitySmsOptOutsSnapshot>(
      future: _loadFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting && !snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snapshot.hasError) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('Could not load: ${snapshot.error}', textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  FilledButton(onPressed: _reload, child: const Text('Retry')),
                ],
              ),
            ),
          );
        }
        final data = snapshot.data!;
        final hasTenants = data.optedOutTenants.isNotEmpty;
        final hasBlockOnly = data.blockListOnly.isNotEmpty;
        final empty = !hasTenants && !hasBlockOnly;

        return KeyboardScrollable(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'SMS opt-outs',
                  style: Theme.of(context).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text(
                  'Tenants who texted STOP (or are marked opted out) and numbers on the facility SMS block list. '
                  'Email opt-outs are managed separately under Email opt-outs.',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
                ),
                const SizedBox(height: 20),
                if (empty)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        'No SMS opt-outs or block list entries for this facility.',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ),
                  ),
                if (hasTenants) ...[
                  Text(
                    'Tenants',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (var i = 0; i < data.optedOutTenants.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          ListTile(
                            title: Text(
                              data.optedOutTenants[i].name,
                              style: const TextStyle(fontWeight: FontWeight.w500),
                            ),
                            subtitle: Text(
                              data.optedOutTenants[i].phone.isNotEmpty
                                  ? '${data.optedOutTenants[i].phone}\n'
                                      '${data.optedOutTenants[i].smsConsentSource ?? 'opted out'}'
                                  : 'No phone on file\n'
                                      '${data.optedOutTenants[i].smsConsentSource ?? 'opted out'}',
                            ),
                            isThreeLine: true,
                            trailing: FilledButton.tonal(
                              onPressed: () => _confirmRestoreTenant(data.optedOutTenants[i]),
                              child: const Text('Allow SMS'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
                if (hasBlockOnly) ...[
                  Text(
                    'Block list only',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'These numbers are blocked but are not tied to an opted-out tenant row above (or the tenant uses a different stored phone format).',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  Card(
                    clipBehavior: Clip.antiAlias,
                    child: Column(
                      children: [
                        for (var i = 0; i < data.blockListOnly.length; i++) ...[
                          if (i > 0) const Divider(height: 1),
                          ListTile(
                            title: Text(
                              data.blockListOnly[i].normalized ?? data.blockListOnly[i].raw,
                              style: const TextStyle(fontWeight: FontWeight.w500),
                            ),
                            subtitle: data.blockListOnly[i].normalized != null &&
                                    data.blockListOnly[i].raw != data.blockListOnly[i].normalized
                                ? Text('Stored as: ${data.blockListOnly[i].raw}')
                                : null,
                            trailing: FilledButton.tonal(
                              onPressed: () => _confirmRestoreBlockOnly(data.blockListOnly[i]),
                              child: const Text('Unblock'),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      },
    );
  }
}
