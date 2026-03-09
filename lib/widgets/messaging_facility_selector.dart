import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:go_router/go_router.dart';
import '../services/facility_service.dart';
import '../screens/home_screen_modern_helper.dart';
import '../models/facility_model.dart';

/// Widget that handles facility selection for messaging screen
class MessagingFacilitySelector extends StatefulWidget {
  const MessagingFacilitySelector({super.key});

  @override
  State<MessagingFacilitySelector> createState() => _MessagingFacilitySelectorState();
}

class _MessagingFacilitySelectorState extends State<MessagingFacilitySelector> {
  bool _isLoading = true;
  bool _hasError = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _selectFacility();
    });
  }

  Future<void> _selectFacility() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _hasError = true;
            _errorMessage = 'Please sign in to access messaging';
          });
        }
        return;
      }

      final facilities = await FacilityService.getUserFacilities();
      
      if (facilities.isEmpty) {
        if (mounted) {
          setState(() {
            _isLoading = false;
            _hasError = true;
            _errorMessage = 'No facilities found. Please create a facility first.';
          });
        }
        return;
      }

      // If only one facility, use it directly
      if (facilities.length == 1) {
        if (mounted) {
          context.go('/messaging?facilityId=${facilities.first.id}');
        }
        return;
      }

      // Multiple facilities - show picker
      if (mounted) {
        final selected = await showModalBottomSheet<FacilitySelectResult>(
          context: context,
          builder: (context) => FacilityPickerSheet(facilities: facilities),
        );

        if (selected != null && mounted) {
          context.go('/messaging?facilityId=${selected.id}');
        } else if (mounted) {
          // User cancelled - go back to dashboard
          context.go('/dashboard');
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _hasError = true;
          _errorMessage = 'Error accessing messaging: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hasError) {
      return Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, size: 64, color: Colors.red),
                const SizedBox(height: 16),
                Text(
                  _errorMessage ?? 'An error occurred',
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => context.go('/dashboard'),
                  child: const Text('Back to Dashboard'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
