// Fakes a Firestore snapshot to read a facility doc without a database.
// ignore_for_file: subtype_of_sealed_class

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/document_logo_layout.dart';
import 'package:sfcapp/models/facility_model.dart';

void main() {
  group('DocumentLogoLayout', () {
    test('defaults keep the original statement look', () {
      const d = DocumentLogoLayout.defaults;
      expect(d.height, 64);
      expect(d.position, DocumentLogoPosition.left);
      expect(d.showName, isTrue);
    });

    test('round-trips through its map', () {
      const layout = DocumentLogoLayout(
        height: 120,
        position: DocumentLogoPosition.center,
        showName: false,
      );
      expect(layout.toMap(),
          {'height': 120.0, 'position': 'center', 'showName': false});
      expect(DocumentLogoLayout.fromMap(layout.toMap()), layout);
    });

    test('missing or malformed values fall back per field', () {
      expect(DocumentLogoLayout.fromMap(null), DocumentLogoLayout.defaults);
      expect(DocumentLogoLayout.fromMap('left'), DocumentLogoLayout.defaults);
      expect(DocumentLogoLayout.fromMap(<String, dynamic>{}),
          DocumentLogoLayout.defaults);

      final mixed = DocumentLogoLayout.fromMap({
        'height': 'big',
        'position': 'upside-down',
        'showName': 'no',
      });
      expect(mixed, DocumentLogoLayout.defaults);

      // Firestore hands back ints for whole numbers.
      expect(DocumentLogoLayout.fromMap({'height': 100}).height, 100);
      expect(DocumentLogoLayout.fromMap({'position': 'above'}).position,
          DocumentLogoPosition.above);
    });

    test('height is kept within the slider range', () {
      expect(DocumentLogoLayout.fromMap({'height': 5}).height,
          DocumentLogoLayout.minHeight);
      expect(DocumentLogoLayout.fromMap({'height': 9000}).height,
          DocumentLogoLayout.maxHeight);
      expect(DocumentLogoLayout.fromMap({'height': double.nan}).height,
          DocumentLogoLayout.defaultHeight);
      expect(DocumentLogoLayout.defaults.copyWith(height: 1000).height,
          DocumentLogoLayout.maxHeight);
    });

    test('the name is only hidden when a logo actually prints', () {
      const hidden = DocumentLogoLayout(showName: false);
      expect(hidden.nameVisible(logoShown: true), isFalse);
      expect(hidden.nameVisible(logoShown: false), isTrue);
      expect(DocumentLogoLayout.defaults.nameVisible(logoShown: true), isTrue);
    });

    test('a logo beside the details is held narrower than one on its own line',
        () {
      double w(DocumentLogoPosition p) =>
          DocumentLogoLayout(position: p).maxWidth;
      expect(w(DocumentLogoPosition.left), lessThan(w(DocumentLogoPosition.above)));
      expect(w(DocumentLogoPosition.above),
          lessThan(w(DocumentLogoPosition.center)));
      // Never wider than the PDF page's 468pt content area.
      expect(w(DocumentLogoPosition.center), lessThanOrEqualTo(468));
    });
  });

  group('FacilityModel.documentLogo', () {
    test('reads the stored map, and defaults when the facility has none', () {
      final withLayout = FacilityModel.fromFirestore(_Snap('with', {
        'name': 'Caprock Storage',
        'ownerUid': 'o',
        'createdAt': Timestamp.now(),
        'documentLogo': {'height': 96, 'position': 'above', 'showName': false},
      }));
      expect(
        withLayout.documentLogo,
        const DocumentLogoLayout(
          height: 96,
          position: DocumentLogoPosition.above,
          showName: false,
        ),
      );

      final without = FacilityModel.fromFirestore(_Snap('without', {
        'name': 'Keepsake',
        'ownerUid': 'o',
        'createdAt': Timestamp.now(),
      }));
      expect(without.documentLogo, DocumentLogoLayout.defaults);
      // A facility that never set it does not get the field written back.
      expect(without.toFirestore().containsKey('documentLogo'), isFalse);
      expect(withLayout.toFirestore()['documentLogo'],
          {'height': 96.0, 'position': 'above', 'showName': false});
    });

    test('copyWith carries it over and replaces it', () {
      final f = FacilityModel(
        id: 'f',
        name: 'F',
        ownerUid: 'o',
        createdAt: DateTime(2026),
        documentLogo: const DocumentLogoLayout(height: 100),
      );
      expect(f.copyWith(name: 'G').documentLogo.height, 100);
      expect(
        f
            .copyWith(
                documentLogo:
                    const DocumentLogoLayout(position: DocumentLogoPosition.center))
            .documentLogo
            .position,
        DocumentLogoPosition.center,
      );
    });
  });
}

class _Snap extends Fake implements DocumentSnapshot<Map<String, dynamic>> {
  _Snap(this.id, this._data);

  @override
  final String id;
  final Map<String, dynamic> _data;

  @override
  Map<String, dynamic> data() => _data;
}
