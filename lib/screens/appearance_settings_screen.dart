import 'package:flutter/material.dart';
import '../widgets/modern_page_wrapper.dart';
import '../theme/app_theme.dart';
import '../services/modern_navigation_service.dart';
import '../widgets/keyboard_scrollable.dart';

class AppearanceSettingsScreen extends StatefulWidget {
  const AppearanceSettingsScreen({super.key});

  @override
  State<AppearanceSettingsScreen> createState() => _AppearanceSettingsScreenState();
}

class _AppearanceSettingsScreenState extends State<AppearanceSettingsScreen> {
  String _selectedTheme = 'light'; // 'light', 'dark', 'system'
  double _fontSize = 1.0; // 0.8, 0.9, 1.0, 1.1, 1.2
  bool _compactMode = false;

  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/settings',
      title: 'Appearance Settings',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      child: KeyboardScrollable(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16.0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Theme Selection
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Theme',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 16),
                      RadioListTile<String>(
                        title: const Text('Light'),
                        subtitle: const Text('Use light theme'),
                        value: 'light',
                        groupValue: _selectedTheme,
                        onChanged: (value) {
                          setState(() {
                            _selectedTheme = value!;
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Theme preference saved (will apply on next app restart)'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                      RadioListTile<String>(
                        title: const Text('Dark'),
                        subtitle: const Text('Use dark theme'),
                        value: 'dark',
                        groupValue: _selectedTheme,
                        onChanged: (value) {
                          setState(() {
                            _selectedTheme = value!;
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Theme preference saved (will apply on next app restart)'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                      RadioListTile<String>(
                        title: const Text('System Default'),
                        subtitle: const Text('Follow system theme'),
                        value: 'system',
                        groupValue: _selectedTheme,
                        onChanged: (value) {
                          setState(() {
                            _selectedTheme = value!;
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                              content: Text('Theme preference saved (will apply on next app restart)'),
                              duration: Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Font Size
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Font Size',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Text('Small'),
                          Expanded(
                            child: Slider(
                              value: _fontSize,
                              min: 0.8,
                              max: 1.2,
                              divisions: 4,
                              label: _getFontSizeLabel(_fontSize),
                              onChanged: (value) {
                                setState(() {
                                  _fontSize = value;
                                });
                              },
                            ),
                          ),
                          const Text('Large'),
                        ],
                      ),
                      Center(
                        child: Text(
                          'Preview: The quick brown fox jumps over the lazy dog',
                          style: TextStyle(fontSize: 14 * _fontSize),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Display Options
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Display Options',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                      const SizedBox(height: 16),
                      SwitchListTile(
                        title: const Text('Compact Mode'),
                        subtitle: const Text('Reduce spacing and padding for more content'),
                        value: _compactMode,
                        onChanged: (value) {
                          setState(() {
                            _compactMode = value;
                          });
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                value
                                    ? 'Compact mode enabled'
                                    : 'Compact mode disabled',
                              ),
                              duration: const Duration(seconds: 2),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // Info Card
              Card(
                color: AppTheme.info.withOpacity(0.1),
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Row(
                    children: [
                      const Icon(Icons.info_outline, color: AppTheme.info),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          'Some appearance settings will require an app restart to take full effect.',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _getFontSizeLabel(double size) {
    if (size <= 0.9) return 'Small';
    if (size <= 1.0) return 'Normal';
    if (size <= 1.1) return 'Large';
    return 'Extra Large';
  }
}

