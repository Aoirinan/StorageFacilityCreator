import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/models/document_logo_layout.dart';
import 'package:sfcapp/widgets/document_logo_layout_editor.dart';

/// A 4x1 PNG, wide like a logo with the business name in it.
final _logo = MemoryImage(base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAQAAAABCAIAAAB2XpiaAAAADUlEQVR4nGOQs+qCIwAVUQOJi/CUgQAAAABJRU5ErkJggg=='));

/// The editor as Edit Facility hosts it: the screen holds the value and
/// rebuilds on change.
Future<List<DocumentLogoLayout>> _pumpEditor(
  WidgetTester tester, {
  DocumentLogoLayout initial = DocumentLogoLayout.defaults,
  ImageProvider? logo,
}) async {
  final changes = <DocumentLogoLayout>[];
  var value = initial;
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(
          width: 700,
          child: StatefulBuilder(
            builder: (context, setState) => DocumentLogoLayoutEditor(
              value: value,
              onChanged: (v) => setState(() {
                value = v;
                changes.add(v);
              }),
              logo: logo,
              facilityName: 'Caprock Storage',
              address: '100 Main St\nLubbock, TX 79401',
              mailingAddress: 'PO Box 42',
              phone: '806-555-0100',
            ),
          ),
        ),
      ),
    ),
  ));
  return changes;
}

double _previewLogoHeight(WidgetTester tester) =>
    tester.getSize(find.byKey(DocumentLetterheadPreview.logoKey)).height;

void main() {
  testWidgets('the preview logo follows the size slider', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final changes = await _pumpEditor(tester, logo: _logo);
    expect(_previewLogoHeight(tester), DocumentLogoLayout.defaultHeight);
    expect(find.text('0.89 in tall'), findsOneWidget);

    // Drag the thumb all the way right: the largest logo.
    final slider = find.byKey(const ValueKey('document-logo-size-slider'));
    await tester.drag(slider, const Offset(1000, 0));
    await tester.pumpAndSettle();
    expect(changes.last.height, DocumentLogoLayout.maxHeight);
    expect(_previewLogoHeight(tester), DocumentLogoLayout.maxHeight);

    // And all the way left: the smallest.
    await tester.drag(slider, const Offset(-2000, 0));
    await tester.pumpAndSettle();
    expect(changes.last.height, DocumentLogoLayout.minHeight);
    expect(_previewLogoHeight(tester), DocumentLogoLayout.minHeight);
  });

  testWidgets('position buttons move the logo in the preview', (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final changes = await _pumpEditor(tester, logo: _logo);
    final logo = find.byKey(DocumentLetterheadPreview.logoKey);
    final name = find.byKey(DocumentLetterheadPreview.nameKey);

    // Left: beside the name, on the same line.
    expect(tester.getTopLeft(logo).dx, lessThan(tester.getTopLeft(name).dx));
    expect(tester.getTopLeft(logo).dy, closeTo(tester.getTopLeft(name).dy, 1));

    await tester.tap(find.text('Above details'));
    await tester.pumpAndSettle();
    expect(changes.last.position, DocumentLogoPosition.above);
    expect(tester.getBottomLeft(logo).dy,
        lessThanOrEqualTo(tester.getTopLeft(name).dy));
    expect(tester.getTopLeft(logo).dx, closeTo(tester.getTopLeft(name).dx, 1));

    await tester.tap(find.text('Centered at top'));
    await tester.pumpAndSettle();
    expect(changes.last.position, DocumentLogoPosition.center);
    expect(tester.getBottomLeft(logo).dy,
        lessThanOrEqualTo(tester.getTopLeft(name).dy));
    expect(tester.getTopLeft(logo).dx, greaterThan(tester.getTopLeft(name).dx));
  });

  testWidgets('the show-name switch hides the name in the preview',
      (tester) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final changes = await _pumpEditor(tester, logo: _logo);
    expect(find.byKey(DocumentLetterheadPreview.nameKey), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('document-logo-show-name')));
    await tester.pumpAndSettle();
    expect(changes.last.showName, isFalse);
    expect(find.byKey(DocumentLetterheadPreview.nameKey), findsNothing);
    // The rest of the header is still there.
    expect(find.text('Mail payments to: PO Box 42'), findsOneWidget);

    await tester.tap(find.text('Reset logo layout'));
    await tester.pumpAndSettle();
    expect(changes.last, DocumentLogoLayout.defaults);
    expect(find.byKey(DocumentLetterheadPreview.nameKey), findsOneWidget);
  });

  testWidgets('without a logo there is nothing to lay out, only the preview',
      (tester) async {
    await _pumpEditor(tester,
        initial: const DocumentLogoLayout(showName: false));
    expect(find.byKey(const ValueKey('document-logo-size-slider')),
        findsNothing);
    expect(find.byKey(DocumentLetterheadPreview.logoKey), findsNothing);
    // A saved "hide name" cannot leave a logo-less header nameless.
    expect(find.byKey(DocumentLetterheadPreview.nameKey), findsOneWidget);
  });
}
