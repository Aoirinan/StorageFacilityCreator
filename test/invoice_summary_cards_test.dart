import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sfcapp/utils/invoice_summary.dart';
import 'package:sfcapp/widgets/invoice_summary_cards.dart';

const _cardKeys = [
  ValueKey('invoice-summary-invoices'),
  ValueKey('invoice-summary-paid'),
  ValueKey('invoice-summary-overdue'),
  ValueKey('invoice-summary-unpaid'),
];

/// Bigger than any facility's figures, so if these fit, real ones do.
const _large = InvoiceSummary(
  count: 1234,
  paid: 567,
  overdue: 89,
  unpaidAmount: 123456.78,
  unpaidDrafts: 12,
);

/// Two drafts and nothing else: what the bug was reported on.
const _twoDrafts = InvoiceSummary(
  count: 2,
  paid: 0,
  overdue: 0,
  unpaidAmount: 1250,
  unpaidDrafts: 2,
);

Future<void> _pump(WidgetTester tester, double width, InvoiceSummary s) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Column(children: [InvoiceSummaryCards(summary: s)]),
    ),
  ));
}

/// Every piece of text in the strip is shown whole: nothing ellipsised,
/// nothing past its line limit, nothing wider than its card.
void _expectNothingCut(WidgetTester tester) {
  // A RenderFlex overflow is reported as an exception.
  expect(tester.takeException(), isNull);
  for (final key in _cardKeys) {
    final card = find.byKey(key);
    final cardRect = tester.getRect(card);
    final paragraphs = tester
        .renderObjectList<RenderParagraph>(
            find.descendant(of: card, matching: find.byType(RichText)))
        .toList();
    expect(paragraphs, isNotEmpty, reason: '$key');
    for (final p in paragraphs) {
      final text = p.text.toPlainText();
      expect(p.overflow, isNot(TextOverflow.ellipsis), reason: text);
      expect(p.didExceedMaxLines, isFalse, reason: text);
      if (p.maxLines == 1 || !p.softWrap) {
        // One line, laid out at its full width (a FittedBox scales an
        // amount down, never clips it).
        expect(p.size.width,
            greaterThanOrEqualTo(p.getMaxIntrinsicWidth(double.infinity) - 0.5),
            reason: text);
      } else {
        // May wrap between words, but no word is broken or cut.
        expect(p.size.width,
            greaterThanOrEqualTo(p.getMinIntrinsicWidth(double.infinity) - 0.5),
            reason: text);
      }
      // Where it lands on screen, after any scaling.
      final rect = MatrixUtils.transformRect(
          p.getTransformTo(null), Offset.zero & p.size);
      expect(rect.left, greaterThanOrEqualTo(cardRect.left), reason: text);
      expect(rect.right, lessThanOrEqualTo(cardRect.right + 0.5), reason: text);
    }
  }
}

void main() {
  for (final width in [360.0, 600.0, 768.0, 1024.0, 1440.0]) {
    testWidgets('at ${width.toInt()}px every label and figure shows whole',
        (tester) async {
      await _pump(tester, width, _large);
      for (final label in ['Invoices', 'Paid', 'Overdue', 'Unpaid']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text(r'$123,456.78'), findsOneWidget);
      expect(find.text('incl. 12 drafts'), findsOneWidget);
      _expectNothingCut(tester);
    });
  }

  testWidgets('at 768px the four cards sit in one row, labels on one line',
      (tester) async {
    await _pump(tester, 768, _twoDrafts);
    _expectNothingCut(tester);

    final tops = {
      for (final key in _cardKeys) tester.getTopLeft(find.byKey(key)).dy
    };
    expect(tops, hasLength(1));

    final oneLine = tester.getSize(find.text('Paid')).height;
    for (final label in ['Invoices', 'Overdue', 'Unpaid']) {
      expect(tester.getSize(find.text(label)).height, oneLine, reason: label);
    }

    expect(find.text('2'), findsOneWidget);
    expect(find.text(r'$1,250.00'), findsOneWidget);
    expect(find.text('incl. 2 drafts'), findsOneWidget);
  });

  testWidgets('on a phone the cards go two by two', (tester) async {
    await _pump(tester, 360, _twoDrafts);
    final top = [
      for (final key in _cardKeys) tester.getTopLeft(find.byKey(key)).dy
    ];
    expect(top[0], top[1]);
    expect(top[2], top[3]);
    expect(top[2], greaterThan(top[0]));
  });

  testWidgets('no drafts in the sum, no drafts caption', (tester) async {
    await _pump(
      tester,
      768,
      const InvoiceSummary(
        count: 3,
        paid: 1,
        overdue: 1,
        unpaidAmount: 80.5,
        unpaidDrafts: 0,
      ),
    );
    expect(find.text(r'$80.50'), findsOneWidget);
    expect(find.textContaining('draft'), findsNothing);
  });

  testWidgets('one draft reads singular', (tester) async {
    await _pump(
      tester,
      768,
      const InvoiceSummary(
        count: 1,
        paid: 0,
        overdue: 0,
        unpaidAmount: 25,
        unpaidDrafts: 1,
      ),
    );
    expect(find.text('incl. 1 draft'), findsOneWidget);
  });
}
