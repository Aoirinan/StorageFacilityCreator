import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signature/signature.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'dart:convert';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:http/http.dart' as http;
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:pdfx/pdfx.dart' as pdfx;
import '../models/contract_model.dart';
import '../models/contract_template_model.dart';
import '../router/app_route.dart';
import '../services/contract_service.dart';
import '../services/web_externals_loader.dart';
import '../services/tenant_service.dart';
import '../models/tenant_model.dart';
import '../theme/app_theme.dart';

class ContractSigningScreen extends ConsumerStatefulWidget {
  final String signingToken;
  final ContractModel? contract; // Optional if we want to pass it directly

  const ContractSigningScreen({
    super.key,
    required this.signingToken,
    this.contract,
  });

  @override
  ConsumerState<ContractSigningScreen> createState() => _ContractSigningScreenState();
}

class _ContractSigningScreenState extends ConsumerState<ContractSigningScreen> {
  // Primary signature controller (used for free-placement mode and first configured sig)
  final SignatureController _signatureController = SignatureController(
    penStrokeWidth: 2,
    penColor: AppTheme.textPrimary,
  );

  // Additional signature controllers keyed by placeholder id (for multiple configured sigs)
  final Map<String, SignatureController> _extraSignatureControllers = {};

  // Height of each signature pad (keyed by placeholder id, or 'primary' for free-placement)
  final Map<String, double> _signaturePadHeights = {};
  static const double _minPadHeight = 80.0;
  static const double _maxPadHeight = 400.0;
  static const double _defaultPadHeight = 200.0;

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  bool _isLoading = false;
  bool _isSigning = false;
  String? _errorMessage;
  ContractModel? _contract;
  TenantModel? _tenant;
  int _signaturePage = -1;
  double _signatureX = 50;
  double _signatureY = 100;
  double _signatureW = 150;
  double _signatureH = 60;
  int _namePage = -1;
  double _nameX = 50;
  double _nameY = 32;
  bool _nameBelowSignature = true;
  int _datePage = -1;
  double _dateX = 50;
  double _dateY = 20;
  bool _dateBelowName = true;
  double _nameFontSize = 11;
  double _dateFontSize = 10;
  bool _useCustomDate = false;
  DateTime _customDate = DateTime.now();

  /// Which field the next tap will place.
  /// 'signature', 'name', 'date', 'misc-new', or 'misc-0', 'misc-1', etc.
  String _activePlacingField = 'signature';
  bool _signaturePlaced = false;
  bool _namePlaced = false;
  bool _datePlaced = false;

  /// Misc fields: user can add multiple custom text placements
  final List<_MiscPlacement> _miscPlacements = [];
  final _miscTextController = TextEditingController();

  /// Placeholders from contract customFields (configured by facility owner)
  List<SignaturePlaceholder> _configuredPlaceholders = [];
  /// Extra controllers for configured text fields (storage unit, initials, etc.)
  final Map<String, TextEditingController> _extraControllers = {};

  @override
  void initState() {
    super.initState();
    _loadContract();
  }

  @override
  void dispose() {
    _signatureController.dispose();
    for (final c in _extraSignatureControllers.values) {
      c.dispose();
    }
    _nameController.dispose();
    _emailController.dispose();
    _miscTextController.dispose();
    for (final c in _extraControllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _loadContract() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final contract = widget.contract ?? 
          await ContractService.getContractBySigningToken(widget.signingToken);
      
      if (contract == null) {
        setState(() {
          _errorMessage = 'Contract not found or signing link has expired.';
          _isLoading = false;
        });
        return;
      }

      _contract = contract;

      // Parse configured signature placeholders from customFields (tenant signer only)
      final custom = contract.customFields;
      if (custom != null) {
        final list = custom['signaturePlaceholders'] as List<dynamic>?;
        String? tenantSignerId;
        final signers = custom['templateSigners'] as List<dynamic>?;
        if (signers != null) {
          for (final s in signers) {
            final m = Map<String, dynamic>.from(s as Map);
            if (m['isTenantSigner'] == true) {
              tenantSignerId = m['id'] as String?;
              break;
            }
          }
        }
        tenantSignerId ??= 'tenantPrimary';
        if (list != null && list.isNotEmpty) {
          final all = list.map((e) => SignaturePlaceholder.fromMap(Map<String, dynamic>.from(e as Map))).toList();
          _configuredPlaceholders = all.where((p) => p.signerId == tenantSignerId).toList();
          bool firstSig = true;
          for (final p in _configuredPlaceholders) {
            if (p.fieldType == SignatureFieldType.signature || p.fieldType == SignatureFieldType.initials) {
              if (firstSig) {
                firstSig = false;
                // Primary controller handles the first signature
              } else {
                // Create a separate controller for each additional signature/initials field
                if (!_extraSignatureControllers.containsKey(p.id)) {
                  _extraSignatureControllers[p.id] = SignatureController(
                    penStrokeWidth: p.fieldType == SignatureFieldType.initials ? 2 : 2,
                    penColor: AppTheme.textPrimary,
                  );
                }
              }
            } else if ((p.fieldType == SignatureFieldType.storageUnit || p.fieldType == SignatureFieldType.text) &&
                !_extraControllers.containsKey(p.id)) {
              _extraControllers[p.id] = TextEditingController();
            }
          }
        }
      }

      // Try to load tenant details
      try {
        final tenant = await TenantService.getTenantById(contract.facilityId, contract.tenantId);
        if (tenant != null) {
          _tenant = tenant;
          _nameController.text = tenant.name;
          _emailController.text = tenant.email ?? '';
        }
      } catch (e) {
        // Tenant loading is optional
        if (kDebugMode) {
          print('⚠️ Could not load tenant details: $e');
        }
      }

      setState(() {
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = 'Error loading contract: $e';
        _isLoading = false;
      });
    }
  }

