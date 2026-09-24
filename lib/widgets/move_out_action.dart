import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import 'package:sfcapp/models/contract_model.dart';
import 'package:sfcapp/models/provider_params.dart';
import 'package:sfcapp/providers/contract_provider.dart';
import 'package:sfcapp/providers/permission_provider.dart';
import 'package:sfcapp/router/app_route.dart';

// The way into the move-out screen. Nothing linked to it, so an owner could
// not run a move-out (contract ended, tenant inactive, unit freed, gate code
// off, move-out charges) from the app at all: only Unassign Tenant, which
// does none of the contract or charges.

/// The contracts a move-out can be run on: processMoveOut refuses an
/// inactive contract and does nothing again for one already moved out, and a
/// cancelled contract has ended.
List<ContractModel> contractsOpenForMoveOut(Iterable<ContractModel> contracts) =>
    contracts
        .where((c) =>
            c.isActive &&
            c.moveOutStatus != MoveOutStatus.completed &&
            c.status != ContractStatus.cancelled)
        .toList();

/// Opens the move-out screen for one of [contracts] at [facilityId]: straight
/// there when one is open, after a choice when several are. [unitId] is the
/// unit being vacated, when the caller knows it. True when the screen
/// finished a move-out.
Future<bool> startMoveOut(
  BuildContext context, {
  required String facilityId,
  required Iterable<ContractModel> contracts,
  String? unitId,
}) async {
  final open = contractsOpenForMoveOut(contracts);
  if (open.isEmpty) return false;
  final contract = open.length == 1
      ? open.single
      : await showDialog<ContractModel>(
          context: context,
          builder: (context) => SimpleDialog(
            title: const Text('Move out from which contract?'),
            children: [
              for (final c in open)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(context, c),
                  child: ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(c.title),
                    subtitle: Text(
                        '${c.status.displayName} · created ${DateFormat.yMMMd().format(c.createdAt)}'),
                  ),
                ),
            ],
          ),
        );
  if (contract == null || !context.mounted) return false;
  final finished = await context.push<bool>(AppRoute.moveOutFor(
    contractId: contract.id,
    facilityId: facilityId,
    unitId: unitId,
  ));
  return finished == true;
}

/// Move out, on the tenant's page: shown to those who may run one, while
/// the tenant has a contract open for it.
class TenantMoveOutButton extends ConsumerWidget {
  final String facilityId;
  final String tenantId;

  /// After a finished move-out, for the page to re-read the tenant.
  final VoidCallback? onMovedOut;

  const TenantMoveOutButton({
    super.key,
    required this.facilityId,
    required this.tenantId,
    this.onMovedOut,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final allowed =
        ref.watch(canProcessMoveOutAtFacilityProvider(facilityId)).value ?? false;
    if (!allowed) return const SizedBox.shrink();
    final params = FacilityTenantParams(facilityId: facilityId, tenantId: tenantId);
    final open = contractsOpenForMoveOut(
        ref.watch(tenantContractsProvider(params)).value ?? const []);
    if (open.isEmpty) return const SizedBox.shrink();
    return OutlinedButton.icon(
      onPressed: () async {
        final finished = await startMoveOut(
          context,
          facilityId: facilityId,
          contracts: open,
        );
        if (!finished || !context.mounted) return;
        ref.invalidate(tenantContractsProvider(params));
        onMovedOut?.call();
      },
      icon: const Icon(Icons.logout, size: 20),
      label: const Text('Move out'),
    );
  }
}
