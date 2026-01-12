import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'dart:async';
import 'dart:convert';

import '../providers/auth_provider.dart';
import 'app_route.dart';
import 'route_guards.dart';
import 'route_helpers.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/signup_screen.dart';
import '../screens/auth/forgot_password_screen.dart';
import '../screens/auth/email_verification_screen.dart';
import '../screens/tenant_portal_access_screen.dart';
import '../screens/contract_signing_screen.dart';
import '../screens/accept_invite_screen.dart';
import '../screens/facility_management_screen.dart';
import '../screens/client_list_screen.dart';
import '../screens/facility_map_editor_screen.dart';
import '../screens/home_screen_modern.dart';
import '../screens/contract_list_screen.dart';
import '../screens/payment_list_screen.dart';
import '../screens/insurance_screen.dart';
import '../screens/messaging_screen.dart';
import '../screens/sms_conversations_screen.dart';
import '../screens/gate_access_screen.dart';
import '../screens/settings_screen.dart';
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
import '../models/tenant_model.dart';
import '../models/payment_model.dart';
import '../screens/payment_detail_screen.dart';
import '../screens/reminder_creation_screen.dart';
import '../screens/reminder_detail_screen.dart';
import '../screens/reminder_schedule_screen.dart';
import '../screens/contract_detail_screen.dart';
import '../screens/contract_creation_screen.dart';
import '../screens/contract_template_management_screen.dart';
import '../screens/payment_creation_screen.dart';
import '../models/contract_model.dart';
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
import '../screens/transfer_workflow_screen.dart';
import '../screens/document_attachments_screen.dart';
import '../screens/unit_detail_screen.dart';
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
import '../models/document_attachment_model.dart';
import '../screens/marketing_landing_page.dart';

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
    refreshListenable: GoRouterRefreshStream(FirebaseAuth.instance.authStateChanges()),
    redirect: (context, state) => routeGuard(context, state, ref),
    errorBuilder: (context, state) => NotFoundPage(state: state),
    routes: [
      GoRoute(
        path: AppRoute.landing,
        name: 'landing',
        builder: (context, state) => MarketingLandingPage(),
      ),
      GoRoute(
        path: AppRoute.login,
        name: 'login',
        builder: (context, state) => const LoginScreen(),
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
          final email = emailExtra is String
              ? emailExtra
              : (emailParam ?? '');
          return EmailVerificationScreen(email: email);
        },
      ),
      GoRoute(
        path: AppRoute.tenantPortal,
        name: 'tenant-portal',
        builder: (context, state) => const TenantPortalAccessScreen(),
      ),
      GoRoute(
        path: AppRoute.contractSign,
        name: 'contract-sign',
        builder: (context, state) {
          final token = state.uri.queryParameters['token'];
          if (token == null || token.isEmpty) {
            return NotFoundPage(state: state);
          }
          return ContractSigningScreen(signingToken: token);
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
          final facilityId = state.pathParameters['facilityId'] ?? state.uri.queryParameters['facilityId'];
          if (facilityId == null || facilityId.isEmpty) {
            return NotFoundPage(state: state);
          }
          return PublicFacilityPageScreen(facilityId: facilityId);
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
          if (facilityId == null || facilityId.isEmpty || inviteId == null || inviteId.isEmpty) {
            return NotFoundPage(state: state);
          }
          return AcceptInviteScreen(
            facilityId: facilityId,
            inviteId: inviteId,
          );
        },
      ),
      ShellRoute(
        builder: (context, state, child) => AppShell(child: child, showSubscriptionBanner: true),
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
            path: AppRoute.tenantDetail,
            name: 'tenant-detail',
            builder: (context, state) {
              final tenantExtra = state.extra;
              if (tenantExtra is! TenantModel) {
                return NotFoundPage(state: state);
              }
              return ClientDetailScreen(tenant: tenantExtra);
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
                    if (snapshot.hasError || !snapshot.hasData || snapshot.data == null) {
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
            builder: (context, state) => const UnitsLandingScreen(),
          ),
          GoRoute(
            path: AppRoute.unitsMap,
            name: 'units-map',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'];
              if (facilityId == null || facilityId.isEmpty) {
                return const UnitsLandingScreen();
              }
              return FacilityMapEditorScreen(facilityId: facilityId);
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
            path: AppRoute.contracts,
            name: 'contracts',
            builder: (context, state) => const ContractListScreen(),
          ),
          GoRoute(
            path: AppRoute.contractCreate,
            name: 'contract-create',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'] ?? '';
              return ContractCreationScreen(facilityId: facilityId);
            },
          ),
          GoRoute(
            path: AppRoute.contractTemplates,
            name: 'contract-templates',
            builder: (context, state) => const ContractTemplateManagementScreen(),
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
            path: AppRoute.delinquency,
            name: 'delinquency',
            builder: (context, state) => const DelinquencyShellScreen(),
          ),
          GoRoute(
            path: AppRoute.access,
            name: 'access',
            builder: (context, state) {
              final facilityId = state.uri.queryParameters['facilityId'];
              final facilityName = state.uri.queryParameters['facilityName'] ?? '';
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
                return const MessagingLandingScreen();
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
                return const MessagingLandingScreen(); // Fallback
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
            path: AppRoute.stripeConnect,
            name: 'stripe-connect',
            builder: (context, state) {
              final extra = state.extra;
              if (extra is FacilityModel) {
                return StripeConnectOnboardingScreen(facility: extra);
              }
              // Fallback - redirect to settings if no facility provided
              return const SettingsScreen();
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
                return const SettingsScreen(); // Fallback
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
            path: AppRoute.aiAssistant,
            name: 'ai-assistant',
            builder: (context, state) => const AIAssistantScreen(),
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
              final facilityName = state.uri.queryParameters['facilityName'] ?? '';
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
            path: AppRoute.subscription,
            name: 'subscription',
            builder: (context, state) => const SubscriptionTestScreen(),
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
            path: AppRoute.legacyScreen,
            name: 'legacy-screen',
            builder: (context, state) {
              // #region agent log
              final logEntry = jsonEncode({
                'timestamp': DateTime.now().millisecondsSinceEpoch,
                'location': 'app_router.dart:562',
                'message': 'Legacy route builder called',
                'data': {'extraType': state.extra?.runtimeType.toString(), 'hasExtra': state.extra != null, 'isWidget': state.extra is Widget},
                'sessionId': 'debug-session',
                'runId': 'run1',
                'hypothesisId': 'C',
              });
              print('[DEBUG] $logEntry');
              // #endregion
              final extra = state.extra;
              if (extra is Widget) {
                // #region agent log
                final logEntry2 = jsonEncode({
                  'timestamp': DateTime.now().millisecondsSinceEpoch,
                  'location': 'app_router.dart:570',
                  'message': 'Returning Widget from legacy route',
                  'data': {'widgetType': extra.runtimeType.toString()},
                  'sessionId': 'debug-session',
                  'runId': 'run1',
                  'hypothesisId': 'C',
                });
                print('[DEBUG] $logEntry2');
                // #endregion
                return extra;
              }
              // #region agent log
              final logEntry3 = jsonEncode({
                'timestamp': DateTime.now().millisecondsSinceEpoch,
                'location': 'app_router.dart:586',
                'message': 'Extra is not a Widget, returning NotFoundPage',
                'data': {},
                'sessionId': 'debug-session',
                'runId': 'run1',
                'hypothesisId': 'C',
              });
              print('[DEBUG] $logEntry3');
              // #endregion
              return NotFoundPage(state: state);
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
    ],
  );
});

