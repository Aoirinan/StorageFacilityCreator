import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/two_factor_service.dart';
import '../theme/app_theme.dart';

/// Dialog for entering OTP code
/// 
/// Usage:
/// ```dart
/// final code = await showDialog<String>(
///   context: context,
///   builder: (context) => OTPInputDialog(
///     purpose: 'delete_facility',
///     onRequestOTP: () async {
///       return await TwoFactorService.requestOTP(purpose: 'delete_facility');
///     },
///   ),
/// );
/// ```
class OTPInputDialog extends StatefulWidget {
  final String? purpose;
  final Future<TwoFactorResult> Function()? onRequestOTP;
  final String title;
  final String message;
  final String? actionName; // e.g., "delete this facility"
  /// When true, dialog shows "Code sent" + Resend instead of "Send Verification Code".
  /// Use when OTP was already requested before showing the dialog (e.g. login flow).
  final bool initialOtpRequested;
  final int initialExpiresIn; // Used when initialOtpRequested is true (seconds).
  /// Optional initial error (e.g. rate limit) to show when opening the dialog.
  final String? initialErrorMessage;

  const OTPInputDialog({
    super.key,
    this.purpose,
    this.onRequestOTP,
    this.title = 'Verification Required',
    this.message = 'Please enter the 6-digit code sent to your email.',
    this.actionName,
    this.initialOtpRequested = false,
    this.initialExpiresIn = 600,
    this.initialErrorMessage,
  });

  @override
  State<OTPInputDialog> createState() => _OTPInputDialogState();
}

class _OTPInputDialogState extends State<OTPInputDialog> {
  final List<TextEditingController> _controllers = List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _focusNodes = List.generate(6, (_) => FocusNode());
  bool _isLoading = false;
  bool _isRequestingOTP = false;
  String? _errorMessage;
  late int _expiresIn;
  late bool _otpRequested;

  @override
  void initState() {
    super.initState();
    _otpRequested = widget.initialOtpRequested;
    _expiresIn = widget.initialExpiresIn;
    _errorMessage = widget.initialErrorMessage;
  }