  Widget _fieldChip(String field, String label, IconData icon, Color color, bool placed) {
    final isActive = _activePlacingField == field;
    return ChoiceChip(
      avatar: Icon(icon, size: 18, color: isActive ? Colors.white : color),
      label: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label),
          if (placed) ...[
            const SizedBox(width: 4),
            Icon(Icons.check_circle, size: 14, color: isActive ? Colors.white : AppTheme.success),
          ],
        ],
      ),
      selected: isActive,
      selectedColor: color,
      labelStyle: TextStyle(color: isActive ? Colors.white : null, fontWeight: isActive ? FontWeight.bold : null),
      onSelected: (_) => setState(() => _activePlacingField = field),
    );
  }

  /// Builds all signature pad widgets. When there are multiple configured
  /// signature/initials placeholders, each gets its own pad.
  List<Widget> _buildSignaturePads() {
    final sigPlaceholders = _configuredPlaceholders
        .where((p) => p.fieldType == SignatureFieldType.signature || p.fieldType == SignatureFieldType.initials)
        .toList();

    if (sigPlaceholders.isEmpty) {
      // Free-placement mode: single primary pad
      return [_buildSignaturePad(
        padKey: 'primary',
        controller: _signatureController,
        label: 'Signature *',
        hint: 'Please sign in the box below using your mouse or touch screen',
      )];
    }

    // Configured mode: one pad per signature/initials placeholder
    final widgets = <Widget>[];
    bool firstSig = true;
    for (final p in sigPlaceholders) {
      final label = (p.label ?? p.fieldType.defaultPrompt) + (p.required ? ' *' : '');
      final controller = firstSig ? _signatureController : _extraSignatureControllers[p.id]!;
      firstSig = false;
      widgets.add(_buildSignaturePad(
        padKey: p.id,
        controller: controller,
        label: label,
        hint: p.fieldType == SignatureFieldType.initials
            ? 'Please write your initials in the box below'
            : 'Please sign in the box below using your mouse or touch screen',
      ));
      widgets.add(const SizedBox(height: 24));
    }
    return widgets;
  }

  Widget _buildSignaturePad({
    required String padKey,
    required SignatureController controller,
    required String label,
    required String hint,
  }) {
    final height = _signaturePadHeights[padKey] ?? _defaultPadHeight;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          hint,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 8),
        // Height resize slider
        Row(
          children: [
            Icon(Icons.height, size: 16, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Text('Size', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary)),
            Expanded(
              child: Slider(
                value: height,
                min: _minPadHeight,
                max: _maxPadHeight,
                divisions: 16,
                label: '${height.round()}px',
                onChanged: (v) => setState(() => _signaturePadHeights[padKey] = v),
              ),
            ),
            Text(
              '${height.round()}px',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary, fontSize: 11),
            ),
          ],
        ),
        Container(
          decoration: BoxDecoration(
            color: AppTheme.surface,
            border: Border.all(color: AppTheme.borderLight),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Signature(
            controller: controller,
            height: height,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton.icon(
              onPressed: controller.isEmpty ? null : () => setState(() => controller.clear()),
              icon: const Icon(Icons.clear, size: 16),
              label: const Text('Clear'),
            ),
          ],
        ),
      ],
    );
  }

  List<_PdfMarker> _buildMarkers() {
    final markers = <_PdfMarker>[];
    if (_signaturePlaced) {
      markers.add(_PdfMarker(
        label: 'Signature',
        color: AppTheme.primaryBlue,
        pageIndex: _signaturePage,
        x: _signatureX,
        y: _signatureY,
        w: _signatureW,
        h: _signatureH,
      ));
    }
    if (_namePlaced) {
      markers.add(_PdfMarker(
        label: 'Name',
        color: Colors.teal,
        pageIndex: _namePage,
        x: _nameX,
        y: _nameY,
        w: 120,
        h: 20,
      ));
    }
    if (_datePlaced) {
      markers.add(_PdfMarker(
        label: 'Date',
        color: Colors.orange,
        pageIndex: _datePage,
        x: _dateX,
        y: _dateY,
        w: 100,
        h: 18,
      ));
    }
    for (int i = 0; i < _miscPlacements.length; i++) {
      final m = _miscPlacements[i];
      markers.add(_PdfMarker(
        label: m.text.length > 12 ? '${m.text.substring(0, 12)}...' : m.text,
        color: Colors.deepPurple,
        pageIndex: m.pageIndex,
        x: m.x,
        y: m.y,
        w: 110,
        h: 18,
      ));
    }
    return markers;
  }

  Future<void> _signContract() async {
    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (_signatureController.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please provide your signature'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    // Check all extra signature pads are filled
    for (final entry in _extraSignatureControllers.entries) {
      if (entry.value.isEmpty) {
        final placeholder = _configuredPlaceholders.firstWhere((p) => p.id == entry.key, orElse: () => _configuredPlaceholders.first);
        final label = placeholder.label ?? placeholder.fieldType.defaultPrompt;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Please complete: $label'),
            backgroundColor: AppTheme.warning,
          ),
        );
        return;
      }
    }

    if (_contract == null) {
      return;
    }

    setState(() {
      _isSigning = true;
      _errorMessage = null;
    });

    try {
      // Export signature as image
      final signatureBytes = await _signatureController.toPngBytes();
      if (signatureBytes == null) {
        throw Exception('Failed to export signature');
      }

      Uint8List signedPdfBytes;
      if (_contract?.fileUrl != null && _contract!.fileUrl!.isNotEmpty) {
        // Merge signature into the original uploaded PDF
        signedPdfBytes = await _mergeSignatureIntoOriginalPdf(signatureBytes);
      } else {
        // No original PDF: use legacy blank page + signature
        signedPdfBytes = await _generateSignedPdf(signatureBytes);
      }

      // Upload signed PDF via Cloud Function (bypasses Storage CORS)
      final signedFileUrl = await ContractService.uploadSignedContract(
        facilityId: _contract!.facilityId,
        contractId: _contract!.id,
        pdfData: signedPdfBytes,
        signingToken: widget.signingToken,
      );

      // Sign the contract
      await ContractService.signContract(
        facilityId: _contract!.facilityId,
        contractId: _contract!.id,
        signedBy: _nameController.text.trim(),
        signedByEmail: _emailController.text.trim().isNotEmpty ? _emailController.text.trim() : null,
        signedFileUrl: signedFileUrl,
        signingToken: widget.signingToken,
      );

      if (mounted) {
        setState(() => _isSigning = false); // Stop spinner (popUntil may not work when arrived from email)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Contract signed successfully!'),
            backgroundColor: AppTheme.success,
          ),
        );
        // Navigate away - context.go works when arrived from email (popUntil often doesn't)
        context.go(AppRoute.landing);
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error signing contract: $e';
        _isSigning = false;
      });
    }
  }

  Future<List<Map<String, dynamic>>> _buildPlacementsFromConfigured(
    String signatureBase64,
    String signerName,
    String signerDate,
  ) async {
    // Pre-export extra signature images (for multiple signature fields)
    final Map<String, String> extraSigBase64 = {};
    for (final entry in _extraSignatureControllers.entries) {
      final bytes = await entry.value.toPngBytes();
      if (bytes != null) {
        extraSigBase64[entry.key] = base64Encode(bytes);
      }
    }

    await ensurePdfJsForWeb();
    final fetchUrl = ContractService.getPdfFetchUrl(_contract!.fileUrl);
    final resp = await http.get(Uri.parse(fetchUrl));
    if (resp.statusCode != 200) throw Exception('Failed to load PDF');
    final doc = await pdfx.PdfDocument.openData(resp.bodyBytes);
    final placements = <Map<String, dynamic>>[];
    bool firstSig = true;
    for (final p in _configuredPlaceholders) {
      final pageIndex = (p.page - 1).clamp(0, doc.pagesCount - 1);
      final page = await doc.getPage(p.page);
      final pageWidth = page.width.toDouble();
      final pageHeight = page.height.toDouble();
      page.close();
      final xPdf = p.x * pageWidth;
      final yPdf = p.y * pageHeight;
      final wPdf = (p.width * pageWidth).clamp(80.0, 250.0);
      final hPdf = (p.height * pageHeight).clamp(30.0, 120.0);
      String? text;
      switch (p.fieldType) {
        case SignatureFieldType.signature:
          final imgBase64 = firstSig ? signatureBase64 : (extraSigBase64[p.id] ?? signatureBase64);
          firstSig = false;
          placements.add({'type': 'image', 'pageIndex': pageIndex, 'x': xPdf, 'y': yPdf, 'width': wPdf, 'height': hPdf, 'imageBase64': imgBase64});
          break;
        case SignatureFieldType.initials:
          final initialsBase64 = extraSigBase64[p.id];
          if (initialsBase64 != null) {
            placements.add({'type': 'image', 'pageIndex': pageIndex, 'x': xPdf, 'y': yPdf, 'width': wPdf, 'height': hPdf, 'imageBase64': initialsBase64});
          } else {
            text = _extraControllers[p.id]?.text.trim() ?? '';
          }
          break;
        case SignatureFieldType.name:
          text = signerName;
          break;
        case SignatureFieldType.date:
          text = signerDate;
          break;
        case SignatureFieldType.storageUnit:
        case SignatureFieldType.text:
          text = _extraControllers[p.id]?.text.trim() ?? '';
          break;
      }
      if (text != null && text.isNotEmpty) {
        placements.add({'type': 'text', 'pageIndex': pageIndex, 'x': xPdf, 'y': yPdf, 'text': text, 'fontSize': 11});
      }
    }
    doc.close();
    return placements;
  }

  Future<Uint8List> _mergeSignatureIntoOriginalPdf(Uint8List signatureImage) async {
    final signatureBase64 = base64Encode(signatureImage);
    final signerName = _nameController.text.trim();
    final signerDate = _useCustomDate
        ? '${_customDate.year}-${_customDate.month.toString().padLeft(2, '0')}-${_customDate.day.toString().padLeft(2, '0')}'
        : DateTime.now().toString().split(' ')[0];

    List<Map<String, dynamic>> placements;
    if (_configuredPlaceholders.isNotEmpty && _contract?.fileUrl != null) {
      placements = await _buildPlacementsFromConfigured(signatureBase64, signerName, signerDate);
    } else {
      final sigPage = _signaturePage < 0 ? 999 : _signaturePage;
      final namePage = _namePage < 0 ? sigPage : _namePage;
      final datePage = _datePage < 0 ? sigPage : _datePage;
      final nameY = _nameBelowSignature ? _signatureY - _signatureH - 8 : _nameY;
      final nameX = _nameBelowSignature ? _signatureX : _nameX;
      final dateY = _dateBelowName ? nameY - 14 : _dateY;
      final dateX = _dateBelowName ? nameX : _dateX;
      placements = [
        {'type': 'image', 'pageIndex': sigPage, 'x': _signatureX, 'y': _signatureY, 'width': _signatureW, 'height': _signatureH, 'imageBase64': signatureBase64},
      ];
      if (signerName.isNotEmpty) {
        placements.add({'type': 'text', 'pageIndex': namePage, 'x': nameX, 'y': nameY, 'text': signerName, 'fontSize': _nameFontSize});
      }
      placements.add({'type': 'text', 'pageIndex': datePage, 'x': dateX, 'y': dateY, 'text': signerDate, 'fontSize': _dateFontSize});
      for (final m in _miscPlacements) {
        placements.add({'type': 'text', 'pageIndex': m.pageIndex, 'x': m.x, 'y': m.y, 'text': m.text, 'fontSize': 11});
      }
    }

    final fetchUrl = ContractService.getPdfFetchUrl(_contract!.fileUrl!);
    final pdfResponse = await http.get(Uri.parse(fetchUrl));
    if (pdfResponse.statusCode != 200) {
      throw Exception('Failed to download contract PDF for merge');
    }
    final pdfBase64 = base64Encode(pdfResponse.bodyBytes);

    final callable = FirebaseFunctions.instance.httpsCallable('mergeSignatureIntoPdf');
    final result = await callable.call({
      'pdfBase64': pdfBase64,
      'facilityId': _contract!.facilityId,
      'contractId': _contract!.id,
      'signaturePngBase64': signatureBase64,
      'signerName': signerName,
      'signerDate': signerDate,
      'signingToken': widget.signingToken,
      'placements': placements,
    });
    final data = result.data as Map<String, dynamic>;
    final mergedBase64 = data['pdfBase64'] as String?;
    if (mergedBase64 == null || mergedBase64.isEmpty) {
      throw Exception('Merge failed');
    }
    return base64Decode(mergedBase64);
  }

  Future<Uint8List> _generateSignedPdf(Uint8List signatureImage) async {
    final pdf = pw.Document();
    
    // Try to download and merge original PDF if it exists
    if (_contract?.fileUrl != null && _contract!.fileUrl!.isNotEmpty) {
      try {
        if (kDebugMode) {
          print('📥 Downloading original PDF from: ${_contract!.fileUrl}');
        }
        
        // Download original PDF
        final fetchUrl = ContractService.getPdfFetchUrl(_contract!.fileUrl);
        final response = await http.get(Uri.parse(fetchUrl));
        if (response.statusCode == 200) {
          final originalPdfBytes = response.bodyBytes;
          
          if (kDebugMode) {
            print('✅ Original PDF downloaded (${originalPdfBytes.length} bytes)');
            print('🔄 Attempting to merge with signature page...');
          }
          
          // Store original PDF for reference
          // Note: The pdf package (v3.10.4) has limitations for merging existing PDFs
          // We'll create a signed document with a reference to the original
          if (kDebugMode) {
            print('📄 Original PDF downloaded (${originalPdfBytes.length} bytes)');
            print('📝 Creating signed document with signature page...');
          }
          
          // Add a reference page with contract info
          pdf.addPage(
            pw.Page(
              pageFormat: PdfPageFormat.a4,
              build: (pw.Context context) {
                return pw.Padding(
                  padding: const pw.EdgeInsets.all(40),
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(
                        'Contract Document',
                        style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold),
                      ),
                      pw.SizedBox(height: 20),
                      pw.Text(
                        _contract?.title ?? 'Contract',
                        style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
                      ),
                      pw.SizedBox(height: 16),
                      if (_contract?.description != null && _contract!.description!.isNotEmpty)
                        pw.Text(
                          _contract!.description!,
                          style: const pw.TextStyle(fontSize: 12),
                        ),
                      pw.Spacer(),
                      pw.Divider(),
                      pw.SizedBox(height: 20),
                      pw.Text(
                        'The complete original contract PDF is available at:',
                        style: const pw.TextStyle(fontSize: 10),
                      ),
                      pw.SizedBox(height: 8),
                      pw.Text(
                        _contract!.fileUrl!,
                        style: pw.TextStyle(fontSize: 9, color: PdfColors.blue700),
                        maxLines: 4,
                      ),
                    ],
                  ),
                );
              },
            ),
          );
        } else {
          if (kDebugMode) {
            print('⚠️ Failed to download original PDF: ${response.statusCode}');
          }
        }
      } catch (e) {
        if (kDebugMode) {
          print('⚠️ Error downloading original PDF: $e');
        }
      }
    }

    // Add signature page (always add this as the last page)
    pdf.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a4,
        build: (pw.Context context) {
          return pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(
                _contract?.title ?? 'Contract',
                style: pw.TextStyle(fontSize: 24, fontWeight: pw.FontWeight.bold),
              ),
              pw.SizedBox(height: 16),
              if (_contract?.description != null && (_contract!.description ?? '').isNotEmpty)
                pw.Text(
                  _contract!.description ?? '',
                  style: const pw.TextStyle(fontSize: 12),
                ),
              pw.Spacer(),
              pw.Divider(),
              pw.SizedBox(height: 32),
              pw.Text(
                'Signed by: ${_nameController.text.trim()}',
                style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
              ),
              pw.SizedBox(height: 8),
              pw.Text(
                'Date: ${DateTime.now().toString().split(' ')[0]}',
                style: pw.TextStyle(fontSize: 12),
              ),
              pw.SizedBox(height: 24),
              pw.Text(
                'Signature:',
                style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
              ),
              pw.SizedBox(height: 8),
              pw.Image(
                pw.MemoryImage(signatureImage),
                width: 200,
                height: 80,
              ),
            ],
          );
        },
      ),
    );

    return pdf.save();
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Sign Contract'),
          backgroundColor: AppTheme.primaryBlueDark,
          foregroundColor: AppTheme.textOnDark,
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_errorMessage != null && _contract == null) {
      return Scaffold(
        backgroundColor: AppTheme.backgroundLight,
        appBar: AppBar(
          title: const Text('Sign Contract'),
          backgroundColor: AppTheme.primaryBlueDark,
          foregroundColor: AppTheme.textOnDark,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(32.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withOpacity(0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.error.withOpacity(0.3)),
                    ),
                    child: Icon(Icons.info_outline, size: 48, color: AppTheme.error),
                  ),
                  const SizedBox(height: 24),
                  Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: AppTheme.textPrimary,
                      height: 1.4,
                    ),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: () => Navigator.of(context).pop(),
                      icon: const Icon(Icons.close, size: 18),
                      label: const Text('Close'),
                      style: FilledButton.styleFrom(
                        backgroundColor: AppTheme.primaryBlueDark,
                        foregroundColor: AppTheme.textOnDark,
                        padding: const EdgeInsets.symmetric(vertical: 14),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    if (_contract == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: AppTheme.backgroundLight,
      appBar: AppBar(
        title: const Text('Sign Contract'),
        backgroundColor: AppTheme.primaryBlueDark,
        foregroundColor: AppTheme.textOnDark,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 800),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Contract Info
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.borderLight),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.04),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _contract!.title,
                          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _contract!.description,
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            Icon(Icons.description, size: 16, color: AppTheme.textSecondary),
                            const SizedBox(width: 8),
                            Text(
                              'Type: ${_contract!.type.displayName}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        if (_contract?.fileUrl != null && _contract!.fileUrl!.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          InkWell(
                            onTap: () => launchUrl(Uri.parse(_contract!.fileUrl!)),
                            child: Row(
                              children: [
                                Icon(Icons.picture_as_pdf, size: 16, color: AppTheme.primaryBlue),
                                const SizedBox(width: 8),
                                Text('View contract PDF', style: TextStyle(color: AppTheme.primaryBlue, fontSize: 13)),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_contract?.fileUrl != null && _contract!.fileUrl!.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    if (_configuredPlaceholders.isNotEmpty) ...[
                      Text(
                        'Please complete each field below. Your responses will be placed on the contract where the facility configured them.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                      ),
                      const SizedBox(height: 16),
                    ] else ...[
                      Text(
                        'Tap to place each field',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Select a field below, then tap on the PDF where you want it placed.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _fieldChip('signature', 'Signature', Icons.draw, AppTheme.primaryBlue, _signaturePlaced),
                          _fieldChip('name', 'Name', Icons.person, Colors.teal, _namePlaced),
                          _fieldChip('date', 'Date', Icons.event, Colors.orange, _datePlaced),
                          _fieldChip('misc-new', '+ Misc', Icons.edit_note, Colors.deepPurple, false),
                          ..._miscPlacements.asMap().entries.map((e) {
                            final i = e.key;
                            final m = e.value;
                            final tag = 'misc-$i';
                            final isActive = _activePlacingField == tag;
                            final shortLabel = m.text.length > 10 ? '${m.text.substring(0, 10)}…' : m.text;
                            return InputChip(
                              avatar: Icon(Icons.edit_note, size: 16, color: isActive ? Colors.white : Colors.deepPurple),
                              label: Text(shortLabel),
                              selected: isActive,
                              selectedColor: Colors.deepPurple,
                              labelStyle: TextStyle(
                                color: isActive ? Colors.white : null,
                                fontWeight: isActive ? FontWeight.bold : null,
                                fontSize: 13,
                              ),
                              onSelected: (_) => setState(() => _activePlacingField = tag),
                              onDeleted: () => setState(() {
                                _miscPlacements.removeAt(i);
                                if (_activePlacingField == tag) _activePlacingField = 'misc-new';
                              }),
                              deleteIconColor: isActive ? Colors.white70 : Colors.deepPurple.shade200,
                            );
                          }),
                        ],
                      ),
                      if (_activePlacingField == 'misc-new') ...[
                        const SizedBox(height: 8),
                        TextField(
                          controller: _miscTextController,
                          style: const TextStyle(fontSize: 16),
                          decoration: const InputDecoration(
                            hintText: 'Type text to place on the PDF...',
                            border: OutlineInputBorder(),
                            isDense: true,
                            prefixIcon: Icon(Icons.edit_note, size: 20),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Type your text, then tap the PDF to place it. You can add as many as you need.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary, fontSize: 12),
                        ),
                      ],
                      if (_activePlacingField.startsWith('misc-') && _activePlacingField != 'misc-new') ...[
                        const SizedBox(height: 4),
                        Text(
                          'Tap the PDF to move this misc field to a new position.',
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Colors.deepPurple, fontSize: 12),
                        ),
                      ],
                      const SizedBox(height: 16),
                      _ClickablePdfViewer(
                        pdfUrl: ContractService.getPdfFetchUrl(_contract!.fileUrl),
                        markers: _buildMarkers(),
                        onTapPlaced: (pageIndex, x, y) {
                          setState(() {
                            if (_activePlacingField == 'signature') {
                              _signaturePage = pageIndex;
                              _signatureX = x;
                              _signatureY = y;
                              _signaturePlaced = true;
                              _nameBelowSignature = false;
                              _dateBelowName = false;
                              if (!_namePlaced) _activePlacingField = 'name';
                            } else if (_activePlacingField == 'name') {
                              _namePage = pageIndex;
                              _nameX = x;
                              _nameY = y;
                              _namePlaced = true;
                              _nameBelowSignature = false;
                              if (!_datePlaced) _activePlacingField = 'date';
                            } else if (_activePlacingField == 'date') {
                              _datePage = pageIndex;
                              _dateX = x;
                              _dateY = y;
                              _datePlaced = true;
                              _dateBelowName = false;
                            } else if (_activePlacingField == 'misc-new') {
                              final text = _miscTextController.text.trim();
                              if (text.isNotEmpty) {
                                _miscPlacements.add(_MiscPlacement(
                                  pageIndex: pageIndex, x: x, y: y, text: text,
                                ));
                                _miscTextController.clear();
                              }
                            } else if (_activePlacingField.startsWith('misc-')) {
                              final idx = int.tryParse(_activePlacingField.substring(5));
                              if (idx != null && idx >= 0 && idx < _miscPlacements.length) {
                                final old = _miscPlacements[idx];
                                _miscPlacements[idx] = _MiscPlacement(
                                  pageIndex: pageIndex, x: x, y: y, text: old.text,
                                );
                              }
                            }
                          });
                        },
                      ),
                    ],
                  ],
                  const SizedBox(height: 24),

              // Signer Information
              Text(
                'Signer Information',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(
                  labelText: 'Full Name *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.person),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter your name';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _emailController,
                decoration: const InputDecoration(
                  labelText: 'Email Address *',
                  border: OutlineInputBorder(),
                  prefixIcon: Icon(Icons.email),
                ),
                keyboardType: TextInputType.emailAddress,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter your email';
                  }
                  if (!value.contains('@')) {
                    return 'Please enter a valid email';
                  }
                  return null;
                },
              ),
              ...(_configuredPlaceholders
                  .where((p) =>
                      p.fieldType == SignatureFieldType.storageUnit ||
                      p.fieldType == SignatureFieldType.text ||
                      p.fieldType == SignatureFieldType.initials)
                  .map((p) {
                final label = p.label ?? p.fieldType.defaultPrompt;
                final required = p.required;
                return Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: TextFormField(
                    controller: _extraControllers[p.id],
                    decoration: InputDecoration(
                      labelText: '$label${required ? " *" : ""}',
                      border: const OutlineInputBorder(),
                      prefixIcon: Icon(p.fieldType == SignatureFieldType.storageUnit ? Icons.garage : Icons.short_text),
                    ),
                    validator: required
                        ? (v) {
                            if (v == null || v.trim().isEmpty) return 'Please complete this field';
                            return null;
                          }
                        : null,
                  ),
                );
              })),
              const SizedBox(height: 32),

              // Signature Pads
              ..._buildSignaturePads(),
              const SizedBox(height: 32),

              // Error Message
              if (_errorMessage != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.error.withOpacity(0.1),
                      border: Border.all(color: AppTheme.error),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline, color: AppTheme.error),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            _errorMessage!,
                            style: TextStyle(color: AppTheme.error),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

              // Sign Button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: _isSigning ? null : _signContract,
                  icon: _isSigning
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.edit),
                  label: Text(_isSigning ? 'Signing...' : 'Sign Contract'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.success,
                    foregroundColor: AppTheme.textOnDark,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'By signing, you agree to the terms and conditions outlined in this contract.',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                ),
                textAlign: TextAlign.center,
              ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MiscPlacement {
  final int pageIndex;
  final double x;
  final double y;
  final String text;

  const _MiscPlacement({
    required this.pageIndex,
    required this.x,
    required this.y,
    required this.text,
  });
}

