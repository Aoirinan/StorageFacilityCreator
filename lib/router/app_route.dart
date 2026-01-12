/// Centralized route names/paths.
/// 
/// This file contains all route constants used throughout the application.
/// Routes are organized by category for easier maintenance.
class AppRoute {
  // Public routes (no authentication required)
  static const landing = '/';
  static const login = '/login';
  static const signup = '/signup';
  static const forgotPassword = '/forgot-password';
  static const verifyEmail = '/verify-email';
  static const acceptInvite = '/accept-invite';
  static const tenantPortal = '/tenant-portal';
  static const contractSign = '/contracts/sign';
  static const publicPayment = '/pay';
  static const publicRental = '/rental';
  static const publicMoveIn = '/public-move-in';
  static const publicFacility = '/facility';

  // Main application routes (authentication required)
  static const dashboard = '/dashboard';
  static const facilities = '/facilities';
  static const facilityNew = '/facilities/new';
  static const facilityCreate = '/facilities/create';
  static const tenants = '/tenants';
  static const tenantDetail = '/tenants/detail';
  static const units = '/units';
  static const unitsMap = '/units/map';
  static const unitDetail = '/units/detail';
  static const contracts = '/contracts';
  static const contractDetail = '/contracts/detail';
  static const contractCreate = '/contracts/create';
  static const contractTemplates = '/contracts/templates';
  static const contractSigningTest = '/contracts/sign/test';
  static const payments = '/payments';
  static const paymentDetail = '/payments/detail';
  static const paymentCreate = '/payments/create';
  static const invoices = '/invoices';
  static const invoiceDetail = '/invoices/detail';
  static const deposits = '/deposits';
  static const depositDetail = '/deposits/detail';
  static const depositCreate = '/deposits/create';
  static const liens = '/liens';
  static const lienDetail = '/liens/detail';
  static const reminders = '/reminders';
  static const reminderCreate = '/reminders/create';
  static const reminderDetail = '/reminders/detail';
  static const reminderSchedule = '/reminders/schedule';
  static const dnr = '/dnr';
  static const delinquency = '/delinquency';
  static const access = '/access';
  static const messaging = '/messaging';
  static const smsConversations = '/messaging/sms';
  static const reports = '/reports';
  static const reportsFinancial = '/reports/financial';
  static const reportsConsolidated = '/reports/consolidated';
  static const settings = '/settings';
  static const notificationSettings = '/settings/notifications';
  static const profileEdit = '/settings/profile';
  static const appearanceSettings = '/settings/appearance';
  static const subscription = '/subscription';
  static const billing = '/billing';
  static const moveInWizard = '/move-in';
  static const moveOut = '/move-out';
  static const contactLogs = '/contact-logs';
  static const ledger = '/ledger';
  static const transfer = '/transfer';
  static const documents = '/documents';
  static const inventory = '/inventory';
  static const pos = '/pos';
  static const recurringCharges = '/recurring-charges';

  // Insurance routes
  static const insurance = '/insurance';
  static const insuranceSettings = '/settings/insurance';
  static const insuranceReport = '/reports/insurance';
  static const claims = '/claims';
  static const claimDetail = '/claims/:id';

  // Communication & templates
  static const bulkMessaging = '/communications/bulk-messaging';
  static const emailTemplates = '/templates/email';
  static const smsTemplates = '/templates/sms';
  static const paymentLinks = '/payment-links';
  static const communicationAnalytics = '/analytics/communication';

  // Automation routes
  static const escalationWorkflows = '/automation/escalations';
  static const conditionalRules = '/automation/conditional-rules';
  static const reportScheduling = '/report-scheduling';
  static const emailSequences = '/email-sequences';

  // Integration routes
  static const apiKeys = '/api-keys';
  static const webhooks = '/webhooks';
  static const stripeConnect = '/stripe-connect';

  // Other routes
  static const coupons = '/coupons';
  static const aiAssistant = '/ai-assistant';
  static const yieldManagement = '/yield';
  static const dataIntegrity = '/data-integrity';
  static const legacyScreen = '/_legacy';
}

