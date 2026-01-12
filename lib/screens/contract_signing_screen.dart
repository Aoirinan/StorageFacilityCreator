import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:signature/signature.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:http/http.dart' as http;
import '../models/contract_model.dart';
import '../services/contract_service.dart';
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
  final SignatureController _signatureController = SignatureController(
    penStrokeWidth: 2,
    penColor: AppTheme.textPrimary,
  );

  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  bool _isLoading = false;
  bool _isSigning = false;
  String? _errorMessage;
  ContractModel? _contract;
  TenantModel? _tenant;

  @override
  void initState() {
    super.initState();
    _loadContract();
  }

  @override
  void dispose() {
    _signatureController.dispose();
    _nameController.dispose();
    _emailController.dispose();
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

      // Generate signed PDF
      final signedPdfBytes = await _generateSignedPdf(signatureBytes);

      // Upload signed PDF
      final signedFileUrl = await ContractService.uploadSignedContract(
        facilityId: _contract!.facilityId,
        contractId: _contract!.id,
        pdfData: signedPdfBytes,
      );

      // Sign the contract
      await ContractService.signContract(
        facilityId: _contract!.facilityId,
        contractId: _contract!.id,
        signedBy: _nameController.text.trim(),
        signedFileUrl: signedFileUrl,
        signingToken: widget.signingToken,
      );

      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Contract signed successfully!'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error signing contract: $e';
        _isSigning = false;
      });
    }
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
        final response = await http.get(Uri.parse(_contract!.fileUrl!));
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
        appBar: AppBar(
          title: const Text('Sign Contract'),
          backgroundColor: AppTheme.primaryBlueDark,
          foregroundColor: AppTheme.textOnDark,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.error_outline, size: 64, color: AppTheme.error),
                const SizedBox(height: 16),
                Text(
                  _errorMessage!,
                  textAlign: TextAlign.center,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Close'),
                ),
              ],
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
      appBar: AppBar(
        title: const Text('Sign Contract'),
        backgroundColor: AppTheme.primaryBlueDark,
        foregroundColor: AppTheme.textOnDark,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Contract Info
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
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
                    ],
                  ),
                ),
              ),
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
              const SizedBox(height: 32),

              // Signature Pad
              Text(
                'Signature *',
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Please sign in the box below using your mouse or touch screen',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                ),
              ),
              const SizedBox(height: 16),
              Container(
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  border: Border.all(color: AppTheme.borderLight),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Signature(
                  controller: _signatureController,
                  height: 200,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton.icon(
                    onPressed: _signatureController.isEmpty
                        ? null
                        : () {
                            _signatureController.clear();
                          },
                    icon: const Icon(Icons.clear),
                    label: const Text('Clear'),
                  ),
                ],
              ),
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
    );
  }
}

