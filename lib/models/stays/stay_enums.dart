// Stays enums (spec §3.1, §3.3). Wire values are the lower_snake strings in
// functions-shared/src/stays/contracts.ts; a string the app does not know
// reads as `unknown` and renders neutrally instead of failing.

/// An enum written to Firestore or a callable as a string.
abstract interface class WireEnum {
  String get wire;
}

T wireEnumFrom<T extends WireEnum>(List<T> values, Object? value, T unknown) {
  if (value is! String) return unknown;
  for (final v in values) {
    if (v.wire == value) return v;
  }
  return unknown;
}

enum StayListingKind implements WireEnum {
  vacationRental('vacation_rental'),
  house('house'),
  cabin('cabin'),
  room('room'),
  rvSite('rv_site'),
  tentSite('tent_site'),
  garage('garage'),
  other('other'),
  unknown('unknown');

  const StayListingKind(this.wire);
  @override
  final String wire;
  static StayListingKind fromWire(Object? v) => wireEnumFrom(values, v, unknown);

  bool get isSite => this == rvSite || this == tentSite;
}

enum RvHookup implements WireEnum {
  full('full'),
  waterElectric('water_electric'),
  electric('electric'),
  dry('dry'),
  unknown('unknown');

  const RvHookup(this.wire);
  @override
  final String wire;
  static RvHookup fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum StayKind implements WireEnum {
  reservation('reservation'),
  ownerBlock('owner_block'),
  maintenanceBlock('maintenance_block'),
  unknown('unknown');

  const StayKind(this.wire);
  @override
  final String wire;
  static StayKind fromWire(Object? v) => wireEnumFrom(values, v, unknown);

  bool get isBlock => this == ownerBlock || this == maintenanceBlock;
}

enum StaySource implements WireEnum {
  airbnb('airbnb'),
  vrbo('vrbo'),
  booking('booking'),
  hipcamp('hipcamp'),
  otherChannel('other_channel'),
  direct('direct'),
  phone('phone'),
  walkUp('walk_up'),
  owner('owner'),
  unknown('unknown');

  const StaySource(this.wire);
  @override
  final String wire;
  static StaySource fromWire(Object? v) => wireEnumFrom(values, v, unknown);

  /// Booked by SFC itself (the `sfc` export scope).
  bool get isSfcBooking => this == direct || this == phone || this == walkUp;

  /// Another channel's booking.
  bool get isChannel => this == airbnb || this == vrbo || this == booking || this == hipcamp || this == otherChannel;
}

enum StayOrigin implements WireEnum {
  sfc('sfc'),
  feed('feed'),
  csv('csv'),
  unknown('unknown');

  const StayOrigin(this.wire);
  @override
  final String wire;
  static StayOrigin fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum StayStatus implements WireEnum {
  confirmed('confirmed'),
  conflict('conflict'),
  cancelled('cancelled'),
  removedFromFeed('removed_from_feed'),
  unknown('unknown');

  const StayStatus(this.wire);
  @override
  final String wire;
  static StayStatus fromWire(Object? v) => wireEnumFrom(values, v, unknown);

  /// Holds its nights.
  bool get isActive => this == confirmed || this == conflict;
}

enum StayArrivalState implements WireEnum {
  upcoming('upcoming'),
  checkedIn('checked_in'),
  checkedOut('checked_out'),
  noShow('no_show'),
  unknown('unknown');

  const StayArrivalState(this.wire);
  @override
  final String wire;
  static StayArrivalState fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum StayPaymentStatus implements WireEnum {
  none('none'),
  due('due'),
  partial('partial'),
  paid('paid'),
  channelCollected('channel_collected'),
  refunded('refunded'),
  unknown('unknown');

  const StayPaymentStatus(this.wire);
  @override
  final String wire;
  static StayPaymentStatus fromWire(Object? v) => wireEnumFrom(values, v, unknown);

  bool get hasBalance => this == due || this == partial;
}

enum ChannelProvider implements WireEnum {
  airbnb('airbnb'),
  vrbo('vrbo'),
  booking('booking'),
  google('google'),
  hipcamp('hipcamp'),
  other('other'),
  unknown('unknown');

  const ChannelProvider(this.wire);
  @override
  final String wire;
  static ChannelProvider fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum ChannelSyncStatus implements WireEnum {
  ok('ok'),
  notModified('not_modified'),
  httpError('http_error'),
  gone('gone'),
  invalidFeed('invalid_feed'),
  blockedHost('blocked_host'),
  timeout('timeout'),
  tooLarge('too_large'),
  suspicious('suspicious'),
  unknown('unknown');

  const ChannelSyncStatus(this.wire);
  @override
  final String wire;
  static ChannelSyncStatus fromWire(Object? v) => wireEnumFrom(values, v, unknown);

  bool get isHealthy => this == ok || this == notModified;
}

enum ExportTargetProvider implements WireEnum {
  airbnb('airbnb'),
  vrbo('vrbo'),
  booking('booking'),
  google('google'),
  other('other'),
  unknown('unknown');

