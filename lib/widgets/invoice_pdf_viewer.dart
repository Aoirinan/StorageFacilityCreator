import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../theme/app_theme.dart';

/// Widget to display invoice PDF
/// For web, shows an iframe. For other platforms, shows a link.
class InvoicePDFViewer extends StatelessWidget {
  final String pdfUrl;

  const InvoicePDFViewer({
    super.key,
    required this.pdfUrl,
  });

  @override
  Widget build(BuildContext context) {
    // For web, use iframe to display PDF inline
    // For other platforms, show a link to open in browser
    
    return Container(
      height: 600,
      decoration: BoxDecoration(
        border: Border.all(color: AppTheme.borderLight),
        borderRadius: BorderRadius.circular(8),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: _buildPDFView(context),
      ),
    );
  }

  Widget _buildPDFView(BuildContext context) {
    // Check if running on web
    try {
      // Use dart:html for web platform
      return _buildWebPDFView();
    } catch (e) {
      // Not on web, show link instead
      return _buildLinkView();
    }
  }

  Widget _buildWebPDFView() {
    // For web, we can use an iframe or embed tag
    // Since Flutter web doesn't have direct iframe support, we'll use a workaround
    // with url_launcher or show a link
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.picture_as_pdf, size: 64, color: AppTheme.primaryBlue),
          const SizedBox(height: 16),
          Text(
            'Invoice PDF',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Click below to view the invoice PDF',
            style: TextStyle(
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () async {
              final uri = Uri.parse(pdfUrl);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open PDF'),
          ),
        ],
      ),
    );
  }

  Widget _buildLinkView() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.picture_as_pdf, size: 64, color: AppTheme.primaryBlue),
          const SizedBox(height: 16),
          Text(
            'Invoice PDF Available',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Click below to open the invoice PDF',
            style: TextStyle(
              color: AppTheme.textSecondary,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: () async {
              final uri = Uri.parse(pdfUrl);
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            icon: const Icon(Icons.open_in_new),
            label: const Text('Open PDF'),
          ),
        ],
      ),
    );
  }
}

