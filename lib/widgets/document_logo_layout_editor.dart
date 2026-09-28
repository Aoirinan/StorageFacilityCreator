import 'package:flutter/material.dart';

import 'package:sfcapp/models/document_logo_layout.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// The logo controls under Edit Facility → Statements & Invoices: logo size,
/// position and whether the business name prints beside it, with a live
/// preview of the document header underneath.
///
/// The value is held by the caller and saved with the rest of the facility
/// form ([FacilityModel.documentLogo]).
class DocumentLogoLayoutEditor extends StatelessWidget {
  const DocumentLogoLayoutEditor({
    super.key,
    required this.value,
    required this.onChanged,
    required this.logo,
    required this.facilityName,
    this.address,
    this.mailingAddress,
    this.phone,
    this.email,
  });

  final DocumentLogoLayout value;
  final ValueChanged<DocumentLogoLayout> onChanged;

  /// The uploaded logo. Null hides the logo controls (there is nothing to lay
  /// out) but still previews the header.
  final ImageProvider? logo;
  final String facilityName;
  final String? address;
  final String? mailingAddress;
  final String? phone;
  final String? email;

  static String _inches(double points) =>
      '${(points / 72).toStringAsFixed(2)} in tall';

  @override
  Widget build(BuildContext context) {
    final hasLogo = logo != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasLogo) ...[
          Row(
            children: [
              const Text('Logo size',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              const Spacer(),
              Text(
                _inches(value.height),
                key: const ValueKey('document-logo-size-label'),
                style: const TextStyle(
                    fontSize: 12, color: AppTheme.textSecondary),
              ),
            ],
          ),
          Slider(
            key: const ValueKey('document-logo-size-slider'),
            min: DocumentLogoLayout.minHeight,
            max: DocumentLogoLayout.maxHeight,
            divisions: ((DocumentLogoLayout.maxHeight -
                        DocumentLogoLayout.minHeight) /
                    4)
                .round(),
            value: value.height,
            label: _inches(value.height),
            onChanged: (h) => onChanged(value.copyWith(height: h)),
          ),
          const SizedBox(height: 4),
          const Text('Logo position',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<DocumentLogoPosition>(
              key: const ValueKey('document-logo-position'),
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(
                  value: DocumentLogoPosition.left,
                  icon: Icon(Icons.view_sidebar_outlined),
                  label: Text('Left of details'),
                ),
                ButtonSegment(
                  value: DocumentLogoPosition.above,
                  icon: Icon(Icons.vertical_align_top),
                  label: Text('Above details'),
                ),
                ButtonSegment(
                  value: DocumentLogoPosition.center,
                  icon: Icon(Icons.format_align_center),
                  label: Text('Centered at top'),
                ),
              ],
              selected: {value.position},
              onSelectionChanged: (s) =>
                  onChanged(value.copyWith(position: s.first)),
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile(
            key: const ValueKey('document-logo-show-name'),
            contentPadding: EdgeInsets.zero,
            title: const Text('Show business name next to logo'),
            subtitle: const Text(
                'Turn off if your logo already spells out your business name.'),
            value: value.showName,
            onChanged: (v) => onChanged(value.copyWith(showName: v)),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: value == DocumentLogoLayout.defaults
                  ? null
                  : () => onChanged(DocumentLogoLayout.defaults),
              icon: const Icon(Icons.restart_alt, size: 18),
              label: const Text('Reset logo layout'),
            ),
          ),
          const SizedBox(height: 4),
        ],
        const Text('Preview', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        const Text(
          'How the top of your statements, invoices and receipts will look. '
          'Wide logos stop growing at the width limit; Above or Centered gives '
          'them more room.',
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 8),
        DocumentLetterheadPreview(
          layout: value,
          logo: logo,
          facilityName: facilityName,
          address: address,
          mailingAddress: mailingAddress,
          phone: phone,
          email: email,
        ),
      ],
    );
  }
}

/// A scaled picture of the letterhead at the top of a printed statement,
/// laid out the way lib/services/pdf_letterhead.dart lays out the PDF: one
/// logical pixel here is one PDF point, on a page 468pt wide between the
/// margins, scaled down to fit the screen.
class DocumentLetterheadPreview extends StatelessWidget {
  const DocumentLetterheadPreview({
    super.key,
    required this.layout,
    required this.facilityName,
    this.logo,
    this.address,
    this.mailingAddress,
    this.phone,
    this.email,
  });

  final DocumentLogoLayout layout;
  final ImageProvider? logo;
  final String facilityName;
  final String? address;
  final String? mailingAddress;
  final String? phone;
  final String? email;

