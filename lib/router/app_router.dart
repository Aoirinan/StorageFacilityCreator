import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'dart:async';
import 'dart:convert';

import '../providers/auth_provider.dart';
import '../providers/active_facility_provider.dart';
import '../providers/facility_provider.dart';
import 'app_route.dart';
import 'route_guards.dart';
import 'route_helpers.dart';
import '../services/modern_navigation_service.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/signup_screen.dart';
import '../screens/auth/forgot_password_screen.dart';
import '../screens/auth/email_verification_screen.dart';
import '../screens/tenant_portal_access_screen.dart';
import '../screens/contract_signing_screen.dart';
import '../screens/accept_invite_screen.dart';
import '../screens/facility_management_screen.dart';
import '../screens/client_list_screen.dart';
import '../screens/public_facility_map_screen.dart';
import '../screens/units_map_entry_screen.dart';
import '../screens/unit_list_screen.dart';
import '../screens/manager_overlock_screen.dart';
import '../screens/tenant_csv_import_wizard_screen.dart';
import '../screens/home_screen_modern.dart';
import '../screens/contract_list_screen.dart';
import '../screens/payment_list_screen.dart';
import '../screens/insurance_screen.dart';
import '../screens/messaging_screen.dart';
import '../screens/sms_conversations_screen.dart';
import '../screens/gate_access_screen.dart';
import '../screens/settings_screen.dart';
import '../screens/texting_setup_screen.dart';
import '../screens/permission_management_screen.dart';
import '../screens/ai_assistant_screen.dart';
import '../screens/stripe_connect_onboarding_screen.dart';
import '../models/facility_model.dart';
import '../screens/financial_reports_screen.dart';
import '../screens/yield_management_screen.dart';
import '../screens/reminder_list_screen.dart';
import '../screens/dnr_list_screen.dart';
import '../screens/facility_creation_wizard.dart';
import '../widgets/global_home_overlay.dart';
import '../screens/late_dashboard_screen.dart';
import '../screens/subscription_test_screen.dart';
import '../screens/billing_and_payments_screen.dart';
import '../models/tenant_model.dart';
import '../models/payment_model.dart';
import '../screens/payment_detail_screen.dart';
import '../screens/reminder_creation_screen.dart';
import '../screens/reminder_detail_screen.dart';
import '../screens/reminder_schedule_screen.dart';
import '../screens/contract_detail_screen.dart';
import '../screens/contract_creation_screen.dart';
import '../screens/contract_template_management_screen.dart';
import '../screens/create_contract_template_screen.dart';
import '../screens/edit_contract_template_screen.dart';
import '../screens/lease_templates_screen.dart';
import '../screens/payment_creation_screen.dart';
import '../screens/payment_reconciliation_screen.dart';
import '../models/contract_model.dart';
import '../models/contract_template_model.dart';
import '../models/unit_model.dart';
import '../screens/client_detail_screen.dart';
import '../models/reminder_model.dart';
import '../screens/data_integrity_screen.dart';
import '../screens/contract_signing_test_screen.dart';
import '../screens/ledger_screen.dart';
import '../screens/move_in_wizard_screen.dart';
import '../screens/invoice_list_screen.dart';
import '../screens/invoice_detail_screen.dart';
import '../models/invoice_model.dart';
import '../screens/recurring_charges_screen.dart';
import '../screens/automation_preview_screen.dart';
import '../screens/deposit_list_screen.dart';
import '../screens/deposit_detail_screen.dart';
import '../screens/deposit_creation_screen.dart';
import '../models/deposit_model.dart';
import '../screens/move_out_screen.dart';
import '../screens/lien_list_screen.dart';
import '../screens/lien_detail_screen.dart';
import '../models/lien_model.dart';
import '../screens/inventory_list_screen.dart';
import '../screens/pos_screen.dart';
import '../screens/reports_consolidated_screen.dart';
import '../screens/contact_logs_screen.dart';
import '../screens/audit_log_screen.dart';
import '../screens/exports_screen.dart';
import '../screens/transfer_workflow_screen.dart';
import '../screens/document_attachments_screen.dart';
import '../screens/unit_detail_screen.dart';
import '../screens/unit_creation_screen.dart';
import '../screens/insurance_settings_screen.dart';
import '../screens/claims_list_screen.dart';
import '../screens/claim_detail_screen.dart';
import '../screens/insurance_report_screen.dart';
import '../screens/notification_settings_screen.dart';
import '../screens/profile_edit_screen.dart';
import '../screens/appearance_settings_screen.dart';
import '../screens/bulk_messaging_screen.dart';
import '../services/subscription_guard_service.dart';
import '../services/tenant_service.dart';
import '../widgets/subscription_warning_banner.dart';
import '../widgets/messaging_facility_selector.dart';
import '../screens/email_template_management_screen.dart';
import '../screens/sms_template_management_screen.dart';
import '../screens/public_payment_screen.dart';
import '../screens/public_rental_portal_screen.dart';
import '../screens/public_facility_page_screen.dart';
import '../screens/public_move_in_screen.dart';
import '../screens/payment_links_management_screen.dart';
import '../screens/report_scheduling_management_screen.dart';
import '../screens/report_scheduling_editor_screen.dart';
import '../screens/email_sequence_management_screen.dart';
import '../screens/email_sequence_editor_screen.dart';
import '../screens/api_keys_management_screen.dart';
import '../screens/api_key_creation_screen.dart';
import '../screens/webhooks_management_screen.dart';
import '../screens/webhook_editor_screen.dart';
import '../screens/coupon_management_screen.dart';
import '../screens/communication_analytics_screen.dart';
import '../screens/document_center_screen.dart';
import '../screens/escalation_workflow_management_screen.dart';
import '../screens/conditional_rules_management_screen.dart';
import '../screens/facility_calendar_screen.dart';
import '../screens/pending_approval_screen.dart';
import '../models/document_attachment_model.dart';
import '../screens/marketing_landing_page.dart';
import '../screens/sms_policy_screen.dart';
import '../screens/contact_screen.dart';
import '../screens/auth/privacy_screen.dart';
import '../screens/auth/terms_screen.dart';
import '../screens/super_admin/super_admin_screen.dart';
import '../providers/feature_flag_provider.dart';
// NOTE: Route constants, guards, and helpers are now in separate files:
// - app_route.dart: Route constants
// - route_guards.dart: Route guard logic (includes subscription cache)
// - route_helpers.dart: Helper widgets (NotFoundPage, AppShell, etc.)
// - public_routes.dart: Public route definitions

