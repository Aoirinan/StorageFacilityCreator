import 'package:flutter/widgets.dart';
import 'package:go_router/go_router.dart';

import 'package:sfcapp/models/contract_model.dart';
import 'package:sfcapp/models/lien_model.dart';
import 'package:sfcapp/models/payment_model.dart';
import 'package:sfcapp/models/tenant_model.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/router/load_by_id.dart';
import 'package:sfcapp/router/route_helpers.dart';
import 'package:sfcapp/screens/client_detail_screen.dart';
import 'package:sfcapp/screens/contract_detail_screen.dart';
import 'package:sfcapp/screens/ledger_screen.dart';
import 'package:sfcapp/screens/lien_detail_screen.dart';
import 'package:sfcapp/screens/payment_detail_screen.dart';
import 'package:sfcapp/services/contract_service.dart';
import 'package:sfcapp/services/lien_service.dart';
import 'package:sfcapp/services/payment_service.dart';
import 'package:sfcapp/services/tenant_service.dart';
import 'package:sfcapp/widgets/tenant_prev_next.dart';

// The detail routes that open with their model as `extra` or load it by id.
// app_router.dart uses these as they are. Tests pass their own loader and a
// stand-in page (the real screens need Firebase) and so run the same
// routes, rather than a copy that could drift from them.

Widget _clientDetailPage(TenantModel tenant) => ClientDetailScreen(tenant: tenant);

Widget _ledgerPage(TenantModel tenant) => LedgerScreen(tenant: tenant);

Widget _contractDetailPage(ContractModel contract) =>
    ContractDetailScreen(contract: contract);

Widget _paymentDetailPage(PaymentModel payment) =>
    PaymentDetailScreen(payment: payment);

Widget _lienDetailPage(LienModel lien, String facilityId) =>
    LienDetailScreen(lien: lien, facilityId: facilityId);

Future<PaymentModel?> _loadPayment(String facilityId, String paymentId) =>
    PaymentService.getPayment(facilityId: facilityId, paymentId: paymentId);

Future<LienModel?> _loadLien(String facilityId, String lienId) =>
    LienService.getLien(facilityId: facilityId, lienId: lienId);

// A document written without a facilityId field reads back with ''. The
// pages act through model.facilityId (process a payment, the ledger's back
// arrow, the contract's actions), so those failed on a page opened by id. It
// was read from the facility in the link, so that is the one it belongs to.

TenantModel _tenantIn(TenantModel tenant, String facilityId) =>
    tenant.facilityId.isEmpty ? tenant.copyWith(facilityId: facilityId) : tenant;

// A tenant's page or ledger, with previous / next tenant on the arrow keys.
// Keyed by tenant: previous / next replace the page in place (same route,
// same page key), and without a key the next tenant's page reused the last
// one's State: its DNR result, its ledger filters, its running balance.

Widget _tenantDetail(
  TenantModel tenant,
  Widget Function(TenantModel tenant) page,
) {
  return KeyedSubtree(
    key: ValueKey('tenant-detail/${tenant.facilityId}/${tenant.id}'),
    child: TenantPrevNextShortcuts(
      tenant: tenant,
      page: TenantPage.detail,
      child: page(tenant),
    ),
  );
}

Widget _tenantLedger(
  TenantModel tenant,
  Widget Function(TenantModel tenant) page,
) {
  return KeyedSubtree(
    key: ValueKey('tenant-ledger/${tenant.facilityId}/${tenant.id}'),
    child: TenantPageFollowsLedger(
      tenant: tenant,
      child: TenantPrevNextShortcuts(
        tenant: tenant,
        page: TenantPage.ledger,
        child: page(tenant),
      ),
    ),
  );
}

ContractModel _contractIn(ContractModel contract, String facilityId) =>
    contract.facilityId.isEmpty
        ? contract.copyWith(facilityId: facilityId)
        : contract;

PaymentModel _paymentIn(PaymentModel payment, String facilityId) =>
    payment.facilityId.isEmpty
        ? payment.copyWith(facilityId: facilityId)
        : payment;

