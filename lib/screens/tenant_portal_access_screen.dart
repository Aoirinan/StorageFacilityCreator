import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../providers/tenant_portal_provider.dart';
import '../services/tenant_portal_service.dart';
import '../models/tenant_portal_models.dart';
import 'tenant_portal_screen.dart';
import '../services/home_button_service.dart';
import '../theme/app_theme.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';

class TenantPortalAccessScreen extends ConsumerStatefulWidget {
  const TenantPortalAccessScreen({super.key});

  @override
  ConsumerState<TenantPortalAccessScreen> createState() => _TenantPortalAccessScreenState();
}

class _TenantPortalAccessScreenState extends ConsumerState<TenantPortalAccessScreen> {
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

    setState(() {
      _isLoading = true;
    });

    final email = _emailController.text.trim();
    final accessCode = _accessCodeController.text.trim();

    try {
      final data = await TenantPortalService.fetchPortalData(email: email, accessCode: accessCode);
      if (!mounted) return;
      context.push(
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
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tenant Portal Access'),
        backgroundColor: AppTheme.primaryBlueDark,
        foregroundColor: AppTheme.textOnDark,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 16),
              Icon(Icons.key_outlined, size: 56, color: theme.colorScheme.primary),
              const SizedBox(height: 16),
              Text(
                'Welcome to your storage tenant portal.',
                style: theme.textTheme.titleMedium,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Enter the email address on file and the access code provided by your facility.',
                style: theme.textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 32),
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'Email Address',
                  prefixIcon: Icon(Icons.email_outlined),
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter your email address';
                  }
                  final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
                  if (!emailRegex.hasMatch(value.trim())) {
                    return 'Enter a valid email address';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _accessCodeController,
                textInputAction: TextInputAction.done,
                decoration: InputDecoration(
                  labelText: 'Access Code',
                  prefixIcon: const Icon(Icons.lock_outline),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.paste_outlined),
                    tooltip: 'Paste from clipboard',
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      final text = data?.text ?? '';
                      if (text.isNotEmpty) {
                        _accessCodeController.text = text.trim();
                      }
                    },
                  ),
                  border: const OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Enter the access code shared by your facility';
                  }
                  if (value.trim().length < 4) {
                    return 'Access code should be at least 4 characters';
                  }
                  return null;
                },
                onFieldSubmitted: (_) => _loadPortal(),
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: _isLoading ? null : _loadPortal,
                icon: _isLoading
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.textOnDark),
                      )
                    : const Icon(Icons.lock_open_outlined),
                label: Text(_isLoading ? 'Loading...' : 'Open Tenant Portal'),
              ),
              const SizedBox(height: 16),
              Text(
                'Having trouble accessing your account? Contact your facility manager to request a new access code.',
                style: theme.textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 120),
            ],
          ),
        ),
      ),
    );
  }
}