class _PdfMarker {
  final String label;
  final Color color;
  final int pageIndex;
  final double x;
  final double y;
  final double w;
  final double h;

  const _PdfMarker({
    required this.label,
    required this.color,
    required this.pageIndex,
    required this.x,
    required this.y,
    required this.w,
    required this.h,
  });
}

/// Displays the contract PDF and lets the user tap to choose where to place the signature.
class _ClickablePdfViewer extends StatefulWidget {
  final String pdfUrl;
  final List<_PdfMarker> markers;
  final void Function(int pageIndex, double x, double y) onTapPlaced;

  const _ClickablePdfViewer({
    required this.pdfUrl,
    required this.markers,
    required this.onTapPlaced,
  });

  @override
  State<_ClickablePdfViewer> createState() => _ClickablePdfViewerState();
}

class _ClickablePdfViewerState extends State<_ClickablePdfViewer> {
  pdfx.PdfDocument? _document;
  String? _loadError;
  bool _loading = true;

  List<String> _candidateUrls() {
    final urls = <String>[];
    final primary = widget.pdfUrl.trim();
    if (primary.isNotEmpty) urls.add(primary);

    final uri = Uri.tryParse(primary);
    String? encodedTarget;
    if (uri != null) {
      for (final part in uri.query.split('&')) {
        if (part.startsWith('url=')) {
          encodedTarget = part.substring(4);
          break;
        }
      }
    }

    if ((encodedTarget == null || encodedTarget!.isEmpty) &&
        (primary.contains('firebasestorage.googleapis.com') ||
            primary.contains('storage.googleapis.com'))) {
      encodedTarget = Uri.encodeQueryComponent(primary);
    }

    if (encodedTarget != null && encodedTarget.isNotEmpty) {
      final directProxy =
          'https://us-central1-storage-facility-creator.cloudfunctions.net/proxyContractPdfHttp?url=$encodedTarget';
      if (!urls.contains(directProxy)) urls.add(directProxy);
    }
    return urls;
  }