// Route constants, guards, and helpers are now in separate files:
// - app_route.dart: Route constants (AppRoute class)
// - route_guards.dart: Route guard logic
// - route_helpers.dart: Helper widgets (NotFoundPage, AppShell, GoRouterRefreshStream, etc.)
// - public_routes.dart: Public route definitions

// Additional landing screens that are specific to this router file
class DelinquencyShellScreen extends StatelessWidget {
  const DelinquencyShellScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const LateDashboardScreen();
  }
}

/// Main router provider
///
/// NOTE: This file has been partially modularized. Route constants, guards, and helpers
/// are in separate files. The routes array is still here but will be further modularized.
final goRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: AppRoute.landing,
    debugLogDiagnostics: kDebugMode,
    refreshListenable:
        GoRouterRefreshStream(FirebaseAuth.instance.authStateChanges()),
    redirect: (context, state) => routeGuard(context, state, ref),
    errorBuilder: (context, state) => NotFoundPage(state: state),
    routes: [
      GoRoute(
        path: AppRoute.landing,
        name: 'landing',
        builder: (context, state) => MarketingLandingPage(),
      ),
      GoRoute(
        path: AppRoute.marketing,
        name: 'marketing',
        builder: (context, state) => MarketingLandingPage(),
      ),
      GoRoute(
        path: '/privacy',
        name: 'privacy',
        builder: (context, state) => const PrivacyScreen(),
      ),
      GoRoute(
        path: '/terms',
        name: 'terms',
        builder: (context, state) => const TermsScreen(),
      ),
      GoRoute(
        path: '/sms-policy',
        name: 'sms-policy',
        builder: (context, state) => const SMSPolicyScreen(),
      ),
      GoRoute(
        path: '/contact',
        name: 'contact',
        builder: (context, state) => const ContactScreen(),
      ),
      GoRoute(
        path: AppRoute.login,
        name: 'login',
        builder: (context, state) {
          final email = state.uri.queryParameters['email'];
          final redirect = state.uri.queryParameters['redirect'];
          return LoginScreen(initialEmail: email, redirectAfterLogin: redirect);
        },
      ),
      GoRoute(
        path: AppRoute.signup,
        name: 'signup',
        builder: (context, state) => const SignupScreen(),
      ),
      GoRoute(
        path: AppRoute.forgotPassword,
        name: 'forgot-password',
        builder: (context, state) => const ForgotPasswordScreen(),
      ),
      GoRoute(
        path: AppRoute.verifyEmail,
        name: 'verify-email',
        builder: (context, state) {
          final emailExtra = state.extra;
          final emailParam = state.uri.queryParameters['email'];
          final email = emailExtra is String ? emailExtra : (emailParam ?? '');
          return EmailVerificationScreen(email: email);
        },
      ),
      GoRoute(
        path: AppRoute.tenantPortal,
        name: 'tenant-portal',
        builder: (context, state) => Consumer(
          builder: (ctx, ref, _) {
            final enabled =
                ref.watch(featureFlagEnabledProvider('tenantPortal'));
            if (!enabled) {
              return const _FeatureDisabledPage(featureName: 'Tenant Portal');
            }
            return const TenantPortalAccessScreen();
          },
        ),
      ),
      GoRoute(
        path: AppRoute.contractSign,
        name: 'contract-sign',
        builder: (context, state) {
          final token = state.uri.queryParameters['token'];
          if (token == null || token.isEmpty) {
            return NotFoundPage(state: state);
          }
          final contract = state.extra is ContractModel
              ? state.extra as ContractModel
              : null;
          return ContractSigningScreen(signingToken: token, contract: contract);
        },
      ),
      GoRoute(
        path: AppRoute.publicRental,
        name: 'public-rental',
        builder: (context, state) {
          final facilityId = state.uri.queryParameters['facilityId'];
          return PublicRentalPortalScreen(facilityId: facilityId);
        },
      ),
      GoRoute(
        path: AppRoute.publicMoveIn,
        name: 'public-move-in',
        builder: (context, state) {
          final token = state.uri.queryParameters['token'];
          if (token == null || token.isEmpty) {
            return NotFoundPage(state: state);
          }
          return PublicMoveInScreen(token: token);
        },
      ),
      GoRoute(
        path: '${AppRoute.publicFacility}/:facilityId',
        name: 'public-facility',
        builder: (context, state) {
          final facilityId = state.pathParameters['facilityId'] ??
              state.uri.queryParameters['facilityId'];
          if (facilityId == null || facilityId.isEmpty) {
            return NotFoundPage(state: state);
          }
          return PublicFacilityPageScreen(facilityId: facilityId);
        },
      ),
      GoRoute(
        path: '${AppRoute.publicMapBase}/:facilitySlug/map',
        name: 'public-facility-map',
        builder: (context, state) {
          final slug = state.pathParameters['facilitySlug'];
          if (slug == null || slug.isEmpty) {
            return NotFoundPage(state: state);
          }
          return PublicFacilityMapScreen(facilitySlug: slug);
        },
      ),
      // Report Scheduling Routes (inside ShellRoute)
      GoRoute(
        path: AppRoute.reportScheduling,
        name: 'report-scheduling',
        builder: (context, state) => const ReportSchedulingManagementScreen(),
      ),
      GoRoute(
        path: '${AppRoute.reportScheduling}/create',
        name: 'report-scheduling-create',
        builder: (context, state) => const ReportSchedulingEditorScreen(),
      ),
      GoRoute(
        path: '${AppRoute.reportScheduling}/:id',
        name: 'report-scheduling-detail',
        builder: (context, state) {
          final id = state.pathParameters['id'];
          // For now, redirect to edit. Could add detail view later
          return ReportSchedulingEditorScreen(scheduleId: id);
        },
      ),
      GoRoute(
        path: '${AppRoute.reportScheduling}/:id/edit',
        name: 'report-scheduling-edit',
        builder: (context, state) {
          final id = state.pathParameters['id'];
          return ReportSchedulingEditorScreen(scheduleId: id);
        },
      ),
      // Escalation Workflow Routes
      GoRoute(
        path: AppRoute.escalationWorkflows,
        name: 'escalation-workflows',
        builder: (context, state) => const EscalationWorkflowManagementScreen(),
      ),
      // Conditional Rules Routes
      GoRoute(
        path: AppRoute.conditionalRules,
        name: 'conditional-rules',
        builder: (context, state) => const ConditionalRulesManagementScreen(),
      ),
      // Email Sequence Routes
      GoRoute(
        path: AppRoute.emailSequences,
        name: 'email-sequences',
        builder: (context, state) => const EmailSequenceManagementScreen(),
      ),
      GoRoute(
        path: '${AppRoute.emailSequences}/create',
        name: 'email-sequences-create',
        builder: (context, state) => const EmailSequenceEditorScreen(),
      ),
      GoRoute(
        path: '${AppRoute.emailSequences}/:id',
        name: 'email-sequences-detail',
        builder: (context, state) {
          final id = state.pathParameters['id'];
          // For now, redirect to edit. Could add detail view later
          return EmailSequenceEditorScreen(sequenceId: id);
        },
      ),
      GoRoute(
        path: '${AppRoute.emailSequences}/:id/edit',
        name: 'email-sequences-edit',
        builder: (context, state) {
          final id = state.pathParameters['id'];
          return EmailSequenceEditorScreen(sequenceId: id);
        },
      ),
      GoRoute(
        path: AppRoute.acceptInvite,
        name: 'accept-invite',
        builder: (context, state) {
          final facilityId = state.uri.queryParameters['facilityId'];
          final inviteId = state.uri.queryParameters['inviteId'];
          if (facilityId == null ||
              facilityId.isEmpty ||
              inviteId == null ||
              inviteId.isEmpty) {
            return NotFoundPage(state: state);
          }
          return AcceptInviteScreen(
            facilityId: facilityId,
            inviteId: inviteId,
          );
        },
      ),
      ShellRoute(
        builder: (context, state, child) =>
            AppShell(child: child, showSubscriptionBanner: true),
        routes: [
          GoRoute(
            path: AppRoute.dashboard,
            name: 'dashboard',
            builder: (context, state) => const HomeScreenModern(),
          ),
          GoRoute(
            path: AppRoute.facilities,
            name: 'facilities',
            builder: (context, state) => const FacilityManagementScreen(),
          ),
          GoRoute(
            path: AppRoute.facilityCreate,
            name: 'facility-create',
            builder: (context, state) => const FacilityCreationWizard(),
          ),
          GoRoute(
            path: AppRoute.facilityNew,
            name: 'facility-new',
            builder: (context, state) => const FacilityCreationWizard(),
          ),
          GoRoute(
            path: AppRoute.tenants,
            name: 'tenants',
            builder: (context, state) => const ClientListScreen(),
          ),
          GoRoute(
            path: AppRoute.tenantCsvImport,
            name: 'tenant-csv-import',
            builder: (context, state) {
              final extra = state.extra;
              String facilityId = '';
              if (extra is Map<String, dynamic>) {
                facilityId = extra['facilityId'] ?? '';
              } else {
                facilityId = state.uri.queryParameters['facilityId'] ?? '';
              }
              if (facilityId.isEmpty) {
                return NotFoundPage(state: state);
              }
              return TenantCsvImportWizardScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.tenantDetail,
            name: 'tenant-detail',
            builder: (context, state) {
              final tenantExtra = state.extra;
              if (tenantExtra is TenantModel) {
                return ClientDetailScreen(tenant: tenantExtra);
              }
              // Load from query params when navigating from dashboard etc.
              final tenantId = state.uri.queryParameters['tenantId'];
              final facilityId = state.uri.queryParameters['facilityId'];
              if (tenantId == null ||
                  tenantId.isEmpty ||
                  facilityId == null ||
                  facilityId.isEmpty) {
                return NotFoundPage(state: state);
              }
              return FutureBuilder<TenantModel?>(
                future: TenantService.getTenantById(facilityId, tenantId),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Scaffold(
                      body: Center(child: CircularProgressIndicator()),
                    );
                  }
                  if (snapshot.hasError ||
                      !snapshot.hasData ||
                      snapshot.data == null) {
                    return NotFoundPage(state: state);
                  }
                  return ClientDetailScreen(tenant: snapshot.data!);
                },
              );
            },
          ),
          GoRoute(
            path: '/tenants/:tenantId/ledger',
            name: 'tenant-ledger',
            builder: (context, state) {
              final tenantId = state.pathParameters['tenantId'];
              if (tenantId == null) {
                return NotFoundPage(state: state);
              }

              // Try to get tenant from state.extra first (preferred)
              final tenantExtra = state.extra;
              if (tenantExtra is TenantModel) {
                return LedgerScreen(tenant: tenantExtra);
              }

              // Otherwise, try to load from facilityId query parameter
              final facilityId = state.uri.queryParameters['facilityId'];
              if (facilityId != null && facilityId.isNotEmpty) {
                // Return a FutureBuilder to load the tenant
                return FutureBuilder<TenantModel?>(
                  future: TenantService.getTenantById(facilityId, tenantId),
                  builder: (context, snapshot) {
                    if (snapshot.connectionState == ConnectionState.waiting) {
                      return const Scaffold(
                        body: Center(child: CircularProgressIndicator()),
                      );
                    }
                    if (snapshot.hasError ||
                        !snapshot.hasData ||
                        snapshot.data == null) {
                      return NotFoundPage(state: state);
                    }
                    return LedgerScreen(tenant: snapshot.data!);
                  },
                );
              }

              // If no facilityId provided and no tenant in extra, show not found
              return NotFoundPage(state: state);
            },
          ),
          GoRoute(
            path: AppRoute.contactLogs,
            name: 'contact-logs',
            builder: (context, state) {
              final tenantId = state.uri.queryParameters['tenantId'] ?? '';
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              if (tenantId.isEmpty || facilityId.isEmpty) {
                return NotFoundPage(state: state);
              }
              final tenant = state.extra;
              return ContactLogsScreen(
                tenantId: tenantId,
                facilityId: facilityId,
                tenant: tenant is TenantModel ? tenant : null,
              );
            },
          ),
          GoRoute(
            path: AppRoute.auditLogs,
            name: 'audit-logs',
            builder: (context, state) => const AuditLogScreen(),
          ),
          GoRoute(
            path: AppRoute.exports,
            name: 'exports',
            builder: (context, state) => const ExportsScreen(),
          ),
          GoRoute(
            path: AppRoute.transfer,
            name: 'transfer',
            builder: (context, state) {
              final tenantId = state.uri.queryParameters['tenantId'] ?? '';
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              if (tenantId.isEmpty || facilityId.isEmpty) {
                return NotFoundPage(state: state);
              }
              final tenant = state.extra;
              return TransferWorkflowScreen(
                tenantId: tenantId,
                facilityId: facilityId,
                tenant: tenant is TenantModel ? tenant : null,
              );
            },
          ),
          GoRoute(
            path: AppRoute.units,
            name: 'units',
            builder: (context, state) => const UnitListScreen(),
          ),
          GoRoute(
            path: AppRoute.managerOverlock,
            name: 'manager-overlock',
            builder: (context, state) => const ManagerOverlockScreen(),
          ),
          GoRoute(
            path: AppRoute.unitsMap,
            name: 'units-map',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'];
              if (facilityId == null || facilityId.isEmpty) {
                return const UnitsLandingScreen();
              }
              return UnitsMapEntryScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.unitDetail,
            name: 'unit-detail',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              final unitId = state.uri.queryParameters['unitId'] ?? '';
              final unit = state.extra;

              if (facilityId.isNotEmpty && unitId.isNotEmpty) {
                return UnitDetailScreen(
                  facilityId: facilityId,
                  unitId: unitId,
                  unit: unit is UnitModel ? unit : null,
                );
              } else if (unit is UnitModel) {
                // Fallback to old pattern
                return UnitDetailScreen(
                  facilityId: unit.facilityId,
                  unitId: unit.id,
                  unit: unit,
                );
              } else {
                return NotFoundPage(state: state);
              }
            },
          ),
          GoRoute(
            path: AppRoute.unitEdit,
            name: 'unit-edit',
            builder: (context, state) {
              final unit = state.extra;
              if (unit is UnitModel) {
                return UnitCreationScreen(
                  facilityId: unit.facilityId,
                  unit: unit,
                );
              }
              return NotFoundPage(state: state);
            },
          ),
          GoRoute(
            path: AppRoute.contracts,
            name: 'contracts',
            builder: (context, state) => const ContractListScreen(),
          ),
          GoRoute(
            path: AppRoute.contractCreate,
            name: 'contract-create',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              final tenantId = state.uri.queryParameters['tenantId'] ?? '';
              return ContractCreationScreen(
                facilityId: facilityId,
                tenantId: tenantId.isEmpty ? null : tenantId,
              );
            },
          ),
          GoRoute(
            path: AppRoute.contractTemplates,
            name: 'contract-templates',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              return ContractTemplateManagementScreen(
                facilityId: facilityId.isEmpty ? null : facilityId,
              );
            },
          ),
          GoRoute(
            path: AppRoute.contractTemplatesCreate,
            name: 'contract-templates-create',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              if (facilityId.isEmpty) {
                return NotFoundPage(state: state);
              }
              return CreateContractTemplateScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.contractTemplatesEdit,
            name: 'contract-templates-edit',
            builder: (context, state) {
              final template = state.extra;
              if (template is! ContractTemplateModel) {
                return NotFoundPage(state: state);
              }
              return EditContractTemplateScreen(template: template);
            },
          ),
          GoRoute(
            path: AppRoute.leaseTemplates,
            name: 'lease-templates',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              if (facilityId.isEmpty) {
                return NotFoundPage(state: state);
              }
              return LeaseTemplatesScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.contractDetail,
            name: 'contract-detail',
            builder: (context, state) {
              final contract = state.extra;
              if (contract is! ContractModel) {
                return NotFoundPage(state: state);
              }
              return ContractDetailScreen(contract: contract);
            },
          ),
          GoRoute(
            path: AppRoute.insurance,
            name: 'insurance',
            builder: (context, state) => const InsuranceScreen(),
          ),
          GoRoute(
            path: AppRoute.billing,
            name: 'billing',
            builder: (context, state) => const InvoiceListScreen(),
          ),
          GoRoute(
            path: AppRoute.payments,
            name: 'payments',
            builder: (context, state) => const PaymentListScreen(),
          ),
          GoRoute(
            path: AppRoute.paymentDetail,
            name: 'payment-detail',
            builder: (context, state) {
              final payment = state.extra;
              if (payment is! PaymentModel) {
                return NotFoundPage(state: state);
              }
              return PaymentDetailScreen(payment: payment);
            },
          ),
          GoRoute(
            path: AppRoute.paymentCreate,
            name: 'payment-create',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              return PaymentCreationScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.paymentReconciliation,
            name: 'payment-reconciliation',
            builder: (context, state) => const PaymentReconciliationScreen(),
          ),
          GoRoute(
            path: AppRoute.delinquency,
            name: 'delinquency',
            builder: (context, state) => const DelinquencyShellScreen(),
          ),
          GoRoute(
            path: AppRoute.access,
            name: 'access',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'];
              final facilityName =
                  state.uri.queryParameters['facilityName'] ?? '';
              if (facilityId == null || facilityId.isEmpty) {
                return const AccessLandingScreen();
              }
              return GateAccessScreen(
                facilityId: facilityId,
                facilityName: Uri.decodeComponent(facilityName),
              );
            },
          ),
          GoRoute(
            path: AppRoute.messaging,
            name: 'messaging',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'];
              if (facilityId == null || facilityId.isEmpty) {
                // Use active facility or trigger facility selection
                return Consumer(
                  builder: (context, ref, child) {
                    final activeFacilityIdAsync =
                        ref.watch(activeFacilityIdProvider);
                    return activeFacilityIdAsync.when(
                      data: (activeFacilityId) {
                        if (activeFacilityId != null) {
                          // Redirect to messaging with active facility
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (context.mounted) {
                              context.go(
                                  '/messaging?facilityId=$activeFacilityId');
                            }
                          });
                          return const Scaffold(
                            body: Center(child: CircularProgressIndicator()),
                          );
                        }
                        // No active facility - show facility selector
                        return const MessagingFacilitySelector();
                      },
                      loading: () => const Scaffold(
                        body: Center(child: CircularProgressIndicator()),
                      ),
                      error: (_, __) => const MessagingFacilitySelector(),
                    );
                  },
                );
              }
              return MessagingScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.smsConversations,
            name: 'sms-conversations',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              if (facilityId.isEmpty) {
                // Use active facility or redirect to messaging
                return Consumer(
                  builder: (context, ref, child) {
                    final activeFacilityId = ref
                        .watch(activeFacilityIdProvider)
                        .whenOrNull(data: (d) => d);
                    if (activeFacilityId != null) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (context.mounted) {
                          context.go(
                              '/messaging/sms?facilityId=$activeFacilityId');
                        }
                      });
                      return const Scaffold(
                        body: Center(child: CircularProgressIndicator()),
                      );
                    }
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (context.mounted) {
                        context.go('/messaging');
                      }
                    });
                    return const Scaffold(
                      body: Center(child: CircularProgressIndicator()),
                    );
                  },
                );
              }
              return SMSConversationsScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.settings,
            name: 'settings',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: AppRoute.textingSetup,
            name: 'texting-setup',
            builder: (context, state) => Consumer(
              builder: (ctx, ref, _) {
                final enabled = ref
                    .watch(featureFlagEnabledProvider('TEXTING_ONBOARDING_V1'));
                if (!enabled) {
                  return const _FeatureDisabledPage(
                      featureName: 'Texting Setup');
                }
                final facilityId = state.uri.queryParameters['facilityId'];
                return TextingSetupScreen(facilityId: facilityId);
              },
            ),
          ),
          GoRoute(
            path: AppRoute.permissionManagement,
            name: 'permission-management',
            builder: (context, state) => const PermissionManagementScreen(),
          ),
          GoRoute(
            path: AppRoute.stripeConnect,
            name: 'stripe-connect',
            builder: (context, state) {
              final extra = state.extra;
              final facilityIdParam = state.uri.queryParameters['facilityId'];

              // Priority: extra > query param > active facility
              if (extra is FacilityModel) {
                return StripeConnectOnboardingScreen(facility: extra);
              }

              // Try to get facility from query param or active facility
              return Consumer(
                builder: (context, ref, _) {
                  final facilitiesAsync = ref.watch(userFacilitiesProvider(
                    ref
                            .watch(authStateProvider)
                            .whenOrNull(data: (d) => d)
                            ?.uid ??
                        '',
                  ));

                  return facilitiesAsync.when(
                    data: (facilities) {
                      FacilityModel? facility;

                      if (facilityIdParam != null &&
                          facilityIdParam.isNotEmpty) {
                        facility = facilities.firstWhere(
                          (f) => f.id == facilityIdParam,
                          orElse: () => facilities.isNotEmpty
                              ? facilities.first
                              : throw Exception('Facility not found'),
                        );
                      } else {
                        // Use active facility
                        final activeFacilityId = ref
                            .read(activeFacilityIdProvider)
                            .whenOrNull(data: (d) => d);
                        if (activeFacilityId != null) {
                          facility = facilities.firstWhere(
                            (f) => f.id == activeFacilityId,
                            orElse: () => facilities.isNotEmpty
                                ? facilities.first
                                : throw Exception('Facility not found'),
                          );
                        } else if (facilities.isNotEmpty) {
                          facility = facilities.first;
                        }
                      }

                      if (facility == null) {
                        return Scaffold(
                          appBar: AppBar(
                            title: const Text('Stripe Connect'),
                          ),
                          body: Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(
                                    Icons.account_balance_wallet_outlined,
                                    size: 64,
                                    color: Colors.grey[400],
                                  ),
                                  const SizedBox(height: 24),
                                  Text(
                                    'Create a facility first',
                                    style:
                                        Theme.of(context).textTheme.titleLarge,
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 12),
                                  Text(
                                    'Stripe Connect is set up per facility. Create a facility, then come back here to connect Stripe and receive payments.',
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color: Colors.grey[600],
                                        ),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 24),
                                  ElevatedButton.icon(
                                    onPressed: () =>
                                        context.go(AppRoute.facilityCreate),
                                    icon: const Icon(Icons.add_business),
                                    label: const Text('Create Facility'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }

                      return StripeConnectOnboardingScreen(facility: facility);
                    },
                    loading: () => const Scaffold(
                      body: Center(child: CircularProgressIndicator()),
                    ),
                    error: (_, __) => const SettingsScreen(),
                  );
                },
              );
            },
          ),
          GoRoute(
            path: AppRoute.insuranceSettings,
            name: 'insurance-settings',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              if (facilityId.isEmpty) {
                return const SettingsScreen(); // Fallback
              }
              return InsuranceSettingsScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.insuranceReport,
            name: 'insurance-report',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              if (facilityId.isEmpty) {
                return const SettingsScreen(); // Fallback
              }
              return InsuranceReportScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.notificationSettings,
            name: 'notification-settings',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              if (facilityId.isEmpty) {
                return const SettingsScreen(); // Fallback
              }
              return NotificationSettingsScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.profileEdit,
            name: 'profile-edit',
            builder: (context, state) => const ProfileEditScreen(),
          ),
          GoRoute(
            path: AppRoute.appearanceSettings,
            name: 'appearance-settings',
            builder: (context, state) => const AppearanceSettingsScreen(),
          ),
          GoRoute(
            path: AppRoute.bulkMessaging,
            name: 'bulk-messaging',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              if (facilityId.isEmpty) {
                // Use active facility or redirect to messaging
                return Consumer(
                  builder: (context, ref, child) {
                    final activeFacilityId = ref
                        .watch(activeFacilityIdProvider)
                        .whenOrNull(data: (d) => d);
                    if (activeFacilityId != null) {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (context.mounted) {
                          context.go(
                              '/messaging/bulk?facilityId=$activeFacilityId');
                        }
                      });
                      return const Scaffold(
                        body: Center(child: CircularProgressIndicator()),
                      );
                    }
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (context.mounted) {
                        context.go('/messaging');
                      }
                    });
                    return const Scaffold(
                      body: Center(child: CircularProgressIndicator()),
                    );
                  },
                );
              }
              return BulkMessagingScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.emailTemplates,
            name: 'email-templates',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'];
              return EmailTemplateManagementScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.smsTemplates,
            name: 'sms-templates',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'];
              return SMSTemplateManagementScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.publicPayment,
            name: 'public-payment',
            builder: (context, state) {
              final token = state.uri.queryParameters['token'];
              return PublicPaymentScreen(token: token);
            },
          ),
          GoRoute(
            path: AppRoute.paymentLinks,
            name: 'payment-links',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              if (facilityId.isEmpty) {
                return const SettingsScreen(); // Fallback
              }
              return PaymentLinksManagementScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.coupons,
            name: 'coupons',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'];
              return CouponManagementScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.claims,
            name: 'claims',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              if (facilityId.isEmpty) {
                return const SettingsScreen(); // Fallback
              }
              return ClaimsListScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.claimDetail,
            name: 'claim-detail',
            builder: (context, state) {
              final extra = state.extra;
              if (extra is Map<String, dynamic>) {
                return ClaimDetailScreen(
                  facilityId: extra['facilityId'] ?? '',
                  claimId: extra['claimId'],
                  isNewClaim: extra['isNewClaim'] ?? false,
                  tenantId: extra['tenantId'],
                );
              }
              // Fallback pattern using query params
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              final claimId = state.pathParameters['id'];
              return ClaimDetailScreen(
                facilityId: facilityId,
                claimId: claimId,
                isNewClaim: claimId == null,
              );
            },
          ),
          GoRoute(
            path: AppRoute.calendar,
            name: 'calendar',
            builder: (context, state) => const FacilityCalendarScreen(),
          ),
          GoRoute(
            path: AppRoute.aiAssistant,
            name: 'ai-assistant',
            builder: (context, state) => Consumer(
              builder: (ctx, ref, _) {
                final enabled =
                    ref.watch(featureFlagEnabledProvider('aiAssistant'));
                if (!enabled) {
                  return const _FeatureDisabledPage(
                      featureName: 'AI Assistant');
                }
                return const AIAssistantScreen();
              },
            ),
          ),
          GoRoute(
            path: AppRoute.reports,
            name: 'reports',
            builder: (context, state) => const FinancialReportsScreen(),
          ),
          GoRoute(
            path: AppRoute.reportsFinancial,
            name: 'reports-financial',
            builder: (context, state) => const FinancialReportsScreen(),
          ),
          GoRoute(
            path: AppRoute.reportsConsolidated,
            name: 'reports-consolidated',
            builder: (context, state) => const ReportsConsolidatedScreen(),
          ),
          GoRoute(
            path: AppRoute.communicationAnalytics,
            name: 'communication-analytics',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'];
              return CommunicationAnalyticsScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.documents,
            name: 'documents',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'];
              final tenantId = state.uri.queryParameters['tenantId'];
              final category = state.uri.queryParameters['category'];
              DocumentCategory? docCategory;
              if (category != null) {
                docCategory = DocumentCategory.values.firstWhere(
                  (c) => c.name == category,
                  orElse: () => DocumentCategory.other,
                );
              }
              return DocumentCenterScreen(
                facilityId: facilityId,
                tenantId: tenantId,
                category: docCategory,
              );
            },
          ),
          // API Keys Routes
          GoRoute(
            path: AppRoute.apiKeys,
            name: 'api-keys',
            builder: (context, state) => const ApiKeysManagementScreen(),
          ),
          GoRoute(
            path: '${AppRoute.apiKeys}/create',
            name: 'api-keys-create',
            builder: (context, state) => const ApiKeyCreationScreen(),
          ),
          // Webhooks Routes
          GoRoute(
            path: AppRoute.webhooks,
            name: 'webhooks',
            builder: (context, state) => const WebhooksManagementScreen(),
          ),
          GoRoute(
            path: '${AppRoute.webhooks}/create',
            name: 'webhooks-create',
            builder: (context, state) => const WebhookEditorScreen(),
          ),
          GoRoute(
            path: '${AppRoute.webhooks}/:id/edit',
            name: 'webhooks-edit',
            builder: (context, state) {
              final id = state.pathParameters['id'];
              return WebhookEditorScreen(webhookId: id);
            },
          ),
          GoRoute(
            path: AppRoute.yieldManagement,
            name: 'yield',
            builder: (context, state) => const YieldManagementScreen(),
          ),
          GoRoute(
            path: AppRoute.reminders,
            name: 'reminders',
            builder: (context, state) => const ReminderListScreen(),
          ),
          GoRoute(
            path: AppRoute.reminderCreate,
            name: 'reminder-create',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              return ReminderCreationScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.reminderDetail,
            name: 'reminder-detail',
            builder: (context, state) {
              final reminder = state.extra;
              if (reminder is! ReminderModel) {
                return NotFoundPage(state: state);
              }
              return ReminderDetailScreen(reminder: reminder);
            },
          ),
          GoRoute(
            path: AppRoute.reminderSchedule,
            name: 'reminder-schedule',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              final facilityName =
                  state.uri.queryParameters['facilityName'] ?? '';
              return ReminderScheduleScreen(
                facilityId: facilityId,
                facilityName: facilityName.isEmpty ? 'Facility' : facilityName,
              );
            },
          ),
          GoRoute(
            path: AppRoute.dnr,
            name: 'dnr',
            builder: (context, state) => const DNRListScreen(),
          ),
          GoRoute(
            path: AppRoute.pendingApproval,
            name: 'pending-approval',
            builder: (context, state) => const PendingApprovalScreen(),
          ),
          GoRoute(
            path: AppRoute.subscription,
            name: 'subscription',
            builder: (context, state) {
              final showTrialExpiredDialog =
                  state.uri.queryParameters['trialExpired'] == '1';
              final tabParam = state.uri.queryParameters['tab'];
              final initialTab = tabParam == 'processing'
                  ? 1
                  : tabParam == 'accounting'
                      ? 2
                      : 0;
              final subscriptionChild = state.extra is SubscriptionTestScreen
                  ? state.extra as SubscriptionTestScreen
                  : null;
              return BillingAndPaymentsScreen(
                showTrialExpiredDialog: showTrialExpiredDialog,
                initialTab: initialTab,
                subscriptionChild: subscriptionChild,
              );
            },
          ),
          GoRoute(
            path: AppRoute.dataIntegrity,
            name: 'data-integrity',
            builder: (context, state) => const DataIntegrityScreen(),
          ),
          GoRoute(
            path: AppRoute.contractSigningTest,
            name: 'contract-signing-test',
            builder: (context, state) {
              if (kDebugMode) {
                return const ContractSigningTestScreen();
              }
              // In release mode, redirect to contracts list
              return const ContractListScreen();
            },
          ),
          GoRoute(
            path: AppRoute.moveOut,
            name: 'move-out',
            builder: (context, state) {
              final contractId = state.uri.queryParameters['contractId'];
              final facilityId = state.uri.queryParameters['facilityId'];
              if (contractId == null || facilityId == null) {
                return NotFoundPage(state: state);
              }
              return MoveOutScreen(
                contractId: contractId,
                facilityId: facilityId,
              );
            },
          ),
          GoRoute(
            path: AppRoute.moveInWizard,
            name: 'move-in-wizard',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              final unitId = state.uri.queryParameters['unitId'];
              final tenantId = state.uri.queryParameters['tenantId'];
              if (facilityId.isEmpty) {
                return NotFoundPage(state: state);
              }
              return MoveInWizardScreen(
                facilityId: facilityId,
                unitId: unitId,
                tenantId: tenantId,
              );
            },
          ),
          GoRoute(
            path: AppRoute.invoices,
            name: 'invoices',
            builder: (context, state) => const InvoiceListScreen(),
          ),
          GoRoute(
            path: AppRoute.invoiceDetail,
            name: 'invoice-detail',
            builder: (context, state) {
              final extra = state.extra;
              if (extra is Map<String, dynamic>) {
                final invoice = extra['invoice'];
                final facilityId = extra['facilityId'];
                if (invoice is InvoiceModel && facilityId is String) {
                  return InvoiceDetailScreen(
                    invoice: invoice,
                    facilityId: facilityId,
                  );
                }
              }
              return NotFoundPage(state: state);
            },
          ),
          GoRoute(
            path: AppRoute.liens,
            name: 'liens',
            builder: (context, state) => const LienListScreen(),
          ),
          GoRoute(
            path: AppRoute.lienDetail,
            name: 'lien-detail',
            builder: (context, state) {
              final extra = state.extra;
              if (extra is Map<String, dynamic>) {
                final lien = extra['lien'];
                final facilityId = extra['facilityId'];
                if (lien is LienModel && facilityId is String) {
                  return LienDetailScreen(
                    lien: lien,
                    facilityId: facilityId,
                  );
                }
              }
              return NotFoundPage(state: state);
            },
          ),
          GoRoute(
            path: AppRoute.inventory,
            name: 'inventory',
            builder: (context, state) => const InventoryListScreen(),
          ),
          GoRoute(
            path: AppRoute.pos,
            name: 'pos',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              final tenantId = state.uri.queryParameters['tenantId'];
              if (facilityId.isEmpty) {
                return NotFoundPage(state: state);
              }
              return POSScreen(
                facilityId: facilityId,
                tenantId: tenantId,
              );
            },
          ),
          GoRoute(
            path: AppRoute.recurringCharges,
            name: 'recurring-charges',
            builder: (context, state) => const RecurringChargesScreen(),
          ),
          GoRoute(
            path: AppRoute.automationPreview,
            name: 'automation-preview',
            builder: (context, state) {
              final automationType =
                  state.uri.queryParameters['type'] ?? 'monthlyCharges';
              return AutomationPreviewScreen(automationType: automationType);
            },
          ),
          GoRoute(
            path: AppRoute.deposits,
            name: 'deposits',
            builder: (context, state) => const DepositListScreen(),
          ),
          GoRoute(
            path: AppRoute.depositDetail,
            name: 'deposit-detail',
            builder: (context, state) {
              final extra = state.extra;
              if (extra is Map<String, dynamic>) {
                final deposit = extra['deposit'];
                final facilityId = extra['facilityId'];
                if (deposit is DepositModel && facilityId is String) {
                  return DepositDetailScreen(
                    deposit: deposit,
                    facilityId: facilityId,
                  );
                }
              }
              return NotFoundPage(state: state);
            },
          ),
          GoRoute(
            path: AppRoute.depositCreate,
            name: 'deposit-create',
            builder: (context, state) {
              final extra = state.extra;
              if (extra is Map<String, dynamic>) {
                final facilityId = extra['facilityId'];
                if (facilityId is String) {
                  return DepositCreationScreen(facilityId: facilityId);
                }
              }
              // Try to get from query params
              final facilityId = state.uri.queryParameters['facilityId'];
              if (facilityId != null && facilityId.isNotEmpty) {
                return DepositCreationScreen(facilityId: facilityId);
              }
              return NotFoundPage(state: state);
            },
          ),
        ],
      ),
      // Outside ShellRoute so it renders without the facility owner sidebar.
      // Used by the tenant portal (and any other full-screen widget pushed via extra).
      GoRoute(
        path: AppRoute.legacyScreen,
        name: 'legacy-screen',
        builder: (context, state) {
          final extra = state.extra;
          if (extra is Widget) return extra;
          return NotFoundPage(state: state);
        },
      ),
      // Super admin dashboard — full-screen, no facility sidebar.
      // Access is restricted to superadmin emails in route_guards.dart.
      GoRoute(
        path: AppRoute.superAdmin,
        name: 'super-admin',
        builder: (context, state) => const SuperAdminScreen(),
      ),
    ],
  );
});

/// Shown when a feature has been disabled via the Super Admin feature flags.
class _FeatureDisabledPage extends StatelessWidget {
  final String featureName;
  const _FeatureDisabledPage({required this.featureName});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.block, size: 48, color: Colors.grey),
            const SizedBox(height: 16),
            Text('$featureName is currently unavailable.',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              'This feature has been temporarily disabled by the platform administrator.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => context.go(AppRoute.dashboard),
              child: const Text('Back to Dashboard'),
            ),
          ],
        ),
      ),
    );
  }
}
