import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../router/app_router.dart';
import '../router/app_route.dart';
import '../theme/app_theme.dart';
import '../services/home_button_service.dart';

/// Modern marketing landing page for web with dark gradient hero and conversion-focused design.
class MarketingLandingPage extends StatefulWidget {
  MarketingLandingPage({super.key});

  @override
  State<MarketingLandingPage> createState() => _MarketingLandingPageState();
}

class _MarketingLandingPageState extends State<MarketingLandingPage> {
  final GlobalKey _featuresKey = GlobalKey();
  final GlobalKey _pricingKey = GlobalKey();
  final GlobalKey _faqKey = GlobalKey();
  final GlobalKey _securityKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Hide floating dashboard button on the marketing page.
    HomeButtonService.instance.hide();
  }

  @override
  void dispose() {
    HomeButtonService.instance.show();
    super.dispose();
  }

  void _scrollTo(GlobalKey key) {
    final context = key.currentContext;
    if (context != null) {
      Scrollable.ensureVisible(
        context,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.backgroundLight,
      body: SafeArea(
        child: SelectionArea(
          child: ScrollConfiguration(
            behavior: const _LandingScrollBehavior(),
            child: SingleChildScrollView(
              primary: true,
              physics: const ClampingScrollPhysics(),
              child: Column(
                children: [
                  _TopNav(
                    onFeatures: () => _scrollTo(_featuresKey),
                    onPricing: () => _scrollTo(_pricingKey),
                    onSecurity: () => _scrollTo(_securityKey),
                    onFAQ: () => _scrollTo(_faqKey),
                    onContact: () => context.go('/contact'),
                  ),
                  _HeroSection(),
                  _Section(
                    padding: const EdgeInsets.symmetric(vertical: 32),
                    child: _TrustStrip(),
                  ),
                  Container(
                    color: const Color(0xFFF7F9FC),
                    child: Column(
                      children: [
                        _Section(
                          key: _featuresKey,
                          padding: const EdgeInsets.symmetric(vertical: 64),
                          child: _FeaturesGrid(),
                        ),
                        _Section(
                          padding: const EdgeInsets.symmetric(vertical: 48),
                          child: _HowItWorks(),
                        ),
                        _Section(
                          padding: const EdgeInsets.symmetric(vertical: 48),
                          child: _IntegrationsRow(),
                        ),
                      ],
                    ),
                  ),
                  _Section(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: _Benefits(),
                  ),
                  _Section(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: _ProductPreview(),
                  ),
                  _Section(
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: _SocialProof(),
                  ),
                  _Section(
                    key: _securityKey,
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: _SecurityPitch(),
                  ),
                  _Section(
                    key: _pricingKey,
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: _PricingSection(),
                  ),
                  _Section(
                    key: _faqKey,
                    padding: const EdgeInsets.symmetric(vertical: 48),
                    child: _FAQ(),
                  ),
                  const SizedBox(height: 16),
                  _FinalCTA(),
                  _Footer(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopNav extends StatelessWidget {
  final VoidCallback onFeatures;
  final VoidCallback onPricing;
  final VoidCallback onSecurity;
  final VoidCallback onFAQ;
  final VoidCallback onContact;

  const _TopNav({
    required this.onFeatures,
    required this.onPricing,
    required this.onSecurity,
    required this.onFAQ,
    required this.onContact,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.95),
        border: Border(bottom: BorderSide(color: const Color(0xFFE2E8F0), width: 1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: Row(
          children: [
            Row(
              children: [
                Image.asset(
                  'assets/images/logo.png',
                  width: 40,
                  height: 40,
                  errorBuilder: (_, __, ___) => Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryBlue,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(Icons.storage_rounded, color: Colors.white, size: 24),
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Storage Facility Creator',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.2,
                    color: Color(0xFF1E293B),
                  ),
                ),
              ],
            ),
            const Spacer(),
            LayoutBuilder(
              builder: (context, constraints) {
                if (constraints.maxWidth > 800) {
                  return Wrap(
                    spacing: 24,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _NavLink(label: 'Features', onTap: onFeatures),
                      _NavLink(label: 'Pricing', onTap: onPricing),
                      _NavLink(label: 'Security', onTap: onSecurity),
                      _NavLink(label: 'FAQ', onTap: onFAQ),
                      _NavLink(label: 'Contact', onTap: onContact),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: () => context.go(AppRoute.login),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: Color(0xFFCBD5E1)),
                          foregroundColor: const Color(0xFF334155),
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text('Login'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: onContact,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: AppTheme.primaryBlue,
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child: const Text('Schedule a Demo'),
                      ),
                    ],
                  );
                } else {
                  return IconButton(
                    icon: const Icon(Icons.menu),
                    onPressed: () => Scaffold.of(context).openEndDrawer(),
                  );
                }
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroSection extends StatelessWidget {
  const _HeroSection();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.white,
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth > 900;
            return Flex(
              direction: isWide ? Axis.horizontal : Axis.vertical,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  flex: isWide ? 1 : 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'Run your storage facility from one place.',
                        style: TextStyle(
                          fontSize: 36,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                          height: 1.2,
                          color: Color(0xFF0F172A),
                        ),
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'Tenants and units, billing and ledgers, late notices and reminders—all in one system. See what\'s paid, what\'s past due, and what\'s empty at a glance. Simple, flat-rate pricing when you\'re ready.',
                        style: TextStyle(
                          fontSize: 18,
                          height: 1.6,
                          color: Color(0xFF475569),
                        ),
                      ),
                      const SizedBox(height: 32),
                      Wrap(
                        spacing: 16,
                        runSpacing: 12,
                        children: [
                          ElevatedButton(
                            onPressed: () => context.go('/contact'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primaryBlue,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              elevation: 0,
                              textStyle: const TextStyle(
                                fontWeight: FontWeight.w600,
                                fontSize: 14,
                              ),
                            ),
                            child: const Text('Schedule a Demo'),
                          ),
                          OutlinedButton(
                            onPressed: () => context.go(AppRoute.login),
                            style: OutlinedButton.styleFrom(
                              side: const BorderSide(color: Color(0xFFCBD5E1)),
                              foregroundColor: const Color(0xFF334155),
                              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                              textStyle: const TextStyle(
                                fontWeight: FontWeight.w500,
                                fontSize: 14,
                              ),
                            ),
                            child: const Text('Login'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (isWide) const SizedBox(width: 48),
                if (isWide)
                  Expanded(
                    flex: 1,
                    child: _DemoFrame(),
                  ),
                if (!isWide) ...[
                  const SizedBox(height: 32),
                  _DemoFrame(),
                ],
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Dashboard preview frame matching Next.js marketing (demo.png).
class _DemoFrame extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
        border: Border.all(color: const Color(0xFFE2E8F0)),
        color: Colors.white,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              color: const Color(0xFFF8FAFC),
              child: Row(
                children: [
                  ...List.generate(3, (_) => Container(
                    width: 12,
                    height: 12,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Color(0xFFCBD5E1),
                    ),
                  )),
                ],
              ),
            ),
            AspectRatio(
              aspectRatio: 4 / 3,
              child: Image.asset(
                'assets/images/demo.png',
                fit: BoxFit.contain,
                errorBuilder: (_, __, ___) => Container(
                  color: const Color(0xFFF1F5F9),
                  child: const Center(
                    child: Icon(Icons.dashboard_outlined, size: 64, color: Color(0xFF94A3B8)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrustStrip extends StatelessWidget {
  static const _items = [
    'Tenant & unit management',
    'Billing, ledger & payment tracking',
    'Late notices & delinquency tools',
    'SMS/email reminders (opt-in, STOP/HELP)',
    'Reports & activity logs',
  ];

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 16),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: Color(0xFFE2E8F0)),
          bottom: BorderSide(color: Color(0xFFE2E8F0)),
        ),
        color: Color(0xFFF8FAFC),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: Wrap(
          spacing: 32,
          runSpacing: 12,
          alignment: WrapAlignment.center,
          children: _items.map((item) => Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check, size: 18, color: AppTheme.primaryBlue),
              const SizedBox(width: 8),
              Text(
                item,
                style: const TextStyle(
                  fontSize: 14,
                  color: Color(0xFF334155),
                ),
              ),
            ],
          )).toList(),
        ),
      ),
    );
  }
}

class _FeaturesGrid extends StatelessWidget {
  final features = const [
    ('Tenant operations', 'Online move-ins, renewals, and ID capture in one place. Track tenant history across facilities.', Icons.people_alt_outlined),
    ('Unit & map control', 'Visual maps with status, holds, and maintenance flags. See availability at a glance.', Icons.map_outlined),
    ('Billing & payments', 'Recurring billing, dunning, and card-on-file support. Process payments via Stripe Connect.', Icons.receipt_long_outlined),
    ('Delinquency & liens', 'Stage-based workflows with notices and audit logging. Track collections automatically.', Icons.report_outlined),
    ('Messaging', 'Email/SMS templates with delivery status and opt-ins. SMS messaging complies with carrier requirements.', Icons.chat_bubble_outline),
    ('Reporting', 'Portfolio dashboards, exports, and scheduled delivery. Track occupancy and revenue across facilities.', Icons.insights_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1200),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Everything you need to run your facility',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w700,
              color: Color(0xFF0F172A),
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Tenant and unit management, billing, late notices, autopay, and reporting—built for independent and multi-site operators.',
            style: TextStyle(
              fontSize: 18,
              color: Color(0xFF475569),
            ),
          ),
          const SizedBox(height: 32),
          LayoutBuilder(
            builder: (context, constraints) {
              final count = constraints.maxWidth > 1100
                  ? 3
                  : constraints.maxWidth > 760
                      ? 2
                      : 1;
              return GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: features.length,
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: count,
                  mainAxisSpacing: 20,
                  crossAxisSpacing: 20,
                  childAspectRatio: 1.5,
                ),
                itemBuilder: (_, i) {
                  final f = features[i];
                  return _FeatureCard(
                    title: f.$1,
                    description: f.$2,
                    icon: f.$3 as IconData,
                  );
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

class _HowItWorks extends StatelessWidget {
  final steps = const [
    ('Setup', 'Import units, gate settings, and staff roles for each site. Connect Stripe for payments.'),
    ('Manage', 'Automate billing cadence, notices, and messaging templates. Track occupancy and collections.'),
    ('Grow', 'Add facilities as you expand. Multi-facility structure keeps data consistent and teams aligned.'),
  ];

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'How it works',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 24),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 900;
              final cardWidth = isWide ? (constraints.maxWidth - 32) / 3 : double.infinity;
              return Wrap(
                spacing: isWide ? 20 : 16,
                runSpacing: 16,
                children: List.generate(
                  steps.length,
                  (i) {
                    final s = steps[i];
                    return SizedBox(
                      width: cardWidth,
                      child: _StepCard(
                        stepNumber: i + 1,
                        title: s.$1,
                        description: s.$2,
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _IntegrationsRow extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Built on trusted infrastructure',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'We integrate with industry-leading services so you can focus on operations.',
            style: TextStyle(
              fontSize: 16,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 24,
            runSpacing: 16,
            alignment: WrapAlignment.center,
            children: const [
              _IntegrationLogo(name: 'Stripe', icon: Icons.payment),
              _IntegrationLogo(name: 'Twilio', icon: Icons.sms),
              _IntegrationLogo(name: 'SendGrid', icon: Icons.email),
              _IntegrationLogo(name: 'Firebase', icon: Icons.cloud),
            ],
          ),
        ],
      ),
    );
  }
}

class _Benefits extends StatelessWidget {
  final benefits = const [
    ('Reduce manual work', 'Automate billing, notices, and messaging so teams stay ahead. No more manual late notices or payment reminders.'),
    ('Centralize facilities', 'One workspace for units, tenants, payments, and communications. Switch between facilities instantly.'),
    ('Scale without complexity', 'Multi-facility structure that keeps data consistent as you grow. Add locations without adding spreadsheets.'),
    ('Built for SaaS multi-tenancy', 'Role-based access and auditability for every site. Track who changed what, when.'),
  ];

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1100),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Why operators choose Storage Facility Creator',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 24),
          Wrap(
            spacing: 20,
            runSpacing: 20,
            children: benefits
                .map(
                  (b) => SizedBox(
                    width: 320,
                    child: _BenefitCard(
                      title: b.$1,
                      description: b.$2,
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _ProductPreview extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1200),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'See it in action',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 24),
          Container(
            height: 400,
            decoration: BoxDecoration(
              color: AppTheme.backgroundSecondary,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.borderLight),
            ),
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.dashboard_outlined,
                    size: 64,
                    color: AppTheme.textTertiary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Dashboard preview',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 16,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SocialProof extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.backgroundSecondary,
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Trusted by operators who want clean, predictable systems.',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 32),
            Wrap(
              spacing: 20,
              runSpacing: 20,
              children: List.generate(
                2,
                (_) => const _TestimonialCard(
                  quote: 'The portfolio view keeps every facility aligned without extra spreadsheets. We can see occupancy and collections across all locations in one place.',
                  name: 'Operations lead',
                  role: 'Multi-site storage operator',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SecurityPitch extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFFF0F9FF),
      padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFDBEAFE),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.lock_outline,
                    color: Color(0xFF1D4ED8),
                    size: 32,
                  ),
                ),
                const SizedBox(width: 16),
                const Expanded(
                  child: Text(
                    'Stripe-powered payments',
                    style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w800,
                      color: AppTheme.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Text(
              'We never see or store your card number',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w700,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Your customers enter card details directly into Stripe\'s secure fields. Reduced risk, modern compliance posture.',
              style: TextStyle(
                fontSize: 16,
                height: 1.5,
                color: AppTheme.textSecondary,
              ),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 24,
              runSpacing: 16,
              children: const [
                _SecurityBullet(
                  icon: Icons.verified_user_outlined,
                  text: 'PCI DSS compliant',
                ),
                _SecurityBullet(
                  icon: Icons.shield_outlined,
                  text: 'Stripe handles all card data',
                ),
                _SecurityBullet(
                  icon: Icons.lock_clock_outlined,
                  text: 'Secure autopay setup',
                ),
              ],
            ),
            const SizedBox(height: 32),
            ExpansionTile(
              tilePadding: EdgeInsets.zero,
              childrenPadding: const EdgeInsets.only(top: 16),
              title: const Text(
                'Learn more about payment security',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.textPrimary,
                ),
              ),
              children: [
                _SecurityFAQItem(
                  question: 'What we store',
                  answer: 'We only store tokenized payment method IDs and safe display information (last 4 digits, card brand, expiration month/year). We never store full card numbers, CVV codes, or any sensitive card data.',
                ),
                const SizedBox(height: 16),
                _SecurityFAQItem(
                  question: 'What we never store',
                  answer: 'We never see or store your full card number, CVV/CVC codes, or any raw payment card data. All card information is handled directly by Stripe using their secure, PCI-compliant infrastructure.',
                ),
                const SizedBox(height: 16),
                _SecurityFAQItem(
                  question: 'How autopay works',
                  answer: 'When you set up autopay, your card details are securely saved with Stripe using their SetupIntent API. We only receive a tokenized payment method ID that we use for future charges. Your card number never touches our servers.',
                ),
              ],
            ),
            const SizedBox(height: 24),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.borderLight),
              ),
              child: Row(
                children: [
                  const Icon(Icons.info_outline, color: AppTheme.primaryBlue, size: 20),
                  const SizedBox(width: 12),
                  Expanded(
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(
                          fontSize: 14,
                          color: AppTheme.textSecondary,
                        ),
                        children: [
                          const TextSpan(text: 'SMS messaging complies with carrier requirements. See our '),
                          WidgetSpan(
                            child: GestureDetector(
                              onTap: () => context.go('/sms-policy'),
                              child: const Text(
                                'SMS Policy',
                                style: TextStyle(
                                  color: AppTheme.primaryBlue,
                                  decoration: TextDecoration.underline,
                                ),
                              ),
                            ),
                          ),
                          const TextSpan(text: ' for details.'),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PricingSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Pricing',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Contact us for custom pricing based on your facility count and needs.',
            style: TextStyle(
              fontSize: 18,
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 32),
          Container(
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: AppTheme.borderLight),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Enterprise',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Custom pricing',
                  style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.w800,
                    color: AppTheme.primaryBlue,
                  ),
                ),
                const SizedBox(height: 24),
                const _PricingFeature(text: 'Unlimited facilities'),
                const _PricingFeature(text: 'Unlimited users'),
                const _PricingFeature(text: 'All features included'),
                const _PricingFeature(text: 'Priority support'),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => context.go('/contact'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: const Text('Contact Sales'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FAQ extends StatelessWidget {
  final faqs = const [
    ('Does this replace my gate system?', 'We integrate with existing access controls; operators keep their hardware. We provide the software layer for managing access codes and gate schedules.'),
    ('How do teams sign in?', 'Role-based access with MFA-ready auth. Invite teammates directly from the app. Each user gets access only to facilities they\'re assigned to.'),
    ('Is there an app?', 'The web experience is responsive and works on all devices. Operators can pin it to home screens for app-like access.'),
    ('Can we migrate data?', 'Yes. Import units, tenants, and balances in a guided CSV import flow. We support bulk imports and can help with data migration.'),
    ('What payment information do you store?', 'We only store tokenized payment method IDs and safe display information (last 4 digits, card brand, expiration month/year). We never store full card numbers, CVV codes, or any sensitive card data.'),
    ('How secure are payments?', 'We never see or store your full card number, CVV/CVC codes, or any raw payment card data. All card information is handled directly by Stripe using their secure, PCI-compliant infrastructure. Your card details never touch our servers.'),
    ('How does SMS messaging work?', 'SMS messaging complies with carrier requirements. Tenants can opt in during account creation. Reply STOP to opt out, HELP for help. Message frequency varies. See our SMS Policy for details.'),
  ];

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 900),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Frequently asked questions',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 24),
          ...faqs.map(
            (f) => Card(
              elevation: 0,
              margin: const EdgeInsets.only(bottom: 12),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: AppTheme.borderLight),
              ),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                title: Text(
                  f.$1,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppTheme.textPrimary,
                  ),
                ),
                children: [
                  Text(
                    f.$2,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      height: 1.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _FinalCTA extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF1E3A8A),
            Color(0xFF2563EB),
          ],
        ),
      ),
      padding: const EdgeInsets.symmetric(vertical: 64, horizontal: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ready to modernize your storage operations?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 36,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.5,
              ),
            ),
            const SizedBox(height: 12),
            const Text(
              'Spin up a portfolio-ready workspace, invite your team, and start automating collections.',
              style: TextStyle(
                color: Color(0xFFE0E7FF),
                fontSize: 18,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 16,
              children: [
                ElevatedButton(
                  onPressed: () => context.go(AppRoute.signup),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppTheme.primaryBlue,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    elevation: 0,
                    textStyle: const TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 16,
                    ),
                  ),
                  child: const Text('Get Started'),
                ),
                OutlinedButton(
                  onPressed: () => context.go(AppRoute.login),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white, width: 2),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    textStyle: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 16,
                    ),
                  ),
                  child: const Text('Sign In'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.backgroundSecondary,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'Storage Facility Creator',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 18,
                    color: AppTheme.textPrimary,
                  ),
                ),
                const Spacer(),
                Wrap(
                  spacing: 24,
                  children: [
                    _FooterLink(
                      label: 'Privacy Policy',
                      onTap: () => context.go('/privacy'),
                    ),
                    _FooterLink(
                      label: 'Terms of Service',
                      onTap: () => context.go('/terms'),
                    ),
                    _FooterLink(
                      label: 'SMS Policy',
                      onTap: () => context.go('/sms-policy'),
                    ),
                    _FooterLink(
                      label: 'Contact',
                      onTap: () => context.go('/contact'),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              'Stripe-powered payments. We never see or store card numbers.',
              style: TextStyle(
                fontSize: 12,
                color: AppTheme.textTertiary,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// Helper widgets

class _NavLink extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _NavLink({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: onTap,
      child: Text(
        label,
        style: const TextStyle(
          color: AppTheme.textPrimary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _PillStat extends StatelessWidget {
  final String title;
  final String subtitle;

  const _PillStat({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      width: 330,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              fontSize: 16,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(
              fontSize: 14,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;

  const _FeatureCard({
    required this.title,
    required this.description,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(icon, color: AppTheme.primaryBlue, size: 24),
          ),
          const SizedBox(height: 16),
          Text(
            title,
            style: const TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: const TextStyle(
              fontSize: 14,
              color: AppTheme.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  final int? stepNumber;
  final String title;
  final String description;

  const _StepCard({
    this.stepNumber,
    required this.title,
    required this.description,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (stepNumber != null)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFEEF2FF),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Step $stepNumber',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 12,
                  color: AppTheme.primaryBlue,
                ),
              ),
            ),
          if (stepNumber != null) const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: const TextStyle(
              fontSize: 14,
              color: AppTheme.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _IntegrationLogo extends StatelessWidget {
  final String name;
  final IconData icon;

  const _IntegrationLogo({required this.name, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: AppTheme.textSecondary, size: 24),
          const SizedBox(width: 12),
          Text(
            name,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _BenefitCard extends StatelessWidget {
  final String title;
  final String description;

  const _BenefitCard({required this.title, required this.description});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: const TextStyle(
              fontSize: 14,
              color: AppTheme.textSecondary,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _TestimonialCard extends StatelessWidget {
  final String quote;
  final String name;
  final String role;

  const _TestimonialCard({
    required this.quote,
    required this.name,
    required this.role,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 400,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            quote,
            style: const TextStyle(
              fontSize: 16,
              fontStyle: FontStyle.italic,
              color: AppTheme.textPrimary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            name,
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: AppTheme.textPrimary,
            ),
          ),
          Text(
            role,
            style: const TextStyle(
              fontSize: 14,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

class _SecurityBullet extends StatelessWidget {
  final IconData icon;
  final String text;

  const _SecurityBullet({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: const Color(0xFF1D4ED8), size: 20),
        const SizedBox(width: 8),
        Text(
          text,
          style: const TextStyle(
            fontWeight: FontWeight.w600,
            fontSize: 14,
            color: AppTheme.textPrimary,
          ),
        ),
      ],
    );
  }
}

class _SecurityFAQItem extends StatelessWidget {
  final String question;
  final String answer;

  const _SecurityFAQItem({required this.question, required this.answer});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          question,
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 16,
            color: AppTheme.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          answer,
          style: const TextStyle(
            fontSize: 14,
            height: 1.5,
            color: AppTheme.textSecondary,
          ),
        ),
      ],
    );
  }
}

class _PricingFeature extends StatelessWidget {
  final String text;

  const _PricingFeature({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: AppTheme.primaryBlue, size: 20),
          const SizedBox(width: 12),
          Text(
            text,
            style: const TextStyle(
              fontSize: 16,
              color: AppTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }
}

class _FooterLink extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _FooterLink({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Text(
        label,
        style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 14,
          decoration: TextDecoration.underline,
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;

  const _Section({super.key, required this.child, required this.padding});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: child,
      ),
    );
  }
}

class _LandingScrollBehavior extends MaterialScrollBehavior {
  const _LandingScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => const ClampingScrollPhysics();
}
