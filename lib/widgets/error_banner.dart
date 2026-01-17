import 'package:flutter/material.dart';
import 'package:sfcapp/services/error_reporter.dart';

/// A lightweight error banner widget that displays user-friendly error messages
/// for uncaught errors. This prevents blank screens and provides actionable feedback.
class ErrorBanner extends StatefulWidget {
  final Widget child;

  const ErrorBanner({
    super.key,
    required this.child,
  });

  @override
  State<ErrorBanner> createState() => _ErrorBannerState();
}

class _ErrorBannerState extends State<ErrorBanner> {
  String? _errorMessage;
  bool _isVisible = false;

  @override
  void initState() {
    super.initState();
    // Listen for errors from ErrorReporter
    // Note: This is a simple implementation. In production, you might want
    // to use a more sophisticated error state management system.
  }

  void _showError(String message) {
    if (mounted) {
      setState(() {
        _errorMessage = message;
        _isVisible = true;
      });
    }
  }

  void _dismissError() {
    if (mounted) {
      setState(() {
        _isVisible = false;
        _errorMessage = null;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        widget.child,
        if (_isVisible && _errorMessage != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Material(
                elevation: 4,
                color: Theme.of(context).colorScheme.errorContainer,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _errorMessage!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onErrorContainer,
                            fontSize: 14,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close),
                        color: Theme.of(context).colorScheme.onErrorContainer,
                        onPressed: _dismissError,
                        iconSize: 20,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// Global error handler that can be used to show errors in the ErrorBanner
class GlobalErrorHandler {
  static final GlobalErrorHandler _instance = GlobalErrorHandler._internal();
  factory GlobalErrorHandler() => _instance;
  GlobalErrorHandler._internal();

  final List<Function(String)> _listeners = [];

  void addListener(Function(String) listener) {
    _listeners.add(listener);
  }

  void removeListener(Function(String) listener) {
    _listeners.remove(listener);
  }

  void showError(String message) {
    for (var listener in _listeners) {
      listener(message);
    }
    // Also log to ErrorReporter
    ErrorReporter.reportError(
      Exception(message),
      null,
      context: 'GlobalErrorHandler',
    );
  }
}

