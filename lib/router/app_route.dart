/// Centralized route names/paths.
///
/// This file contains all route constants used throughout the application.
/// Routes are organized by category for easier maintenance.
class AppRoute {
  // Public routes (no authentication required)
  static const landing = '/';
  static const marketing = '/marketing';
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
  static const publicMapBase = '/public';
  static const publicFacilityRentalBase = '/f';

  // Main application routes (authentication required)
  static const dashboard = '/dashboard';
  static const facilities = '/facilities';
  static const facilityNew = '/facilities/new';
  static const facilityCreate = '/facilities/create';
  static const facilityEdit = '/facilities/edit';
  static const tenants = '/tenants';
  static const tenantDetail = '/tenants/detail';

  /// A tenant's detail page by id, for when there is no tenant to pass
  /// as `extra` (a reload or a link).
  static String tenantDetailFor({
    required String tenantId,
    required String facilityId,
  }) =>
      Uri(path: tenantDetail, queryParameters: {
        'tenantId': tenantId,
        'facilityId': facilityId,
      }).toString();

  /// A tenant's ledger by id (the tenant is read fresh).
  static String tenantLedgerFor({
    required String tenantId,
    required String facilityId,
  }) =>
      Uri(
        path: '/tenants/$tenantId/ledger',
        queryParameters: {'facilityId': facilityId},
      ).toString();

  static const tenantCsvImport = '/tenants/import-csv';
  static const units = '/units';
  static const unitsMap = '/units/map';
  static const unitDetail = '/units/detail';
  static const unitCreate = '/units/create';
  static const unitEdit = '/units/edit';
  static const managerOverlock = '/manager-overlock';
  static const contracts = '/contracts';
  static const contractDetail = '/contracts/detail';
  static const contractCreate = '/contracts/create';
  static const contractTemplates = '/contracts/templates';
  static const contractTemplatesCreate = '/contracts/templates/create';
  static const contractTemplatesEdit = '/contracts/templates/edit';
  static const contractSigningTest = '/contracts/sign/test';
  static const leaseTemplates = '/lease-templates';
  static const payments = '/payments';
  static String paymentsWithTab(String tab) => '/payments?tab=$tab';
  static const paymentsPastDue = '/payments?tab=past-due';
  static const paymentsInvoices = '/payments?tab=invoices';
  static const paymentsReminders = '/payments?tab=reminders';
  static const paymentsCollect = '/payments?tab=collect';
  static const paymentDetail = '/payments/detail';

  /// A payment's detail page by id, for when there is no payment to pass
  /// as `extra`. The page needs both ids to load it.
  static String paymentDetailFor({
    required String paymentId,
    required String facilityId,
  }) =>
      Uri(path: paymentDetail, queryParameters: {
        'paymentId': paymentId,
        'facilityId': facilityId,
      }).toString();

  static const paymentCreate = '/payments/create';
  static const paymentReconciliation = '/payments/reconciliation';
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
  static const textingSetup = '/settings/texting';
  static const permissionManagement = '/permissions';
  static const notificationSettings = '/settings/notifications';
  static const emailOptOutsSettings = '/settings/email-opt-outs';
  static const smsOptOutsSettings = '/settings/sms-opt-outs';
  static const profileEdit = '/settings/profile';
  static const appearanceSettings = '/settings/appearance';
  static const subscription = '/subscription';
  static const billing = '/billing';
  static const autopayActivity = '/autopay-activity';
  static const facilityNotifications = '/notifications';
  static const moveInWizard = '/move-in';
  static const moveOut = '/move-out';

  /// The move-out screen for [contractId]. [unitId] names the unit being
  /// vacated when the caller knows it (the unit's own menu); without it the
  /// screen works it out from the units the tenant holds.
  static String moveOutFor({
    required String contractId,
    required String facilityId,
    String? unitId,
  }) =>
      Uri(path: moveOut, queryParameters: {
        'contractId': contractId,
        'facilityId': facilityId,
        if (unitId != null && unitId.isNotEmpty) 'unitId': unitId,
      }).toString();
  static const contactLogs = '/contact-logs';

