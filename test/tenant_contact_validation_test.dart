import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/utils/tenant_contact_validation.dart';

void main() {
  group('validateOptionalTenantEmail', () {
    test('accepts a blank address, because most tenants do not have one on file', () {
      expect(validateOptionalTenantEmail(null), isNull);
      expect(validateOptionalTenantEmail(''), isNull);
      expect(validateOptionalTenantEmail('   '), isNull);
    });

    test('accepts ordinary addresses', () {
      expect(validateOptionalTenantEmail('alexa@caprockstorage.com'), isNull);
      expect(validateOptionalTenantEmail('first.last+unit12@gmail.com'), isNull);
    });

    test('accepts the longer top-level domains the old four-letter limit rejected', () {
      expect(validateOptionalTenantEmail('owner@caprock.storage'), isNull);
      expect(validateOptionalTenantEmail('owner@example.online'), isNull);
    });

    test('still rejects something that is not an address', () {
      expect(validateOptionalTenantEmail('not-an-address'), isNotNull);
      expect(validateOptionalTenantEmail('missing@domain'), isNotNull);
      expect(validateOptionalTenantEmail('two words@example.com'), isNotNull);
    });

    test('says that leaving it blank is allowed', () {
      expect(validateOptionalTenantEmail('nope'), contains('blank'));
    });
  });

  group('isSendableTenantEmail', () {
    test('a blank or malformed address is not sendable', () {
      expect(isSendableTenantEmail(null), isFalse);
      expect(isSendableTenantEmail(''), isFalse);
      expect(isSendableTenantEmail('   '), isFalse);
      expect(isSendableTenantEmail('nope'), isFalse);
    });

    test('a real address is sendable', () {
      expect(isSendableTenantEmail(' alexa@caprockstorage.com '), isTrue);
    });
  });
}
