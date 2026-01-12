import 'package:flutter/foundation.dart';

class ValidationService {
  // Email validation
  static String? validateEmail(String? value) {
    if (value == null || value.isEmpty) {
      return 'Email is required';
    }
    
    final emailRegex = RegExp(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');
    if (!emailRegex.hasMatch(value)) {
      return 'Please enter a valid email address';
    }
    
    return null;
  }

  // Phone number validation
  static String? validatePhone(String? value) {
    if (value == null || value.isEmpty) {
      return 'Phone number is required';
    }
    
    // Remove all non-digit characters
    final digitsOnly = value.replaceAll(RegExp(r'[^\d]'), '');
    
    if (digitsOnly.length < 10) {
      return 'Phone number must be at least 10 digits';
    }
    
    if (digitsOnly.length > 15) {
      return 'Phone number cannot exceed 15 digits';
    }
    
    return null;
  }

  // Name validation
  static String? validateName(String? value, {String fieldName = 'Name'}) {
    if (value == null || value.isEmpty) {
      return '$fieldName is required';
    }
    
    if (value.length < 2) {
      return '$fieldName must be at least 2 characters';
    }
    
    if (value.length > 50) {
      return '$fieldName cannot exceed 50 characters';
    }
    
    // Check for valid characters (letters, spaces, hyphens, apostrophes)
    final nameRegex = RegExp(r"^[a-zA-Z\s\-']+$");
    if (!nameRegex.hasMatch(value)) {
      return '$fieldName can only contain letters, spaces, hyphens, and apostrophes';
    }
    
    return null;
  }

  // Address validation
  static String? validateAddress(String? value) {
    if (value == null || value.isEmpty) {
      return 'Address is required';
    }
    
    if (value.length < 5) {
      return 'Address must be at least 5 characters';
    }
    
    if (value.length > 200) {
      return 'Address cannot exceed 200 characters';
    }
    
    return null;
  }

  // City validation
  static String? validateCity(String? value) {
    if (value == null || value.isEmpty) {
      return 'City is required';
    }
    
    if (value.length < 2) {
      return 'City must be at least 2 characters';
    }
    
    if (value.length > 50) {
      return 'City cannot exceed 50 characters';
    }
    
    return null;
  }

  // State validation
  static String? validateState(String? value) {
    if (value == null || value.isEmpty) {
      return 'State is required';
    }
    
    if (value.length < 2) {
      return 'State must be at least 2 characters';
    }
    
    if (value.length > 50) {
      return 'State cannot exceed 50 characters';
    }
    
    return null;
  }

  // ZIP code validation
  static String? validateZipCode(String? value) {
    if (value == null || value.isEmpty) {
      return 'ZIP code is required';
    }
    
    // US ZIP code pattern (5 digits or 5+4 format)
    final zipRegex = RegExp(r'^\d{5}(-\d{4})?$');
    if (!zipRegex.hasMatch(value)) {
      return 'Please enter a valid ZIP code (e.g., 12345 or 12345-6789)';
    }
    
    return null;
  }

  // Amount validation
  static String? validateAmount(String? value, {double? minAmount, double? maxAmount}) {
    if (value == null || value.isEmpty) {
      return 'Amount is required';
    }
    
    final amount = double.tryParse(value);
    if (amount == null) {
      return 'Please enter a valid amount';
    }
    
    if (amount <= 0) {
      return 'Amount must be greater than 0';
    }
    
    if (minAmount != null && amount < minAmount) {
      return 'Amount must be at least \$${minAmount.toStringAsFixed(2)}';
    }
    
    if (maxAmount != null && amount > maxAmount) {
      return 'Amount cannot exceed \$${maxAmount.toStringAsFixed(2)}';
    }
    
    return null;
  }

  // Unit number validation
  static String? validateUnitNumber(String? value) {
    if (value == null || value.isEmpty) {
      return 'Unit number is required';
    }
    
    if (value.length > 20) {
      return 'Unit number cannot exceed 20 characters';
    }
    
    return null;
  }

  // Dimensions validation
  static String? validateDimensions(String? value) {
    if (value == null || value.isEmpty) {
      return 'Dimensions are required';
    }
    
    // Check for format like "10x10x8" or "10 x 10 x 8"
    final dimensionsRegex = RegExp(r'^\d+(\.\d+)?\s*[xX×]\s*\d+(\.\d+)?\s*[xX×]\s*\d+(\.\d+)?$');
    if (!dimensionsRegex.hasMatch(value)) {
      return 'Please enter dimensions in format: Length x Width x Height (e.g., 10x10x8)';
    }
    
    return null;
  }

  // Password validation
  static String? validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Password is required';
    }
    
