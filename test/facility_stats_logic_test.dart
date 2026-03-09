import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/utils/count_helpers.dart';

void main() {
  group('effectiveTotalUnits', () {
    test('uses facility totalUnits when > 0', () {
      expect(effectiveTotalUnits(200, 50), 200);
      expect(effectiveTotalUnits(1, 0), 1);
    });

    test('uses unit count when facility totalUnits is 0', () {
      expect(effectiveTotalUnits(0, 50), 50);
      expect(effectiveTotalUnits(0, 0), 0);
    });
  });
}
