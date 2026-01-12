import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'contract_signing_screen.dart';
import '../theme/app_theme.dart';
import '../router/app_router.dart';
import '../router/app_route.dart';

/// Test screen to easily access the contract signing screen with a token
/// This is for testing purposes - in production, tenants would access via email links
class ContractSigningTestScreen extends ConsumerStatefulWidget {
  const ContractSigningTestScreen({super.key});

  @override
  ConsumerState<ContractSigningTestScreen> createState() => _ContractSigningTestScreenState();
}

class _ContractSigningTestScreenState extends ConsumerState<ContractSigningTestScreen> {
  final _tokenController = TextEditingController();

  @override
  void dispose() {
    _tokenController.dispose();
    super.dispose();
  }

  void _navigateToSigning() {
    final token = _tokenController.text.trim();
    if (token.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a signing token'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    context.push('${AppRoute.contractSign}?token=$token');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Test Contract Signing'),
        backgroundColor: AppTheme.primaryBlueDark,
        foregroundColor: AppTheme.textOnDark,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Contract Signing Test',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Text(
                      'Enter a signing token to test the contract signing flow. '
                      'You can get a signing token by sending a contract for signature from the contract detail screen.',
                    ),
                    const SizedBox(height: 24),
                    TextField(
                      controller: _tokenController,
                      decoration: const InputDecoration(
                        labelText: 'Signing Token',
                        hintText: 'Paste signing token here',
                        border: OutlineInputBorder(),
                        prefixIcon: Icon(Icons.key),
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: _navigateToSigning,
                      icon: const Icon(Icons.edit),
                      label: const Text('Open Signing Screen'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlueDark,
                        foregroundColor: AppTheme.textOnDark,
                        padding: const EdgeInsets.symmetric(vertical: 16),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            Card(
              color: AppTheme.primaryBlue.withOpacity(0.1),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.info_outline, color: AppTheme.primaryBlue),
                        const SizedBox(width: 8),
                        Text(
                          'How to Test',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.primaryBlue,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '1. Go to Contracts section\n'
                      '2. Create or open a contract\n'
                      '3. Click "Send" to send it for signature\n'
                      '4. Check the console/logs for the signing token\n'
                      '5. Paste the token above and click "Open Signing Screen"',
                      style: TextStyle(fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