  const ExportTargetProvider(this.wire);
  @override
  final String wire;
  static ExportTargetProvider fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum ExportScope implements WireEnum {
  blocksOnly('blocks_only'),
  sfc('sfc'),
  all('all'),
  unknown('unknown');

  const ExportScope(this.wire);
  @override
  final String wire;
  static ExportScope fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum StayTaskCategory implements WireEnum {
  turnover('turnover'),
  siteCheck('site_check'),
  maintenance('maintenance'),
  restock('restock'),
  general('general'),
  unknown('unknown');

  const StayTaskCategory(this.wire);
  @override
  final String wire;
  static StayTaskCategory fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum StayTaskStatus implements WireEnum {
  todo('todo'),
  inProgress('in_progress'),
  done('done'),
  skipped('skipped'),
  cancelled('cancelled'),
  unknown('unknown');

  const StayTaskStatus(this.wire);
  @override
  final String wire;
  static StayTaskStatus fromWire(Object? v) => wireEnumFrom(values, v, unknown);

  bool get isOpen => this == todo || this == inProgress;
}

enum StayTaskPriority implements WireEnum {
  normal('normal'),
  high('high'),
  unknown('unknown');

  const StayTaskPriority(this.wire);
  @override
  final String wire;
  static StayTaskPriority fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum TurnoverMode implements WireEnum {
  full('full'),
  quickCheck('quick_check'),
  none('none'),
  unknown('unknown');

  const TurnoverMode(this.wire);
  @override
  final String wire;
  static TurnoverMode fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum AccessCodeMode implements WireEnum {
  none('none'),
  staticCode('static'),
  perStay('per_stay'),
  phoneLast4('phone_last4'),
  unknown('unknown');

  const AccessCodeMode(this.wire);
  @override
  final String wire;
  static AccessCodeMode fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum StayAccessSource implements WireEnum {
  manual('manual'),
  phoneLast4('phone_last4'),
  staticCode('static'),
  unknown('unknown');

  const StayAccessSource(this.wire);
  @override
  final String wire;
  static StayAccessSource fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum StayIncomeSource implements WireEnum {
  manual('manual'),
  airbnbCsv('airbnb_csv'),
  unknown('unknown');

  const StayIncomeSource(this.wire);
  @override
  final String wire;
  static StayIncomeSource fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum StayIncomeMethod implements WireEnum {
  cash('cash'),
  check('check'),
  cardExternal('card_external'),
  venmo('venmo'),
  bank('bank'),
  airbnb('airbnb'),
  other('other'),
  unknown('unknown');

  const StayIncomeMethod(this.wire);
  @override
  final String wire;
  static StayIncomeMethod fromWire(Object? v) => wireEnumFrom(values, v, unknown);

  /// Methods a person records by hand (the CSV import alone writes 'airbnb').
  static const List<StayIncomeMethod> manual = [cash, check, cardExternal, venmo, bank, other];
}

enum StayIncomeKind implements WireEnum {
  stayPayment('stay_payment'),
  refundGiven('refund_given'),
  channelBooking('channel_booking'),
  adjustment('adjustment'),
  resolution('resolution'),
  cancellationFee('cancellation_fee'),
  channelTax('channel_tax'),
  payout('payout'),
  other('other'),
  unknown('unknown');

  const StayIncomeKind(this.wire);
  @override
  final String wire;
  static StayIncomeKind fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum StayExpenseCategory implements WireEnum {
  cleaning('cleaning'),
  supplies('supplies'),
  laundry('laundry'),
  utilities('utilities'),
  repairs('repairs'),
  channel('channel'),
  other('other'),
  unknown('unknown');

  const StayExpenseCategory(this.wire);
  @override
  final String wire;
  static StayExpenseCategory fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum StayMoneyEntryStatus implements WireEnum {
  posted('posted'),
  voided('voided'),
  unknown('unknown');

  const StayMoneyEntryStatus(this.wire);
  @override
  final String wire;
  static StayMoneyEntryStatus fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum StayImportBatchKind implements WireEnum {
  airbnbEarnings('airbnb_earnings'),
  airbnbReservations('airbnb_reservations'),
  unknown('unknown');

  const StayImportBatchKind(this.wire);
  @override
  final String wire;
  static StayImportBatchKind fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum StayImportBatchStatus implements WireEnum {
  previewed('previewed'),
  committed('committed'),
  unknown('unknown');

  const StayImportBatchStatus(this.wire);
  @override
  final String wire;
  static StayImportBatchStatus fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum TemplateChannelHint implements WireEnum {
  airbnbPaste('airbnb_paste'),
  email('email'),
  sms('sms'),
  print('print'),
  unknown('unknown');

  const TemplateChannelHint(this.wire);
  @override
  final String wire;
  static TemplateChannelHint fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum FolioLineCode implements WireEnum {
  lodging('lodging'),
  cleaning('cleaning'),
  pet('pet'),
  extraGuest('extra_guest'),
  adjustment('adjustment'),
  unknown('unknown');

  const FolioLineCode(this.wire);
  @override
  final String wire;
  static FolioLineCode fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum ConsentMethod implements WireEnum {
  verbal('verbal'),
  written('written'),
  bookingForm('booking_form'),
  unknown('unknown');

  const ConsentMethod(this.wire);
  @override
  final String wire;
  static ConsentMethod fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum SyncTrigger implements WireEnum {
  scheduled('scheduled'),
  manual('manual'),
  save('save'),
  drift('drift'),
  unknown('unknown');

  const SyncTrigger(this.wire);
  @override
  final String wire;
  static SyncTrigger fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}

enum StayReviewAction implements WireEnum {
  acknowledgeConflict('acknowledge_conflict'),
  restore('restore'),
  clearReview('clear_review'),
  unknown('unknown');

  const StayReviewAction(this.wire);
  @override
  final String wire;
  static StayReviewAction fromWire(Object? v) => wireEnumFrom(values, v, unknown);
}