  @override
  void initState() {
    super.initState();
    _loadPdf();
  }

  Future<void> _loadPdf() async {
    final errors = <String>[];
    await ensurePdfJsForWeb();
    for (final url in _candidateUrls()) {
      try {
        final response = await http.get(Uri.parse(url));
        if (response.statusCode != 200) {
          errors.add('HTTP ${response.statusCode} from ${Uri.parse(url).host}');
          continue;
        }
        final doc = await pdfx.PdfDocument.openData(response.bodyBytes);
        if (mounted) {
          setState(() {
            _document = doc;
            _loading = false;
            _loadError = null;
          });
        }
        return;
      } catch (e) {
        errors.add(e.toString());
        if (kDebugMode) {
          print('⚠️ Tap-to-place URL failed: $url -> $e');
        }
      }
    }
    if (kDebugMode) {
      print('⚠️ Error loading PDF for tap-to-place: ${errors.join(' | ')}');
    }
    if (mounted) {
      setState(() {
        _loading = false;
        _loadError = errors.isEmpty ? 'Unknown PDF load error' : errors.join(' | ');
      });
    }
  }

  @override
  void dispose() {
    _document?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        height: 400,
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderLight),
        ),
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Loading PDF...'),
            ],
          ),
        ),
      );
    }
    if (_loadError != null) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: AppTheme.borderLight),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber, color: AppTheme.warning),
                const SizedBox(width: 8),
                const Expanded(
                  child: Text(
                    'Could not load PDF for tap-to-place. Use the Advanced section below to set position manually.',
                    style: TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            if (_loadError != null && _loadError!.isNotEmpty) ...[
              const SizedBox(height: 8),
              SelectableText(
                _loadError!,
                style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary),
              ),
            ],
          ],
        ),
      );
    }
    final doc = _document!;
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderLight),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              'Tap on the document where you want to sign',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: AppTheme.textSecondary,
                    fontWeight: FontWeight.w500,
                  ),
            ),
          ),
          ...List.generate(
            doc.pagesCount,
            (index) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (doc.pagesCount > 1)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4, left: 4),
                      child: Text('Page ${index + 1} of ${doc.pagesCount}',
                          style: const TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                    ),
                  _ClickablePdfPage(
                    document: doc,
                    pageNumber: index + 1,
                    pageIndex: index,
                    markers: widget.markers.where((m) => m.pageIndex == index).toList(),
                    onTap: (x, y) => widget.onTapPlaced(index, x, y),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A single page of the PDF that the user can tap to set signature position.
class _ClickablePdfPage extends StatefulWidget {
  final pdfx.PdfDocument document;
  final int pageNumber;
  final int pageIndex;
  final List<_PdfMarker> markers;
  final void Function(double x, double y) onTap;

  const _ClickablePdfPage({
    required this.document,
    required this.pageNumber,
    required this.pageIndex,
    required this.markers,
    required this.onTap,
  });

  @override
  State<_ClickablePdfPage> createState() => _ClickablePdfPageState();
}

class _ClickablePdfPageState extends State<_ClickablePdfPage> {
  Uint8List? _imageBytes;
  double _pageWidth = 612;
  double _pageHeight = 792;

  @override
  void initState() {
    super.initState();
    _renderPage();
  }

  Future<void> _renderPage() async {
    try {
      final page = await widget.document.getPage(widget.pageNumber);
      _pageWidth = page.width.toDouble();
      _pageHeight = page.height.toDouble();
      final renderScale = 4.0;
      final pageImage = await page.render(
        width: page.width * renderScale,
        height: page.height * renderScale,
      );
      page.close();
      if (mounted && pageImage != null) {
        setState(() {
          _imageBytes = pageImage.bytes;
        });
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Error rendering PDF page: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_imageBytes == null) {
      return Container(
        height: 500,
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: Colors.grey.shade200,
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Center(child: CircularProgressIndicator()),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final availableWidth = constraints.maxWidth > 0 ? constraints.maxWidth : 580.0;
        final aspectRatio = _pageWidth / _pageHeight;
        final displayWidth = availableWidth;
        final displayHeight = displayWidth / aspectRatio;

        final displayScale = displayWidth / _pageWidth;

        return GestureDetector(
          onTapUp: (details) {
            final box = context.findRenderObject() as RenderBox?;
            if (box == null) return;
            final local = box.globalToLocal(details.globalPosition);
            final tapX = (local.dx / displayScale).clamp(0.0, _pageWidth);
            final tapYFromTop = (local.dy / displayScale).clamp(0.0, _pageHeight);
            final pdfY = (_pageHeight - tapYFromTop).clamp(0.0, _pageHeight);
            widget.onTap(tapX, pdfY);
          },
          child: Container(
            width: displayWidth,
            height: displayHeight,
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: widget.markers.isNotEmpty ? AppTheme.primaryBlue : Colors.grey.shade300,
                width: widget.markers.isNotEmpty ? 2 : 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.1),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: Stack(
                children: [
                  Image.memory(
                    _imageBytes!,
                    width: displayWidth,
                    height: displayHeight,
                    fit: BoxFit.fill,
                  ),
                  ...widget.markers.map((m) => Positioned(
                    left: m.x * displayScale,
                    top: (_pageHeight - m.y - m.h) * displayScale,
                    width: (m.w * displayScale).clamp(4.0, double.infinity),
                    height: (m.h * displayScale).clamp(4.0, double.infinity),
                    child: Container(
                      decoration: BoxDecoration(
                        border: Border.all(color: m.color, width: 2),
                        borderRadius: BorderRadius.circular(2),
                        color: m.color.withOpacity(0.15),
                      ),
                      child: Center(
                        child: Text(m.label, style: TextStyle(fontSize: 10, color: m.color, fontWeight: FontWeight.bold)),
                      ),
                    ),
                  )),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _PlacementField extends StatelessWidget {
  final String label;
  final int page;
  final double x;
  final double y;
  final double? w;
  final double? h;
  final bool belowPrevious;
  final double? fontSize;
  final void Function(int) onPage;
  final void Function(double) onX;
  final void Function(double) onY;
  final void Function(double)? onW;
  final void Function(double)? onH;
  final void Function(bool)? onBelowChanged;
  final void Function(double)? onFontSize;
  final bool showSize;
  final String? belowLabel;

  const _PlacementField({
    required this.label,
    required this.page,
    required this.x,
    required this.y,
    this.w,
    this.h,
    this.belowPrevious = false,
    this.fontSize,
    required this.onPage,
    required this.onX,
    required this.onY,
    this.onW,
    this.onH,
    this.onBelowChanged,
    this.onFontSize,
    this.showSize = false,
    this.belowLabel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.borderLight),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Row(
            children: [
              SizedBox(
                width: 72,
                child: TextFormField(
                  initialValue: page < 0 ? 'Last' : '${page + 1}',
                  decoration: const InputDecoration(labelText: 'Page', border: OutlineInputBorder(), isDense: true),
                  onChanged: (v) {
                    final t = v.trim().toLowerCase();
                    if (t.isEmpty || t == 'last') onPage(-1);
                    else {
                      final n = int.tryParse(v.trim());
                      if (n != null && n >= 1) onPage(n - 1);
                    }
                  },
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 72,
                child: TextFormField(
                  initialValue: x.toStringAsFixed(0),
                  decoration: const InputDecoration(labelText: 'X', border: OutlineInputBorder(), isDense: true),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) {
                    final n = double.tryParse(v.trim());
                    if (n != null) onX(n);
                  },
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 72,
                child: TextFormField(
                  initialValue: y.toStringAsFixed(0),
                  decoration: const InputDecoration(labelText: 'Y', border: OutlineInputBorder(), isDense: true),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  onChanged: (v) {
                    final n = double.tryParse(v.trim());
                    if (n != null) onY(n);
                  },
                ),
              ),
              if (showSize && w != null && h != null && onW != null && onH != null) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 60,
                  child: TextFormField(
                    initialValue: w!.toStringAsFixed(0),
                    decoration: const InputDecoration(labelText: 'W', border: OutlineInputBorder(), isDense: true),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (v) {
                      final n = double.tryParse(v.trim());
                      if (n != null) onW!(n);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 60,
                  child: TextFormField(
                    initialValue: h!.toStringAsFixed(0),
                    decoration: const InputDecoration(labelText: 'H', border: OutlineInputBorder(), isDense: true),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (v) {
                      final n = double.tryParse(v.trim());
                      if (n != null) onH!(n);
                    },
                  ),
                ),
              ],
              if (fontSize != null && onFontSize != null) ...[
                const SizedBox(width: 8),
                SizedBox(
                  width: 56,
                  child: TextFormField(
                    initialValue: fontSize!.toStringAsFixed(0),
                    decoration: const InputDecoration(labelText: 'Size', border: OutlineInputBorder(), isDense: true),
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    onChanged: (v) {
                      final n = double.tryParse(v.trim());
                      if (n != null && n >= 6) onFontSize!(n);
                    },
                  ),
                ),
              ],
              if (onBelowChanged != null) ...[
                const SizedBox(width: 12),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: belowPrevious,
                      onChanged: (v) => onBelowChanged!(v ?? false),
                    ),
                    Text(belowLabel ?? 'Below previous', style: const TextStyle(fontSize: 12)),
                  ],
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }
}