  @override
  void dispose() {
    for (var controller in _controllers) {
      controller.dispose();
    }
    for (var node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  Future<void> _requestOTP() async {
    if (_isRequestingOTP) return;

    setState(() {
      _isRequestingOTP = true;
      _errorMessage = null;
    });

    try {
      final result = widget.onRequestOTP != null
          ? await widget.onRequestOTP!()
          : await TwoFactorService.requestOTP(purpose: widget.purpose);

      if (result.success) {
        setState(() {
          _otpRequested = true;
          _expiresIn = result.expiresIn ?? 600;
          _errorMessage = null;
        });

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Verification code sent to your email. Expires in ${_expiresIn ~/ 60} minutes.'),
              backgroundColor: AppTheme.success,
              duration: const Duration(seconds: 3),
            ),
          );
        }
      } else {
        // Check for rate limiting or service errors
        String errorMsg = result.error ?? 'Failed to send verification code';
        if (result.errorCode == 'resource-exhausted' ||
            errorMsg.contains('429') ||
            errorMsg.contains('Too Many Requests') ||
            errorMsg.contains('wait')) {
          // Prefer backend message if it includes remaining seconds (e.g. "You can request a new code in 42 seconds")
          if (!errorMsg.contains('second') && !errorMsg.contains('minute')) {
            errorMsg = 'Please wait before requesting another code. The code request limit has been reached.';
          }
        } else if (errorMsg.contains('500') || errorMsg.contains('Internal Server Error')) {
          errorMsg = 'The verification service is temporarily unavailable. Please try again in a moment.';
        }

        setState(() {
          _errorMessage = errorMsg;
        });
      }
    } catch (e) {
      String errorMsg = 'Error: $e';
      if (e.toString().contains('429') || e.toString().contains('Too Many Requests')) {
        errorMsg = 'Please wait before requesting another code.';
      } else if (e.toString().contains('500')) {
        errorMsg = 'The verification service is temporarily unavailable. Please try again in a moment.';
      }
      
      setState(() {
        _errorMessage = errorMsg;
      });
    } finally {
      setState(() {
        _isRequestingOTP = false;
      });
    }
  }

  void _onCodeChanged(int index, String value) {
    if (value.length == 1 && index < 5) {
      _focusNodes[index + 1].requestFocus();
    } else if (value.isEmpty && index > 0) {
      _focusNodes[index - 1].requestFocus();
    }

    // Auto-submit when all 6 digits are entered
    if (index == 5 && value.length == 1) {
      final code = _controllers.map((c) => c.text).join();
      if (code.length == 6) {
        _verifyOTP(code);
      }
    }
  }

  Future<void> _verifyOTP(String code) async {
    if (_isLoading) return;

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final result = await TwoFactorService.verifyOTP(
        code: code,
        purpose: widget.purpose,
      );

      if (result.success) {
        if (mounted) {
          Navigator.of(context).pop(code);
        }
      } else {
        setState(() {
          _errorMessage = result.error ?? 'Invalid verification code';
        });
        // Clear all fields
        for (var controller in _controllers) {
          controller.clear();
        }
        _focusNodes[0].requestFocus();
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error: $e';
      });
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _submit() {
    final code = _controllers.map((c) => c.text).join();
    if (code.length == 6) {
      _verifyOTP(code);
    } else {
      setState(() {
        _errorMessage = 'Please enter all 6 digits';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Icon(Icons.security, color: AppTheme.primaryBlue),
          const SizedBox(width: 8),
          Expanded(child: Text(widget.title)),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.actionName != null) ...[
              Text(
                'To ${widget.actionName}, please verify your identity.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
            ],
            Text(
              widget.message,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            
            // OTP Input Fields
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: List.generate(6, (index) {
                return SizedBox(
                  width: 55,
                  height: 70,
                  child: TextField(
                    controller: _controllers[index],
                    focusNode: _focusNodes[index],
                    textAlign: TextAlign.center,
                    keyboardType: TextInputType.number,
                    maxLength: 1,
                    style: TextStyle(
                      fontSize: 36,
                      fontWeight: FontWeight.w900, // Extra bold for maximum visibility
                      color: const Color(0xFF000000), // Pure black for maximum contrast
                      letterSpacing: 4,
                      height: 1.0,
                    ),
                    decoration: InputDecoration(
                      counterText: '',
                      filled: true,
                      fillColor: const Color(0xFFFFFFFF), // Pure white background
                      contentPadding: const EdgeInsets.symmetric(vertical: 16),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: Color(0xFF000000),
                          width: 2.5,
                        ),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: Color(0xFF000000),
                          width: 2.5,
                        ),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: AppTheme.primaryBlue,
                          width: 4,
                        ),
                      ),
                      errorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: AppTheme.error,
                          width: 3,
                        ),
                      ),
                      focusedErrorBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: const BorderSide(
                          color: AppTheme.error,
                          width: 4,
                        ),
                      ),
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    onChanged: (value) => _onCodeChanged(index, value),
                    onSubmitted: (value) {
                      if (index == 5) _submit();
                    },
                  ),
                );
              }),
            ),
            
            const SizedBox(height: 16),
            
            // Error Message
            if (_errorMessage != null)
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.error),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, color: AppTheme.error, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: const TextStyle(color: AppTheme.error, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            
            const SizedBox(height: 16),
            
            // Request OTP Button
            if (!_otpRequested)
              OutlinedButton.icon(
                onPressed: _isRequestingOTP ? null : _requestOTP,
                icon: _isRequestingOTP
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.email),
                label: Text(_isRequestingOTP ? 'Sending...' : 'Send Verification Code'),
              )
            else
              Column(
                children: [
                  Text(
                    'Code sent! Check your email. Expires in ${_expiresIn ~/ 60} minutes.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.success,
                        ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _isRequestingOTP ? null : _requestOTP,
                    icon: _isRequestingOTP
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh, size: 16),
                    label: Text(_isRequestingOTP ? 'Sending...' : 'Resend Code'),
                  ),
                ],
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primaryBlue,
            foregroundColor: Colors.white,
          ),
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                  ),
                )
              : const Text('Verify'),
        ),
      ],
    );
  }
}

/// Helper function to show OTP input dialog
Future<String?> showOTPInputDialog(
  BuildContext context, {
  String? purpose,
  Future<TwoFactorResult> Function()? onRequestOTP,
  String? title,
  String? message,
  String? actionName,
  bool initialOtpRequested = false,
  int initialExpiresIn = 600,
  String? initialErrorMessage,
}) async {
  return await showDialog<String>(
    context: context,
    barrierDismissible: false,
    builder: (context) => OTPInputDialog(
      purpose: purpose,
      onRequestOTP: onRequestOTP,
      title: title ?? 'Verification Required',
      message: message ?? 'Please enter the 6-digit code sent to your email.',
      actionName: actionName,
      initialOtpRequested: initialOtpRequested,
      initialExpiresIn: initialExpiresIn,
      initialErrorMessage: initialErrorMessage,
    ),
  );
}
