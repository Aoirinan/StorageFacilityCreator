import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:sfcapp/providers/auth_provider.dart';
import 'package:sfcapp/providers/tenant_portal_provider.dart';
import 'package:sfcapp/router/app_route.dart';
import 'package:sfcapp/screens/auth/widgets/auth_shell.dart';
import 'package:sfcapp/screens/tenant_portal_screen.dart';
import 'package:sfcapp/services/home_button_service.dart';
import 'package:sfcapp/services/tenant_portal_service.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Public tenant entry — uses the same [AuthShell] as facility owner login so the
/// experience is visually consistent and clearly distinct from the legacy layout.
class TenantPortalAccessScreen extends StatefulWidget {
  const TenantPortalAccessScreen({super.key});

  @override
  State<TenantPortalAccessScreen> createState() => _TenantPortalAccessScreenState();
}

class _TenantPortalAccessScreenState extends State<TenantPortalAccessScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _accessCodeController = TextEditingController();
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      HomeButtonService.instance.hide();
    });
  }

  @override
  void dispose() {
    _emailController.dispose();
    _accessCodeController.dispose();
    HomeButtonService.instance.show();
    super.dispose();
  }

  Future<void> _loadPortal() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    final email = _emailController.text.trim();
    final accessCode = _accessCodeController.text.trim();

    try {
      final data = await TenantPortalService.fetchPortalData(email: email, accessCode: accessCode);
      if (!mounted) return;
      await context.push(
        AppRoute.legacyScreen,
        extra: TenantPortalScreen(
          lookup: TenantPortalLookup(email: email, accessCode: accessCode),
          initialData: data,
        ),
      );
    } on TenantPortalException catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(error.message),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.error,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Unable to load tenant portal: $error'),
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppTheme.error,
        ),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  static String? _validateAccessCode(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Enter the access code from your facility';
    }
    if (value.trim().length < 4) {
      return 'Access code should be at least 4 characters';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return AuthShell(
      backButton: context.canPop() ? AuthShellBackButton(onPressed: () => context.pop()) : null,
      belowCard: Wrap(
        alignment: WrapAlignment.center,
        spacing: 8,
        runSpacing: 4,
        children: [
          AuthSecondaryLink(
            icon: Icons.login_rounded,
            label: 'Facility manager sign in',
            onPressed: () => context.go(AppRoute.login),
          ),
        ],
      ),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const AuthLogoHeader(
              title: 'Tenant portal',
              subtitle: 'Use the email on file with your facility and the access code they gave you.',
            ),
            const AuthFieldLabel('Email'),
            const SizedBox(height: 6),
            TextFormField(
              controller: _emailController,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              validator: AuthValidators.validateEmail,
              autofillHints: const [AutofillHints.email],
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15),
              decoration: authFieldDecoration(
                hint: 'you@email.com',
                icon: Icons.email_outlined,
              ),
            ),
            const SizedBox(height: 16),
            const AuthFieldLabel('Access code'),
            const SizedBox(height: 6),
            TextFormField(
              controller: _accessCodeController,
              textInputAction: TextInputAction.done,
              validator: _validateAccessCode,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15),
              decoration: authFieldDecoration(
                hint: 'Code from your facility',
                icon: Icons.lock_outlined,
                suffix: IconButton(
                  splashRadius: 20,
                  icon: const Icon(Icons.content_paste_go_rounded, size: 20, color: AppTheme.textTertiary),
                  tooltip: 'Paste from clipboard',
                  onPressed: () async {
                    final data = await Clipboard.getData('text/plain');
                    final text = data?.text ?? '';
                    if (text.isNotEmpty) {
                      _accessCodeController.text = text.trim();
                    }
                  },
                ),
              ),
              onFieldSubmitted: (_) => _loadPortal(),
            ),
            const SizedBox(height: 22),
            AuthGradientButton(
              isLoading: _isLoading,
              onPressed: _loadPortal,
              label: 'Open tenant portal',
            ),
            const SizedBox(height: 16),
            const Text(
              'Need a new code? Ask your facility manager.',
              style: TextStyle(
                fontSize: 13,
                color: AppTheme.textSecondary,
                height: 1.45,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
