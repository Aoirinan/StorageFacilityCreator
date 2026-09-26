import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'package:sfcapp/models/document_logo_layout.dart';
import 'package:sfcapp/models/facility_model.dart';

/// The facility's letterhead for tenant-facing PDFs (statements, invoices):
/// logo, business name, addresses and phone on the left, the document title
/// on the right. Both sides are width-bounded so a long business name wraps
/// instead of running into the title.
///
/// The logo's size and position, and whether the name prints beside it, come
/// from the facility's [FacilityModel.documentLogo]. The HTML invoice and
/// receipt (lib/utils/print_documents.dart) and the Edit Facility preview
/// (lib/widgets/document_logo_layout_editor.dart) follow the same settings.
class PdfLetterhead {
  /// Fetches the facility logo for embedding. Returns null when there is no
  /// logo or it cannot be loaded, so a broken logo never blocks a statement.
  static Future<pw.ImageProvider?> loadLogo(FacilityModel facility) async {
    final url = facility.logoUrl?.trim();
    if (url == null || url.isEmpty) return null;
    try {
      final response =
          await http.get(Uri.parse(url)).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200 || response.bodyBytes.isEmpty) {
        return null;
      }
      return pw.MemoryImage(response.bodyBytes);
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ [PdfLetterhead] Logo not loaded: $e');
      }
      return null;
    }
  }

  /// The address payments should be mailed to: the mailing address when the
  /// facility has one, otherwise its physical address.
  static String? remitAddress(FacilityModel facility) {
    final mailing = facility.mailingAddress?.trim();
    if (mailing != null && mailing.isNotEmpty) return mailing;
    final physical = facility.address?.trim();
    if (physical != null && physical.isNotEmpty) return physical;
    return null;
  }

  static pw.Widget build({
    required FacilityModel facility,
    required String title,
    required List<String> titleDetails,
    pw.ImageProvider? logo,
  }) {
    final layout = facility.documentLogo;
    final physical = facility.address?.trim() ?? '';
    final mailing = facility.mailingAddress?.trim() ?? '';
    final showMailing = mailing.isNotEmpty && mailing != physical;
    final showName = layout.nameVisible(logoShown: logo != null);
    const detailStyle = pw.TextStyle(fontSize: 9, color: PdfColors.grey800);

    // Height is what the owner picked; width follows the logo's proportions
    // up to the layout's max width (pw.Image fits itself inside the box).
    final logoWidget = logo == null
        ? null
        : pw.ConstrainedBox(
            constraints: pw.BoxConstraints(
              maxWidth: layout.maxWidth,
              maxHeight: layout.height,
            ),
            child: pw.Image(logo, fit: pw.BoxFit.contain),
          );

    final detailLines = <pw.Widget>[
      if (showName) ...[
        pw.Text(
          facility.name,
          style: pw.TextStyle(
            fontSize: 16,
            fontWeight: pw.FontWeight.bold,
          ),
        ),
        pw.SizedBox(height: 4),
      ],
      if (physical.isNotEmpty) pw.Text(physical, style: detailStyle),
      if (showMailing) ...[
        pw.SizedBox(height: 2),
        pw.Text('Mail payments to: $mailing', style: detailStyle),
      ],
      if (facility.phone != null && facility.phone!.trim().isNotEmpty)
        pw.Text(facility.phone!.trim(), style: detailStyle),
      if (facility.email != null && facility.email!.trim().isNotEmpty)
        pw.Text(facility.email!.trim(), style: detailStyle),
    ];

    final titleBlock = pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.end,
      children: [
        pw.Text(
          title.toUpperCase(),
          style: pw.TextStyle(
            fontSize: 12,
            fontWeight: pw.FontWeight.bold,
            letterSpacing: 0.5,
            color: PdfColors.grey700,
          ),
        ),
        pw.SizedBox(height: 4),
        ...titleDetails.map(
          (line) => pw.Text(line, style: const pw.TextStyle(fontSize: 10)),
        ),
      ],
    );

    pw.Widget detailsRow({pw.Widget? leading, pw.Widget? above}) => pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            if (leading != null) ...[leading, pw.SizedBox(width: 12)],
            pw.Expanded(
              child: pw.Column(
                crossAxisAlignment: pw.CrossAxisAlignment.start,
                children: [
                  if (above != null) ...[above, pw.SizedBox(height: 8)],
                  ...detailLines,
                ],
              ),
            ),
            pw.SizedBox(width: 16),
            titleBlock,
          ],
        );

    final pw.Widget body = switch (layout.position) {
      DocumentLogoPosition.left => detailsRow(leading: logoWidget),
      DocumentLogoPosition.above => detailsRow(above: logoWidget),
      DocumentLogoPosition.center => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          children: [
            if (logoWidget != null) ...[
              pw.Center(child: logoWidget),
              pw.SizedBox(height: 10),
            ],
            detailsRow(),
          ],
        ),
    };

    return pw.Container(
      padding: const pw.EdgeInsets.only(bottom: 12),
      decoration: const pw.BoxDecoration(
        border: pw.Border(
          bottom: pw.BorderSide(color: PdfColors.grey400, width: 1),
        ),
      ),
      child: body,
    );
  }
}