  /// The PDF page's content width (US Letter minus 1in margins), in points.
  static const double contentWidth = 468;
  static const double _pagePadding = 24;

  static const Key logoKey = ValueKey('letterhead-preview-logo');
  static const Key nameKey = ValueKey('letterhead-preview-name');

  static String? _clean(String? s) {
    final t = s?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  @override
  Widget build(BuildContext context) {
    // The page is paper whatever the app theme, so the colours are fixed.
    const ink = Color(0xFF111827);
    const detailStyle = TextStyle(fontSize: 9, color: Color(0xFF424242));
    final physical = _clean(address);
    final mailing = _clean(mailingAddress);
    final showMailing = mailing != null && mailing != physical;
    final showName = layout.nameVisible(logoShown: logo != null);
    final name = _clean(facilityName) ?? 'Your business name';

    Widget? logoWidget;
    if (logo != null) {
      final placeholderWidth =
          (layout.height * 2).clamp(0, layout.maxWidth).toDouble();
      logoWidget = ConstrainedBox(
        key: logoKey,
        constraints: BoxConstraints(
          maxWidth: layout.maxWidth,
          maxHeight: layout.height,
        ),
        child: Image(
          image: logo!,
          height: layout.height,
          fit: BoxFit.contain,
          alignment: layout.position == DocumentLogoPosition.center
              ? Alignment.center
              : Alignment.centerLeft,
          errorBuilder: (_, __, ___) => Container(
            width: placeholderWidth,
            height: layout.height,
            color: const Color(0xFFE5E7EB),
            alignment: Alignment.center,
            child: const Icon(Icons.broken_image_outlined,
                color: Color(0xFF9CA3AF)),
          ),
        ),
      );
    }

    final details = <Widget>[
      if (showName) ...[
        Text(
          name,
          key: nameKey,
          style: const TextStyle(
              fontSize: 16, fontWeight: FontWeight.bold, color: ink),
        ),
        const SizedBox(height: 4),
      ],
      if (physical != null) Text(physical, style: detailStyle),
      if (showMailing) ...[
        const SizedBox(height: 2),
        Text('Mail payments to: $mailing', style: detailStyle),
      ],
      if (_clean(phone) != null) Text(_clean(phone)!, style: detailStyle),
      if (_clean(email) != null) Text(_clean(email)!, style: detailStyle),
    ];

    final now = DateTime.now();
    final today = '${now.month.toString().padLeft(2, '0')}/'
        '${now.day.toString().padLeft(2, '0')}/${now.year}';
    final title = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        const Text(
          'ACCOUNT STATEMENT',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
            color: Color(0xFF616161),
          ),
        ),
        const SizedBox(height: 4),
        Text('Date: $today', style: const TextStyle(fontSize: 10, color: ink)),
      ],
    );

    Widget detailsRow({Widget? leading, Widget? above}) => Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (leading != null) ...[leading, const SizedBox(width: 12)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (above != null) ...[above, const SizedBox(height: 8)],
                  ...details,
                ],
              ),
            ),
            const SizedBox(width: 16),
            title,
          ],
        );

    final Widget header = switch (layout.position) {
      DocumentLogoPosition.left => detailsRow(leading: logoWidget),
      DocumentLogoPosition.above => detailsRow(above: logoWidget),
      DocumentLogoPosition.center => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (logoWidget != null) ...[
              Center(child: logoWidget),
              const SizedBox(height: 10),
            ],
            detailsRow(),
          ],
        ),
    };

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderLight),
      ),
      padding: const EdgeInsets.all(12),
      alignment: Alignment.topLeft,
      child: FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.topLeft,
        child: Container(
          width: contentWidth + _pagePadding * 2,
          padding: const EdgeInsets.fromLTRB(
              _pagePadding, _pagePadding, _pagePadding, 16),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 4,
                offset: const Offset(0, 1),
              ),
            ],
          ),
          child: DefaultTextStyle(
            style: const TextStyle(color: ink),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  padding: const EdgeInsets.only(bottom: 12),
                  decoration: const BoxDecoration(
                    border: Border(
                      bottom: BorderSide(color: Color(0xFFBDBDBD)),
                    ),
                  ),
                  child: header,
                ),
                const SizedBox(height: 12),
                // A hint of the page body, so the header reads in context.
                for (final w in const [0.55, 0.8, 0.7])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: FractionallySizedBox(
                      alignment: Alignment.centerLeft,
                      widthFactor: w,
                      child: Container(height: 6, color: const Color(0xFFEEEEEE)),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