/// The tenant's page: the tenant as `extra` from the list, or by id from the
/// Calendar, Unit detail's View Details, the Dashboard and the ledger.
GoRoute tenantDetailRoute({
  LoadInFacility<TenantModel> load = TenantService.getTenantById,
  Widget Function(TenantModel tenant) page = _clientDetailPage,
}) {
  return GoRoute(
    path: AppRoute.tenantDetail,
    name: 'tenant-detail',
    builder: (context, state) {
      final tenantExtra = state.extra;
      if (tenantExtra is TenantModel) return _tenantDetail(tenantExtra, page);
      return loadByIdPage<TenantModel>(
        state,
        idParam: 'tenantId',
        load: load,
        page: (tenant, facilityId) =>
            _tenantDetail(_tenantIn(tenant, facilityId), page),
      );
    },
  );
}

/// The tenant's ledger: the tenant as `extra` from the tenant's page, or by
/// the facilityId query parameter (not found without one).
GoRoute tenantLedgerRoute({
  LoadInFacility<TenantModel> load = TenantService.getTenantById,
  Widget Function(TenantModel tenant) page = _ledgerPage,
}) {
  return GoRoute(
    path: '/tenants/:tenantId/ledger',
    name: 'tenant-ledger',
    builder: (context, state) {
      final tenantId = state.pathParameters['tenantId'];
      if (tenantId == null) return NotFoundPage(state: state);
      final tenantExtra = state.extra;
      if (tenantExtra is TenantModel) return _tenantLedger(tenantExtra, page);
      return loadByIdPage<TenantModel>(
        state,
        idParam: 'tenantId',
        id: tenantId,
        load: load,
        page: (tenant, facilityId) =>
            _tenantLedger(_tenantIn(tenant, facilityId), page),
      );
    },
  );
}

/// A contract: as `extra` from the list, or by id from the Calendar's
/// contract events and the Dashboard's move-outs.
GoRoute contractDetailRoute({
  LoadInFacility<ContractModel> load = ContractService.getContract,
  Widget Function(ContractModel contract) page = _contractDetailPage,
}) {
  return GoRoute(
    path: AppRoute.contractDetail,
    name: 'contract-detail',
    builder: (context, state) {
      final contract = state.extra;
      if (contract is ContractModel) return page(contract);
      return loadByIdPage<ContractModel>(
        state,
        idParam: 'contractId',
        load: load,
        page: (contract, facilityId) =>
            page(_contractIn(contract, facilityId)),
      );
    },
  );
}

/// A payment: as `extra` from the lists, or by id from the invoice and
/// deposit pages.
GoRoute paymentDetailRoute({
  LoadInFacility<PaymentModel> load = _loadPayment,
  Widget Function(PaymentModel payment) page = _paymentDetailPage,
}) {
  return GoRoute(
    path: AppRoute.paymentDetail,
    name: 'payment-detail',
    builder: (context, state) {
      final payment = state.extra;
      if (payment is PaymentModel) return page(payment);
      return loadByIdPage<PaymentModel>(
        state,
        idParam: 'paymentId',
        load: load,
        page: (payment, facilityId) => page(_paymentIn(payment, facilityId)),
      );
    },
  );
}

/// A lien: `{'lien': ..., 'facilityId': ...}` as `extra` from the lien list,
/// or by id from the Calendar's lien and auction events.
GoRoute lienDetailRoute({
  LoadInFacility<LienModel> load = _loadLien,
  Widget Function(LienModel lien, String facilityId) page = _lienDetailPage,
}) {
  return GoRoute(
    path: AppRoute.lienDetail,
    name: 'lien-detail',
    builder: (context, state) {
      final extra = state.extra;
      if (extra is Map<String, dynamic>) {
        final lien = extra['lien'];
        final facilityId = extra['facilityId'];
        if (lien is LienModel && facilityId is String) {
          return page(lien, facilityId);
        }
      }
      return loadByIdPage<LienModel>(
        state,
        idParam: 'lienId',
        load: load,
        page: page,
      );
    },
  );
}
