import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:sfcapp/models/global_dnr_model.dart';
import 'package:sfcapp/services/global_dnr_service.dart';

GlobalDNREntryModel _entry({
  GlobalDnrStatus status = GlobalDnrStatus.active,
}) {
  return GlobalDNREntryModel(
    id: 'dnr-1',
    fullName: 'Jane Example',
    phone: '(555) 867-5309',
    email: 'jane@example.com',
    reason: 'Documented policy violations',
    status: status,
    createdAt: DateTime.utc(2026, 7, 19),
    createdByUserId: 'user-1',
    createdByFacilityId: 'facility-1',
    reportedByName: 'Pat Manager',
    reportedByEmail: 'pat@example.com',
    linkedTenantId: 'tenant-1',
  );
}

void main() {
  group('GlobalDNRService.isPhotoFilename', () {
    test('recognizes supported image extensions case-insensitively', () {
      for (final filename in [
        'evidence.jpg',
        'evidence.JPEG',
        'evidence.png',
        'evidence.gif',
        'evidence.webp',
        'evidence.heic',
        'evidence.bmp',
      ]) {
        expect(
          GlobalDNRService.isPhotoFilename(filename),
          isTrue,
          reason: '$filename should be treated as photo evidence',
        );
      }
    });

    test('does not classify documents or extensionless files as photos', () {
      for (final filename in [
        'incident-report.pdf',
        'statement.docx',
        'evidence',
        'photo.jpg.pdf',
      ]) {
        expect(
          GlobalDNRService.isPhotoFilename(filename),
          isFalse,
          reason: '$filename should be treated as document evidence',
        );
      }
    });
  });

  group('GlobalDNRService.globalEntryMatchesTenantSearch', () {
    test('matches normalized partial name, email, and phone values', () {
      final entry = _entry();

      expect(
        GlobalDNRService.globalEntryMatchesTenantSearch(
          entry: entry,
          name: 'jane',
        ),
        isTrue,
      );
      expect(
        GlobalDNRService.globalEntryMatchesTenantSearch(
          entry: entry,
          email: 'JANE@EXAMPLE.COM',
        ),
        isTrue,
      );
      expect(
        GlobalDNRService.globalEntryMatchesTenantSearch(
          entry: entry,
          phone: '867-5309',
        ),
        isTrue,
      );
    });

    test('never returns inactive entries even when identity fields match', () {
      final entry = _entry(status: GlobalDnrStatus.inactive);

      expect(
        GlobalDNRService.globalEntryMatchesTenantSearch(
          entry: entry,
          name: entry.fullName,
          email: entry.email,
          phone: entry.phone,
        ),
        isFalse,
      );
    });

    test('does not match blank or unrelated identity fields', () {
      final entry = _entry();

      expect(
        GlobalDNRService.globalEntryMatchesTenantSearch(
          entry: entry,
          name: '',
          email: '',
          phone: 'not-a-phone-number',
        ),
        isFalse,
      );
      expect(
        GlobalDNRService.globalEntryMatchesTenantSearch(
          entry: entry,
          name: 'John Other',
          email: 'other@example.com',
          phone: '555-000-0000',
        ),
        isFalse,
      );
    });
  });

  group('GlobalDNREntryModel attribution', () {
    test('reads reporter and linked-tenant fields from stored data', () {
      final entry = GlobalDNREntryModel.fromMap(
        id: 'dnr-2',
        data: {
          'fullName': 'Jane Example',
          'phone': '5558675309',
          'email': 'jane@example.com',
          'reason': 'Documented policy violations',
          'createdAt': Timestamp.fromDate(DateTime.utc(2026, 7, 19)),
          'createdByUserId': 'user-1',
          'createdByFacilityId': 'facility-1',
          'reportedByName': 'Pat Manager',
          'reportedByEmail': 'pat@example.com',
          'linkedTenantId': 'tenant-1',
        },
      );

      expect(entry.reportedByName, 'Pat Manager');
      expect(entry.reportedByEmail, 'pat@example.com');
      expect(entry.linkedTenantId, 'tenant-1');
    });

    test('persists and copies reporter and linked-tenant fields', () {
      final entry = _entry();

      expect(
        entry.toFirestore(),
        containsPair('reportedByName', 'Pat Manager'),
      );
      expect(
        entry.toFirestore(),
        containsPair('reportedByEmail', 'pat@example.com'),
      );
      expect(entry.toFirestore(), containsPair('linkedTenantId', 'tenant-1'));

      final copied = entry.copyWith(
        reportedByName: 'Alex Owner',
        reportedByEmail: 'alex@example.com',
        linkedTenantId: 'tenant-2',
      );
      expect(copied.reportedByName, 'Alex Owner');
      expect(copied.reportedByEmail, 'alex@example.com');
      expect(copied.linkedTenantId, 'tenant-2');
    });

    test('omits absent reporter and linked-tenant fields', () {
      final entry = GlobalDNREntryModel(
        id: 'dnr-3',
        fullName: 'Manual Entry',
        phone: '',
        email: '',
        reason: 'Documented policy violations',
        createdAt: DateTime.utc(2026, 7, 19),
        createdByUserId: 'user-1',
        createdByFacilityId: 'facility-1',
      );

      final data = entry.toFirestore();
      expect(data, isNot(contains('reportedByName')));
      expect(data, isNot(contains('reportedByEmail')));
      expect(data, isNot(contains('linkedTenantId')));
    });
  });
}
