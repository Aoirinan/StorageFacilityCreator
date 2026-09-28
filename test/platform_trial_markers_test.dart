import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/platform_trial_markers.dart';

void main() {
  const stamp = 'STAMP';

  test('revoking a trial granted before the marker existed records the marker', () {
    final fields = revokeTrialFields({
      'subscriptionStatus': 'trialing',
      'subscriptionTrialEnd': DateTime.utc(2026, 10, 21),
    }, stamp: stamp);
    expect(fields['subscriptionStatus'], 'cancelled');
    expect(fields.containsKey('subscriptionTrialEnd'), isTrue);
    expect(fields['subscriptionTrialEnd'], isNull);
    expect(fields['platformTrialUsedAt'], stamp);
  });

  test('revoking keeps an existing marker untouched', () {
    final fields = revokeTrialFields({
      'subscriptionStatus': 'trialing',
      'platformTrialUsedAt': DateTime.utc(2026, 9, 1),
    }, stamp: stamp);
    expect(fields.containsKey('platformTrialUsedAt'), isFalse);
    expect(fields['subscriptionStatus'], 'cancelled');
  });

  test('a missing account document still gets the marker', () {
    expect(revokeTrialFields(null, stamp: stamp)['platformTrialUsedAt'], stamp);
  });
}