    if (value.length < 8) {
      return 'Password must be at least 8 characters';
    }
    
    if (value.length > 128) {
      return 'Password cannot exceed 128 characters';
    }
    
    // Check for at least one uppercase letter
    if (!value.contains(RegExp(r'[A-Z]'))) {
      return 'Password must contain at least one uppercase letter';
    }
    
    // Check for at least one lowercase letter
    if (!value.contains(RegExp(r'[a-z]'))) {
      return 'Password must contain at least one lowercase letter';
    }
    
    // Check for at least one digit
    if (!value.contains(RegExp(r'[0-9]'))) {
      return 'Password must contain at least one digit';
    }
    
    return null;
  }

  // Confirm password validation
  static String? validateConfirmPassword(String? value, String? password) {
    if (value == null || value.isEmpty) {
      return 'Please confirm your password';
    }
    
    if (value != password) {
      return 'Passwords do not match';
    }
    
    return null;
  }

  // Date validation
  static String? validateDate(DateTime? value, {String fieldName = 'Date'}) {
    if (value == null) {
      return '$fieldName is required';
    }
    
    final now = DateTime.now();
    if (value.isBefore(DateTime(1900))) {
      return '$fieldName cannot be before 1900';
    }
    
    if (value.isAfter(DateTime(2100))) {
      return '$fieldName cannot be after 2100';
    }
    
    return null;
  }

  // Future date validation
  static String? validateFutureDate(DateTime? value, {String fieldName = 'Date'}) {
    final dateError = validateDate(value, fieldName: fieldName);
    if (dateError != null) return dateError;
    
    if (value!.isBefore(DateTime.now())) {
      return '$fieldName must be in the future';
    }
    
    return null;
  }

  // Past date validation
  static String? validatePastDate(DateTime? value, {String fieldName = 'Date'}) {
    final dateError = validateDate(value, fieldName: fieldName);
    if (dateError != null) return dateError;
    
    if (value!.isAfter(DateTime.now())) {
      return '$fieldName must be in the past';
    }
    
    return null;
  }

  // Required field validation
  static String? validateRequired(String? value, {String fieldName = 'Field'}) {
    if (value == null || value.isEmpty) {
      return '$fieldName is required';
    }
    
    return null;
  }

  // Text length validation
  static String? validateTextLength(String? value, {int minLength = 1, int maxLength = 1000, String fieldName = 'Text'}) {
    if (value == null || value.isEmpty) {
      return '$fieldName is required';
    }
    
    if (value.length < minLength) {
      return '$fieldName must be at least $minLength characters';
    }
    
    if (value.length > maxLength) {
      return '$fieldName cannot exceed $maxLength characters';
    }
    
    return null;
  }

  // URL validation
  static String? validateUrl(String? value) {
    if (value == null || value.isEmpty) {
      return 'URL is required';
    }
    
    final urlRegex = RegExp(r'^https?:\/\/(www\.)?[-a-zA-Z0-9@:%._\+~#=]{1,256}\.[a-zA-Z0-9()]{1,6}\b([-a-zA-Z0-9()@:%_\+.~#?&//=]*)$');
    if (!urlRegex.hasMatch(value)) {
      return 'Please enter a valid URL';
    }
    
    return null;
  }

  // Business logic validations

  // Validate facility creation
  static Map<String, String?> validateFacility({
    required String? name,
    required String? address,
    required String? city,
    required String? state,
    required String? zipCode,
    String? phone,
    String? email,
  }) {
    return {
      'name': validateName(name, fieldName: 'Facility name'),
      'address': validateAddress(address),
      'city': validateCity(city),
      'state': validateState(state),
      'zipCode': validateZipCode(zipCode),
      'phone': phone != null && phone.isNotEmpty ? validatePhone(phone) : null,
      'email': email != null && email.isNotEmpty ? validateEmail(email) : null,
    };
  }

  // Validate tenant creation
  static Map<String, String?> validateTenant({
    required String? name,
    required String? email,
    required String? phone,
    String? address,
    String? city,
    String? state,
    String? zipCode,
  }) {
    return {
      'name': validateName(name, fieldName: 'Tenant name'),
      'email': validateEmail(email),
      'phone': validatePhone(phone),
      'address': address != null && address.isNotEmpty ? validateAddress(address) : null,
      'city': city != null && city.isNotEmpty ? validateCity(city) : null,
      'state': state != null && state.isNotEmpty ? validateState(state) : null,
      'zipCode': zipCode != null && zipCode.isNotEmpty ? validateZipCode(zipCode) : null,
    };
  }

  // Validate unit creation
  static Map<String, String?> validateUnit({
    required String? unitNumber,
    required String? dimensions,
    required String? monthlyRate,
  }) {
    return {
      'unitNumber': validateUnitNumber(unitNumber),
      'dimensions': validateDimensions(dimensions),
      'monthlyRate': validateAmount(monthlyRate, minAmount: 1.0, maxAmount: 10000.0),
    };
  }

  // Validate payment creation
  static Map<String, String?> validatePayment({
    required String? amount,
    required DateTime? dueDate,
    String? notes,
  }) {
    return {
      'amount': validateAmount(amount, minAmount: 0.01, maxAmount: 100000.0),
      'dueDate': validateDate(dueDate, fieldName: 'Due date'),
      'notes': notes != null && notes.isNotEmpty ? validateTextLength(notes, maxLength: 500, fieldName: 'Notes') : null,
    };
  }

  // Validate contract creation
  static Map<String, String?> validateContract({
    required String? tenantId,
    required String? unitId,
    required DateTime? startDate,
    required DateTime? endDate,
    required String? monthlyRate,
  }) {
    final errors = <String, String?>{};
    
    errors['tenantId'] = validateRequired(tenantId, fieldName: 'Tenant');
    errors['unitId'] = validateRequired(unitId, fieldName: 'Unit');
    errors['startDate'] = validateDate(startDate, fieldName: 'Start date');
    errors['endDate'] = validateDate(endDate, fieldName: 'End date');
    errors['monthlyRate'] = validateAmount(monthlyRate, minAmount: 1.0, maxAmount: 10000.0);
    
    // Validate date range
    if (startDate != null && endDate != null) {
      if (endDate.isBefore(startDate)) {
        errors['endDate'] = 'End date must be after start date';
      }
      
      final duration = endDate.difference(startDate);
      if (duration.inDays < 30) {
        errors['endDate'] = 'Contract must be at least 30 days long';
      }
    }
    
    return errors;
  }

  // Check if validation has any errors
  static bool hasErrors(Map<String, String?> validationResults) {
    return validationResults.values.any((error) => error != null);
  }

  // Get first error message
  static String? getFirstError(Map<String, String?> validationResults) {
    for (final error in validationResults.values) {
      if (error != null) return error;
    }
    return null;
  }

  // Get all error messages
  static List<String> getAllErrors(Map<String, String?> validationResults) {
    return validationResults.values.where((error) => error != null).cast<String>().toList();
  }

  // Sanitize input
  static String sanitizeInput(String input) {
    return input.trim().replaceAll(RegExp(r'\s+'), ' ');
  }

  // Validate and sanitize
  static String? validateAndSanitize(String? value, String? Function(String?) validator) {
    if (value == null) return null;
    
    final sanitized = sanitizeInput(value);
    return validator(sanitized);
  }
}