  /// A tenant's contact log (calls, texts, letters, notes).
  static String contactLogsFor({
    required String tenantId,
    required String facilityId,
  }) =>
      Uri(path: contactLogs, queryParameters: {
        'tenantId': tenantId,
        'facilityId': facilityId,
      }).toString();

  static const auditLogs = '/audit-logs';
  static const exports = '/exports';
  static const ledger = '/ledger';
  static const transfer = '/transfer';
  static const documents = '/documents';
  static const inventory = '/inventory';
  static const pos = '/pos';
  static const retailSales = '/retail-sales';

  /// Sidebar target only — resolves to [pos] with a facility (not a registered page path).
  static const retail = '/retail';
  static const recurringCharges = '/recurring-charges';
  static const automationPreview = '/automation-preview';

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
  static const onlineRentals = '/online-rentals';
  static const websiteSetup = '/website-setup';
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

  // Account approval holding screen
  static const pendingApproval = '/pending-approval';

  // Super admin
  static const superAdmin = '/super-admin';

  // Stays (short-term rentals). Every page takes ?facilityId=; the routes
  // are in stays_routes.dart.
  static const stays = '/stays';
  static const stayDetail = '/stays/booking';
  static const stayCreate = '/stays/booking/new';
  static const stayEdit = '/stays/booking/edit';
  static const turnoverDetail = '/stays/turnover';
  static const stayListingEdit = '/stays/listing/edit';
  static const staysSetup = '/stays/setup';
  static const staysChannels = '/stays/channels';
  static const staysEarningsImport = '/stays/earnings/import';
  static const staysGuests = '/stays/guests';
  static const staysTemplates = '/stays/templates';
  static const staysSettings = '/settings/stays';

  static String _withQuery(String path, Map<String, String?> params) => Uri(
        path: path,
        queryParameters: {
          for (final e in params.entries)
            if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
        },
      ).toString();

  /// The Stays hub on a tab: today, calendar, bookings, turnovers, earnings, listings.
  static String staysWithTab({required String facilityId, String tab = 'today'}) =>
      _withQuery(stays, {'facilityId': facilityId, 'tab': tab});

  static String stayDetailFor({required String facilityId, required String stayId}) =>
      _withQuery(stayDetail, {'facilityId': facilityId, 'stayId': stayId});

  /// A new booking or block, optionally prefilled (dates are 'YYYY-MM-DD').
  static String stayCreateFor({
    required String facilityId,
    String? listingId,
    String? checkIn,
    String? checkOut,
    String? kind,
  }) =>
      _withQuery(stayCreate, {
        'facilityId': facilityId,
        'listingId': listingId,
        'checkIn': checkIn,
        'checkOut': checkOut,
        'kind': kind,
      });

  static String stayEditFor({required String facilityId, required String stayId}) =>
      _withQuery(stayEdit, {'facilityId': facilityId, 'stayId': stayId});

  static String turnoverDetailFor({required String facilityId, required String taskId}) =>
      _withQuery(turnoverDetail, {'facilityId': facilityId, 'taskId': taskId});

  /// No listingId: a new listing.
  static String stayListingEditFor({required String facilityId, String? listingId}) =>
      _withQuery(stayListingEdit, {'facilityId': facilityId, 'listingId': listingId});

  static String staysSetupFor(String facilityId) => _withQuery(staysSetup, {'facilityId': facilityId});

  static String staysChannelsFor({required String facilityId, String? listingId}) =>
      _withQuery(staysChannels, {'facilityId': facilityId, 'listingId': listingId});

  static String staysEarningsImportFor(String facilityId) =>
      _withQuery(staysEarningsImport, {'facilityId': facilityId});

  static String staysGuestsFor(String facilityId) => _withQuery(staysGuests, {'facilityId': facilityId});

  static String staysTemplatesFor(String facilityId) => _withQuery(staysTemplates, {'facilityId': facilityId});

  static String staysSettingsFor(String facilityId) => _withQuery(staysSettings, {'facilityId': facilityId});

  // Other routes
  static const coupons = '/coupons';
  static const aiAssistant = '/ai-assistant';
  static const calendar = '/calendar';
  static const yieldManagement = '/yield';
  static const dataIntegrity = '/data-integrity';
  static const legacyScreen = '/_legacy';
}
