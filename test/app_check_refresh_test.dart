import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/services/app_check_service.dart';

void main() {
  final now = DateTime(2026, 9, 23, 12);

  test('the first token request of a page load is not forced', () {
    // It was: with no refresh recorded yet, every production startup forced a
    // reCAPTCHA run and token exchange although the SDK's cached token was
    // still valid (the SDK already replaces an expired one on its own).
    expect(
      AppCheckService.shouldForceTokenRefresh(lastRefresh: null, now: now),
      isFalse,
    );
  });

  test('a token this service fetched long ago in this session is still refreshed', () {
    expect(
      AppCheckService.shouldForceTokenRefresh(
        lastRefresh: now.subtract(const Duration(hours: 10)),
        now: now,
      ),
      isFalse,
    );
    expect(
      AppCheckService.shouldForceTokenRefresh(
        lastRefresh: now.subtract(const Duration(hours: 134)),
        now: now,
      ),
      isTrue,
    );
  });
}
