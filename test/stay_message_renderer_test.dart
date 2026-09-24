import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/stays/stay_message_renderer.dart';

const _checkIn =
    'Hi {{guestFirstName}}! Check-in at {{listingName}} is {{checkInDate}} after {{checkInTime}}. '
    'Door code: {{doorCode}}. Wifi: {{wifiName}} / {{wifiPassword}}.';

final _values = <String, String?>{
  'guestFirstName': 'Jane',
  'listingName': 'Airbnb 1',
  'checkInDate': 'Oct 3',
  'checkInTime': '3:00 pm',
  'doorCode': '4821',
  'wifiName': 'Caprock',
  'wifiPassword': 'rvpark2026',
};

void main() {
  test('fills every known variable', () {
    expect(
      StayMessageRenderer.render(_checkIn, _values),
      'Hi Jane! Check-in at Airbnb 1 is Oct 3 after 3:00 pm. Door code: 4821. Wifi: Caprock / rvpark2026.',
    );
  });

  test('a missing or empty value shows as [name], never as a blank', () {
    final out = StayMessageRenderer.render(_checkIn, {..._values, 'doorCode': null, 'wifiName': '  '});
    expect(out, contains('Door code: [doorCode].'));
    expect(out, contains('Wifi: [wifiName] / rvpark2026.'));
  });

  test('an unknown variable is shown, not dropped or filled', () {
    expect(StayMessageRenderer.render('Hi {{nickname}}', {'nickname': 'JJ'}), 'Hi [nickname]');
  });

  test('spaces inside the braces are allowed', () {
    expect(StayMessageRenderer.render('At {{ listingName }}', _values), 'At Airbnb 1');
  });

  test('viewers never see codes or wifi, even when the values are there', () {
    final out = StayMessageRenderer.render(_checkIn, _values, canSeeAccess: false);
    expect(out, contains('Door code: [doorCode].'));
    expect(out, contains('Wifi: [wifiName] / [wifiPassword].'));
    expect(out, contains('Hi Jane!'));
    expect(out, isNot(contains('4821')));
  });

  test('"Copy for Airbnb scheduled messages" leaves guest-specific parts for Airbnb', () {
    final out = StayMessageRenderer.render(_checkIn, _values, forScheduledMessages: true);
    expect(out, contains('Hi [guestFirstName]!'));
    expect(out, contains('is [checkInDate] after 3:00 pm'));
    expect(out, contains('Door code: [doorCode].'));
    // Listing-level values are still filled.
    expect(out, contains('Airbnb 1'));
    expect(out, contains('Wifi: Caprock / rvpark2026.'));
  });

  test('lists the variables a body uses and the ones it cannot fill', () {
    expect(StayMessageRenderer.variablesIn('{{a}} {{listingName}} {{a}}'), ['a', 'listingName']);
    expect(
      StayMessageRenderer.missingIn(_checkIn, {..._values, 'doorCode': ''}),
      ['doorCode'],
    );
    expect(
      StayMessageRenderer.missingIn(_checkIn, _values, canSeeAccess: false),
      ['doorCode', 'wifiName', 'wifiPassword'],
    );
  });

  test('the variable catalogue matches the spec list', () {
    expect(StayMessageRenderer.variableNames, {
      'guestFirstName', 'guestName', 'listingName', 'siteCode', 'address', 'directionsUrl', 'checkInDate',
      'checkInTime', 'checkOutDate', 'checkOutTime', 'nights', 'adults', 'doorCode', 'lockboxCode', 'gateCode',
      'wifiName', 'wifiPassword', 'houseRules', 'parkingNotes', 'trashNotes', 'checkoutInstructions', 'hookups',
      'amps', 'maxLengthFt', 'quietHours', 'parkRules', 'totalDue', 'balanceDue', 'facilityName', 'facilityPhone',
    });
    expect(StayMessageRenderer.sensitiveVariables, containsAll(['doorCode', 'lockboxCode', 'gateCode', 'wifiName', 'wifiPassword']));
  });

  test('first name from a display name', () {
    expect(StayMessageRenderer.firstNameOf('Jane D.'), 'Jane');
    expect(StayMessageRenderer.firstNameOf('  '), '');
  });
}
