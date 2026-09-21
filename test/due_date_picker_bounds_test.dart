import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/screens/payment_creation_screen.dart';

void main() {
  final now = DateTime(2026, 9, 21, 14, 30);

  // showDatePicker throws when initialDate sits outside [firstDate, lastDate],
  // so every case here is really asking: would the picker have opened at all?
  void assertContains(DateTime selected) {
    final bounds = dueDatePickerBounds(selected: selected, now: now);
    expect(
      bounds.first.isAfter(selected),
      isFalse,
      reason: 'firstDate must not be after the date the picker opens on',
    );
    expect(
      bounds.last.isBefore(selected),
      isFalse,
      reason: 'lastDate must not be before the date the picker opens on',
    );
  }

  test('an ordinary future due date keeps the normal window', () {
    final bounds =
        dueDatePickerBounds(selected: DateTime(2026, 10, 21), now: now);
    expect(bounds.first, now);
    expect(bounds.last, now.add(const Duration(days: 365)));
  });

  test('a back-dated due date widens the range instead of throwing', () {
    // The calendar's "add a payment due on this date" passes the tapped day,
    // which is routinely in the past. With firstDate pinned to now, opening
    // the picker asserted.
    final backDated = DateTime(2026, 3, 1);
    assertContains(backDated);
    final bounds = dueDatePickerBounds(selected: backDated, now: now);
    expect(bounds.first, backDated);
    expect(bounds.last, now.add(const Duration(days: 365)));
  });

  test('a due date beyond a year out widens the other end', () {
    final farOut = DateTime(2029, 1, 1);
    assertContains(farOut);
    expect(dueDatePickerBounds(selected: farOut, now: now).last, farOut);
  });

  test('today itself is inside the range', () {
    assertContains(now);
    assertContains(DateTime(2026, 9, 21));
  });

  test('the range is never inverted', () {
    for (final selected in [
      DateTime(2020, 1, 1),
      DateTime(2026, 9, 20, 23, 59),
      now,
      DateTime(2026, 9, 22),
      DateTime(2027, 9, 21),
      DateTime(2035, 6, 15),
    ]) {
      final bounds = dueDatePickerBounds(selected: selected, now: now);
      expect(bounds.first.isAfter(bounds.last), isFalse,
          reason: 'bounds inverted for $selected');
      assertContains(selected);
    }
  });
}
