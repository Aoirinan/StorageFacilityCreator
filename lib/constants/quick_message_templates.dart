class QuickMessageTemplate {
  final String label;
  final String? subject;
  final String body;

  const QuickMessageTemplate({
    required this.label,
    this.subject,
    required this.body,
  });
}

/// Shared starter messages for email/bulk messaging.
/// Supports placeholders: {{tenant_name}}, {{name}}, {{first_name}}, {{unit}}, {{email}}, {{phone}}.
const List<QuickMessageTemplate> kQuickMessageTemplates = [
  QuickMessageTemplate(
    label: 'Payment reminder',
    subject: 'Reminder: storage rent',
    body:
        'Hi {{first_name}},\n\n'
        'This is a friendly reminder about your upcoming storage rent. If you have already paid, please disregard this message.\n\n'
        'Thank you,\nManagement',
  ),
  QuickMessageTemplate(
    label: 'Past due notice',
    subject: 'Important: past due balance',
    body:
        'Hi {{first_name}},\n\n'
        'Our records show a past-due balance on your account for unit {{unit}}. Please contact us at your earliest convenience to arrange payment or discuss options.\n\n'
        'Thank you,\nManagement',
  ),
  QuickMessageTemplate(
    label: 'Thank you',
    subject: 'Thank you',
    body:
        'Hi {{first_name}},\n\n'
        'Thank you for being a valued customer. We appreciate your business.\n\n'
        'Best regards,\nManagement',
  ),
  QuickMessageTemplate(
    label: 'Document / update needed',
    subject: 'Action needed for your account',
    body:
        'Hi {{first_name}},\n\n'
        'We need a quick update for your account (unit {{unit}}). Please reply to this message or call the office when you have a moment.\n\n'
        'Thank you,\nManagement',
  ),
  QuickMessageTemplate(
    label: 'Blank greeting',
    body:
        'Hi {{first_name}},\n\n'
        '\n\n'
        'Best regards,\nManagement',
  ),
];
