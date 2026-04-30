import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/contract_model.dart';
import '../providers/feature_flag_provider.dart';
import '../screens/accept_invite_screen.dart';
import '../screens/auth/email_verification_screen.dart';
import '../screens/auth/forgot_password_screen.dart';
import '../screens/auth/login_screen.dart';
import '../screens/auth/privacy_screen.dart';
import '../screens/auth/signup_screen.dart';
import '../screens/auth/terms_screen.dart';
import '../screens/contact_screen.dart';
import '../screens/contract_signing_screen.dart';
import '../screens/marketing_landing_page.dart';
import '../screens/sms_policy_screen.dart';
import '../screens/tenant_portal_access_screen.dart';
import '../services/referral_program_service.dart';
import 'app_route.dart';
import 'route_helpers.dart';

List<RouteBase> buildPublicAuthEntryRoutes() {
  return [
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
      builder: (context, state) {
        final email = state.uri.queryParameters['email'];
        final refCode =
            state.uri.queryParameters[ReferralProgramService.referralSignupQueryParam];
        return SignupScreen(
          initialEmail: email,
          initialReferralCode: refCode,
        );
      },
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
          final enabled = ref.watch(featureFlagEnabledProvider('tenantPortal'));
          if (!enabled) {
            return const FeatureDisabledPage(featureName: 'Tenant Portal');
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
        final contract =
            state.extra is ContractModel ? state.extra as ContractModel : null;
        return ContractSigningScreen(signingToken: token, contract: contract);
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
  ];
}
