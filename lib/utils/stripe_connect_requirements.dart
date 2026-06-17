/// Human-readable labels for Stripe Connect account.requirements fields.
String stripeConnectRequirementLabel(String field) {
  const labels = <String, String>{
    'business_profile.url': 'Business website URL',
    'business_profile.product_description': 'Business description',
    'business_profile.support_phone': 'Support phone number',
    'business_profile.mcc': 'Business category (MCC)',
    'external_account': 'Bank account for payouts',
    'tos_acceptance.date': 'Accept Stripe terms of service',
    'tos_acceptance.ip': 'Accept Stripe terms of service',
    'individual.email': 'Owner email',
    'individual.first_name': 'Owner first name',
    'individual.last_name': 'Owner last name',
    'individual.phone': 'Owner phone',
    'individual.address.line1': 'Owner address',
    'individual.address.city': 'Owner city',
    'individual.address.state': 'Owner state',
    'individual.address.postal_code': 'Owner ZIP code',
    'company.name': 'Company name',
    'company.phone': 'Company phone',
    'company.address.line1': 'Company address',
    'company.tax_id': 'Company tax ID',
    'representative.first_name': 'Representative first name',
    'representative.last_name': 'Representative last name',
    'owners.email': 'Owner verification email',
    'owners.first_name': 'Owner first name',
    'owners.last_name': 'Owner last name',
  };
  if (labels.containsKey(field)) return labels[field]!;
  if (field.startsWith('individual.')) {
    return 'Owner: ${field.replaceFirst('individual.', '').replaceAll('_', ' ')}';
  }
  if (field.startsWith('company.')) {
    return 'Company: ${field.replaceFirst('company.', '').replaceAll('_', ' ')}';
  }
  return field.replaceAll('_', ' ').replaceAll('.', ' — ');
}

List<String> uniqueStripeConnectRequirements({
  required List<String> currentlyDue,
  required List<String> pastDue,
}) {
  final seen = <String>{};
  final out = <String>[];
  for (final field in [...pastDue, ...currentlyDue]) {
    if (field.isEmpty || seen.contains(field)) continue;
    seen.add(field);
    out.add(field);
  }
  return out;
}
