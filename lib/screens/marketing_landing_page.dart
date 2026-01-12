import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../router/app_router.dart';
import '../router/app_route.dart';
import '../theme/app_theme.dart';
import '../services/home_button_service.dart';

/// Modern marketing landing page for web.
class MarketingLandingPage extends StatefulWidget {
  MarketingLandingPage({super.key});

  @override
  State<MarketingLandingPage> createState() => _MarketingLandingPageState();
}

class _MarketingLandingPageState extends State<MarketingLandingPage> {
  final GlobalKey _featuresKey = GlobalKey();
  final GlobalKey _faqKey = GlobalKey();

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
                  _TopNav(onFeatures: () => _scrollTo(_featuresKey), onFAQ: () => _scrollTo(_faqKey)),
                  _Section(
                    padding: const EdgeInsets.symmetric(vertical: 44),
                    child: _HeroBlock(onFeatures: () => _scrollTo(_featuresKey)),
                  ),
                  _Section(
                    padding: const EdgeInsets.symmetric(vertical: 26),
                    child: _TrustStrip(),
                  ),
                  Container(
                    color: const Color(0xFFF7F9FC),
                    child: Column(
                      children: [
                        _Section(
                          key: _featuresKey,
                          padding: const EdgeInsets.symmetric(vertical: 38),
                          child: _FeaturesGrid(),
                        ),
                        _Section(
                          padding: const EdgeInsets.symmetric(vertical: 36),
                          child: _HowItWorks(),
                        ),
                      ],
                    ),
                  ),
                  _Section(
                    padding: const EdgeInsets.symmetric(vertical: 34),
                    child: _Benefits(),
                  ),
                  _Section(
                    padding: const EdgeInsets.symmetric(vertical: 34),
                    child: _SocialProof(),
                  ),
                  _Section(
                    key: _faqKey,
                    padding: const EdgeInsets.symmetric(vertical: 32),
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
  final VoidCallback onFAQ;

  const _TopNav({required this.onFeatures, required this.onFAQ});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 16),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.9),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1200),
        child: Row(
          children: [
            Row(
              children: [
                Container(
                  width: 36,
                  height: 36,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1E3A8A), Color(0xFF2563EB)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.storage_rounded, color: Colors.white),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Storage Facility Creator',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ],
            ),
            const Spacer(),
            Wrap(
              spacing: 10,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _NavLink(label: 'Product', onTap: onFeatures),
                _NavLink(label: 'Features', onTap: onFeatures),
                _NavLink(label: 'Solutions', onTap: onFeatures),
                _NavLink(label: 'Resources', onTap: onFAQ),
                TextButton(
                  onPressed: () => context.go(AppRoute.login),
                  child: const Text('Sign In'),
                ),
                ElevatedButton(
                  onPressed: () => context.go(AppRoute.signup),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
                  ),
                  child: const Text('Request Demo'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _HeroBlock extends StatelessWidget {
  final VoidCallback onFeatures;

  const _HeroBlock({required this.onFeatures});

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1180),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth > 900;
          return Flex(
            direction: isWide ? Axis.horizontal : Axis.vertical,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 3,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                          decoration: BoxDecoration(
                            color: const Color(0xFFDBEAFE),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: const Text(
                            'Built for multi-facility operators',
                            style: TextStyle(
                              color: Color(0xFF1D4ED8),
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Color(0xFF10B981),
                          ),
                        ),
                        const SizedBox(width: 4),
                        const Text(
                          'Live',
                          style: TextStyle(color: AppTheme.textSecondary),
                        ),
                      ],
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      'Operate every storage facility from one modern workspace.',
                      style: TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.1,
                        height: 1.12,
                        color: AppTheme.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 14),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 640),
                      child: const Text(
                        'Unify rentals, billing, access control, messaging, and reporting so teams stay aligned across locations.',
                        style: TextStyle(
                          fontSize: 17,
                          height: 1.5,
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    Wrap(
                      spacing: 12,
                      runSpacing: 10,
                      children: [
                        ElevatedButton(
                          onPressed: () => context.go(AppRoute.signup),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: AppTheme.primaryBlue,
                            foregroundColor: Colors.white,
                            padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            textStyle: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          child: const Text('Get Started'),
                        ),
                        OutlinedButton(
                          onPressed: onFeatures,
                          style: OutlinedButton.styleFrom(
                            side: const BorderSide(color: AppTheme.primaryBlue),
                            foregroundColor: AppTheme.primaryBlue,
                            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            textStyle: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          child: const Text('View Features'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(width: isWide ? 32 : 0, height: isWide ? 0 : 24),
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: isWide ? 380 : double.infinity,
                  minWidth: isWide ? 300 : double.infinity,
                ),
                child: Container(
                  height: 230,
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.borderLight),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withOpacity(0.045),
                        blurRadius: 14,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: const [
                      Text(
                        'Snapshot',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                          color: AppTheme.textPrimary,
                        ),
                      ),
                      SizedBox(height: 10),
                      _MetricCard(title: 'Occupancy', value: '94%', change: '+2.1% vs last month'),
                      SizedBox(height: 10),
                      _MetricCard(title: 'Payments processed', value: '\$218,450', change: '+\$12,400 this week'),
                      SizedBox(height: 10),
                      _MetricCard(title: 'Units available', value: '38', change: 'Balanced across 5 facilities'),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _TrustStrip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final stats = [
      ('Built for modern self-storage operators', 'Designed to keep multi-site teams aligned.'),
      ('Enterprise-ready', 'Role-based access, audit trails, multi-facility structure.'),
      ('Automation-first', 'Billing, notices, and messaging stay in sync.'),
    ];
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1200),
      child: Wrap(
        spacing: 14,
        runSpacing: 12,
        children: stats
            .map((s) => _PillStat(title: s.$1, subtitle: s.$2))
            .toList(),
      ),
    );
  }
}

class _FeaturesGrid extends StatelessWidget {
  final features = const [
    ('Tenant operations', 'Online move-ins, renewals, and ID capture in one place.', Icons.people_alt_outlined),
    ('Unit & map control', 'Visual maps with status, holds, and maintenance flags.', Icons.map_outlined),
    ('Billing & payments', 'Recurring billing, dunning, and card-on-file support.', Icons.receipt_long_outlined),
    ('Delinquency & liens', 'Stage-based workflows with notices and audit logging.', Icons.report_outlined),
    ('Messaging', 'Email/SMS templates with delivery status and opt-ins.', Icons.chat_bubble_outline),
    ('Reporting', 'Portfolio dashboards, exports, and scheduled delivery.', Icons.insights_outlined),
  ];

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 1200),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Everything operators need, packaged for the web.',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.w800, color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 14),
          const Text(
            'Purpose-built modules that stay synced across facilities.',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 22),
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
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 16,
                  childAspectRatio: 1.6,
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
    ('Setup', 'Import units, gate settings, and staff roles for each site.'),
    ('Manage', 'Automate billing cadence, notices, and messaging templates.'),
    ('Grow', 'Track occupancy, collections, and communications in real time.'),
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
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(
            builder: (context, constraints) {
              final isWide = constraints.maxWidth > 900;
              final cardWidth = isWide ? (constraints.maxWidth - 32) / 3 : double.infinity;
              return Wrap(
                spacing: isWide ? 16 : 12,
                runSpacing: 12,
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

class _Benefits extends StatelessWidget {
  final benefits = const [
    ('Reduce manual work', 'Automate billing, notices, and messaging so teams stay ahead.'),
    ('Centralize facilities', 'One workspace for units, tenants, payments, and communications.'),
    ('Scale without complexity', 'Multi-facility structure that keeps data consistent as you grow.'),
    ('Built for SaaS multi-tenancy', 'Role-based access and auditability for every site.'),
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
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 18),
          Wrap(
            spacing: 14,
            runSpacing: 14,
            children: benefits
                .map(
                  (b) => _BenefitCard(
                    title: b.$1,
                    description: b.$2,
                  ),
                )
                .toList(),
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
      padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Trusted by operators who want clean, predictable systems.',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.textPrimary),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 8,
              children: const [
                _AvatarPlaceholder(label: 'Ops lead'),
                _AvatarPlaceholder(label: 'General manager'),
                _AvatarPlaceholder(label: 'Collections'),
              ],
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 14,
              runSpacing: 14,
              children: List.generate(
                2,
                (_) => const _TestimonialCard(
                  quote: '“The portfolio view keeps every facility aligned without extra spreadsheets.”',
                  name: 'Operations lead',
                  role: 'Multi-site storage operator',
                ),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: const [
                _LogoPlaceholder(),
                _LogoPlaceholder(),
                _LogoPlaceholder(),
                _LogoPlaceholder(),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _FAQ extends StatelessWidget {
  final faqs = const [
    ('Does this replace my gate system?', 'We integrate with existing access controls; operators keep their hardware.'),
    ('How do teams sign in?', 'Role-based access with MFA-ready auth. Invite teammates directly.'),
    ('Is there an app?', 'The web experience is responsive; operators can pin it to home screens.'),
    ('Can we migrate data?', 'Yes. Import units, tenants, and balances in a guided flow.'),
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
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w800, color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 12),
          ...faqs.map(
            (f) => Card(
              elevation: 0,
              margin: const EdgeInsets.symmetric(vertical: 6),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: const BorderSide(color: AppTheme.borderLight),
              ),
              child: ExpansionTile(
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                title: Text(
                  f.$1,
                  style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
                ),
                children: [
                  Text(f.$2, style: const TextStyle(color: AppTheme.textSecondary)),
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
      color: AppTheme.primaryBlue,
      padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Ready to modernize your storage operations?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 24,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Spin up a portfolio-ready workspace, invite your team, and start automating collections.',
              style: TextStyle(color: Colors.white70, fontSize: 16),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 12,
              children: [
                ElevatedButton(
                  onPressed: () => context.go(AppRoute.signup),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.white,
                    foregroundColor: AppTheme.primaryBlue,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                  ),
                  child: const Text('Get Started'),
                ),
                OutlinedButton(
                  onPressed: () => context.go(AppRoute.login),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.white),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 22),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Row(
          children: [
            const Text(
              'Storage Facility Creator',
              style: TextStyle(fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
            ),
            const Spacer(),
            Wrap(
              spacing: 16,
              children: const [
                Text('Privacy', style: TextStyle(color: AppTheme.textSecondary)),
                Text('Terms', style: TextStyle(color: AppTheme.textSecondary)),
                Text('Contact', style: TextStyle(color: AppTheme.textSecondary)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

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
        style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  final String title;
  final String value;
  final String change;

  const _MetricCard({required this.title, required this.value, required this.change});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: AppTheme.primaryBlue),
          ),
          const SizedBox(height: 4),
          Text(change, style: const TextStyle(color: AppTheme.textSecondary)),
        ],
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
      padding: const EdgeInsets.all(14),
      width: 330,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.textPrimary)),
          const SizedBox(height: 4),
          Text(subtitle, style: const TextStyle(color: AppTheme.textSecondary)),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final String title;
  final String description;
  final IconData icon;

  const _FeatureCard({required this.title, required this.description, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFEFF6FF),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: AppTheme.primaryBlue),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 6),
          Text(description, style: const TextStyle(color: AppTheme.textSecondary, height: 1.35)),
        ],
      ),
    );
  }
}

class _StepCard extends StatelessWidget {
  final int? stepNumber;
  final String title;
  final String description;

  const _StepCard({this.stepNumber, required this.title, required this.description});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
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
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFFEEF2FF),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                'Step $stepNumber',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppTheme.primaryBlue,
                ),
              ),
            ),
          if (stepNumber != null) const SizedBox(height: 10),
          Text(
            title,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            description,
            style: const TextStyle(color: AppTheme.textSecondary, height: 1.4),
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
      width: 320,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            quote,
            style: const TextStyle(
              fontStyle: FontStyle.italic,
              color: AppTheme.textPrimary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            name,
            style: const TextStyle(fontWeight: FontWeight.w700, color: AppTheme.textPrimary),
          ),
          Text(
            role,
            style: const TextStyle(color: AppTheme.textSecondary),
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
      width: 320,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppTheme.textPrimary),
          ),
          const SizedBox(height: 8),
          Text(
            description,
            style: const TextStyle(color: AppTheme.textSecondary, height: 1.4),
          ),
        ],
      ),
    );
  }
}

class _LogoPlaceholder extends StatelessWidget {
  const _LogoPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 150,
      height: 56,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.borderLight),
      ),
      alignment: Alignment.center,
      child: const Text('Logo placeholder', style: TextStyle(color: AppTheme.textSecondary)),
    );
  }
}

class _AvatarPlaceholder extends StatelessWidget {
  final String label;
  const _AvatarPlaceholder({required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 30,
          height: 30,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Color(0xFFE5E7EB),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.person_outline, size: 16, color: AppTheme.textSecondary),
        ),
        const SizedBox(width: 6),
        Text(label, style: const TextStyle(color: AppTheme.textSecondary)),
      ],
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
      child: child,
    );
  }
}

class _LandingScrollBehavior extends MaterialScrollBehavior {
  const _LandingScrollBehavior();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) => const ClampingScrollPhysics();
}

