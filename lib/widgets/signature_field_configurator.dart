import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:pdfx/pdfx.dart';
import '../models/contract_template_model.dart';
import '../services/web_externals_loader.dart';
import '../theme/app_theme.dart';

/// Configurator for contract signature fields. Lets facility owners add fields
/// like "Sign your name", "Sign the date", "Sign your contract storage unit number"
/// and tap on the PDF to place each one.
class SignatureFieldConfigurator extends StatefulWidget {
  final Uint8List? pdfBytes;
  final String? pdfUrl;
  final List<SignaturePlaceholder> initialPlaceholders;
  final String tenantSignerId;
  final ValueChanged<List<SignaturePlaceholder>> onPlaceholdersChanged;

  const SignatureFieldConfigurator({
    super.key,
    this.pdfBytes,
    this.pdfUrl,
    this.initialPlaceholders = const [],
    this.tenantSignerId = 'tenantPrimary',
    required this.onPlaceholdersChanged,
  }) : assert(pdfBytes != null || pdfUrl != null, 'Provide pdfBytes or pdfUrl');

  @override
  State<SignatureFieldConfigurator> createState() => _SignatureFieldConfiguratorState();
}

class _SignatureFieldConfiguratorState extends State<SignatureFieldConfigurator> {
  late List<_EditablePlaceholder> _placeholders;
  int _nextId = 0;
  PdfDocument? _document;
  bool _loading = true;
  String? _loadError;
  double _pageWidth = 612;
  double _pageHeight = 792;

  @override
  void initState() {
    super.initState();
    _placeholders = widget.initialPlaceholders
        .map((p) => _EditablePlaceholder(
              id: p.id,
              signerId: p.signerId,
              fieldType: p.fieldType,
              page: p.page,
              x: p.x,
              y: p.y,
              width: p.width,
              height: p.height,
              label: p.label,
              tooltip: p.tooltip,
              placed: p.page >= 1 && (p.x.abs() + p.y.abs()) > 0.01,
            ))
        .toList();
    _nextId = _placeholders.isEmpty ? 0 : _placeholders.map((e) => int.tryParse(e.id.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0).reduce((a, b) => a > b ? a : b) + 1;
    _loadPdf();
  }

  Future<void> _loadPdf() async {
    try {
      await ensurePdfJsForWeb();
      Uint8List bytes;
      if (widget.pdfBytes != null) {
        bytes = widget.pdfBytes!;
      } else {
        final resp = await http.get(Uri.parse(widget.pdfUrl!));
        if (resp.statusCode != 200) throw Exception('Failed to load PDF');
        bytes = resp.bodyBytes;
      }
      final doc = await PdfDocument.openData(bytes);
      if (doc.pagesCount > 0) {
        final page = await doc.getPage(1);
        _pageWidth = page.width.toDouble();
        _pageHeight = page.height.toDouble();
        page.close();
      }
      if (mounted) {
        setState(() {
          _document = doc;
          _loading = false;
          _loadError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _loadError = e.toString();
        });
      }
    }
  }

  void _emitPlaceholders() {
    widget.onPlaceholdersChanged(
      _placeholders
          .where((p) => p.placed)
          .map((p) => SignaturePlaceholder(
                id: p.id,
                signerId: p.signerId,
                fieldType: p.fieldType,
                page: p.page,
                x: p.x,
                y: p.y,
                width: p.width,
                height: p.height,
                label: p.label,
                tooltip: p.tooltip,
              ))
          .toList(),
    );
  }

  void _addField(SignatureFieldType type) {
    final id = 'field-$_nextId';
    _nextId++;
    setState(() {
      _placeholders.add(_EditablePlaceholder(
        id: id,
        signerId: widget.tenantSignerId,
        fieldType: type,
        page: 1,
        x: 0.15,
        y: 0.8,
        width: type == SignatureFieldType.signature ? 0.25 : 0.2,
        height: type == SignatureFieldType.signature ? 0.08 : 0.04,
        label: null,
        tooltip: type.defaultPrompt,
      ));
    });
    _emitPlaceholders();
  }

  void _removeField(int index) {
    setState(() {
      _placeholders.removeAt(index);
    });
    _emitPlaceholders();
  }

  void _updateField(int index, {SignatureFieldType? type, String? label, int? page, double? x, double? y, double? width, double? height, bool? placed}) {
    setState(() {
      final p = _placeholders[index];
      _placeholders[index] = _EditablePlaceholder(
        id: p.id,
        signerId: p.signerId,
        fieldType: type ?? p.fieldType,
        page: page ?? p.page,
        x: x ?? p.x,
        y: y ?? p.y,
        width: width ?? p.width,
        height: height ?? p.height,
        label: label ?? p.label,
        tooltip: p.tooltip,
        placed: placed ?? p.placed,
      );
    });
    _emitPlaceholders();
  }

  void _placeField(int index, int page, double x, double y) {
    // Convert from PDF coords to relative 0-1 (y from bottom in PDF)
    final xRel = (x / _pageWidth).clamp(0.0, 1.0);
    final yRel = (y / _pageHeight).clamp(0.0, 1.0);
    _updateField(index, page: page + 1, x: xRel, y: yRel, placed: true);
  }

  IconData _iconFor(SignatureFieldType t) {
    switch (t) {
      case SignatureFieldType.signature:
        return Icons.draw;
      case SignatureFieldType.initials:
        return Icons.text_fields;
      case SignatureFieldType.date:
        return Icons.event;
      case SignatureFieldType.text:
        return Icons.short_text;
      case SignatureFieldType.storageUnit:
        return Icons.garage;
      case SignatureFieldType.name:
        return Icons.person;
    }
  }

  @override
  void dispose() {
    _document?.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Configure where each field appears on the contract. Add fields and tap on the PDF to place them.',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 16),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: SignatureFieldType.values.map((type) {
            return ActionChip(
              avatar: Icon(_iconFor(type), size: 18, color: AppTheme.primaryBlue),
              label: Text(type.displayName),
              onPressed: () => _addField(type),
            );
          }).toList(),
        ),
        const SizedBox(height: 16),
        if (_placeholders.isNotEmpty)
          ...List.generate(_placeholders.length, (i) {
            final p = _placeholders[i];
            final prompt = p.label ?? p.fieldType.defaultPrompt;
            return Card(
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
                leading: Icon(_iconFor(p.fieldType), color: AppTheme.primaryBlue),
                title: Text(prompt),
                subtitle: p.placed
                    ? Text(
                        'Page ${p.page} • placed • ${(p.width * 100).round()}% × ${(p.height * 100).round()}%',
                        style: TextStyle(color: AppTheme.success, fontSize: 12),
                      )
                    : Text('Tap on PDF to place', style: TextStyle(color: AppTheme.warning, fontSize: 12)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!p.placed)
                      TextButton(
                        onPressed: _loading || _loadError != null
                            ? null
                            : () => _showPlacePicker(i),
                        child: const Text('Place'),
                      ),
                    IconButton(
                      icon: const Icon(Icons.edit, size: 20),
                      onPressed: () => _showEditDialog(i),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete, size: 20, color: AppTheme.error),
                      onPressed: () => _removeField(i),
                    ),
                  ],
                ),
              ),
            );
          }),
        if (_placeholders.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppTheme.backgroundLight,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.borderLight),
            ),
            child: Center(
              child: Text(
                'Add fields above (e.g. "Sign your name", "Sign the date", "Storage unit number") then tap "Place" to position each on the PDF.',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(color: AppTheme.textSecondary),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        if (_loading) ...[
          const SizedBox(height: 16),
          const Center(child: CircularProgressIndicator()),
        ] else if (_loadError != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.error.withOpacity(0.1),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text('Could not load PDF: $_loadError', style: const TextStyle(color: AppTheme.error)),
          ),
        ],
      ],
    );
  }

  void _showPlacePicker(int index) async {
    if (_document == null) return;
    final result = await showDialog<({int page, double x, double y})>(
      context: context,
      builder: (ctx) => _PdfTapDialog(
        document: _document!,
        pageWidth: _pageWidth,
        pageHeight: _pageHeight,
        fieldLabel: _placeholders[index].label ?? _placeholders[index].fieldType.defaultPrompt,
      ),
    );
    if (result != null && mounted) {
      _placeField(index, result.page, result.x, result.y);
    }
  }

  void _showEditDialog(int index) {
    final p = _placeholders[index];
    final labelController = TextEditingController(text: p.label ?? p.fieldType.defaultPrompt);
    double fieldWidth = p.width;
    double fieldHeight = p.height;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Customize field'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('Prompt shown to signer:'),
                const SizedBox(height: 8),
                TextField(
                  controller: labelController,
                  decoration: const InputDecoration(
                    hintText: 'e.g. Sign your contract storage unit number',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 20),
                const Text('Field width on PDF (% of page width):'),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: fieldWidth.clamp(0.05, 0.95),
                        min: 0.05,
                        max: 0.95,
                        divisions: 18,
                        label: '${(fieldWidth * 100).round()}%',
                        onChanged: (v) => setDialogState(() => fieldWidth = v),
                      ),
                    ),
                    SizedBox(
                      width: 42,
                      child: Text(
                        '${(fieldWidth * 100).round()}%',
                        style: const TextStyle(fontSize: 12),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const Text('Field height on PDF (% of page height):'),
                Row(
                  children: [
                    Expanded(
                      child: Slider(
                        value: fieldHeight.clamp(0.01, 0.5),
                        min: 0.01,
                        max: 0.5,
                        divisions: 24,
                        label: '${(fieldHeight * 100).round()}%',
                        onChanged: (v) => setDialogState(() => fieldHeight = v),
                      ),
                    ),
                    SizedBox(
                      width: 42,
                      child: Text(
                        '${(fieldHeight * 100).round()}%',
                        style: const TextStyle(fontSize: 12),
                        textAlign: TextAlign.right,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                _updateField(
                  index,
                  label: labelController.text.trim().isEmpty ? null : labelController.text.trim(),
                  width: fieldWidth,
                  height: fieldHeight,
                );
                Navigator.pop(ctx);
              },
              style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryBlueDark, foregroundColor: AppTheme.textOnDark),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EditablePlaceholder {
  final String id;
  final String signerId;
  final SignatureFieldType fieldType;
  final int page;
  final double x;
  final double y;
  final double width;
  final double height;
  final String? label;
  final String? tooltip;
  final bool placed;

  _EditablePlaceholder({
    required this.id,
    required this.signerId,
    required this.fieldType,
    required this.page,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.label,
    this.tooltip,
    this.placed = false,
  });
}

class _PdfTapDialog extends StatefulWidget {
  final PdfDocument document;
  final double pageWidth;
  final double pageHeight;
  final String fieldLabel;

  const _PdfTapDialog({
    required this.document,
    required this.pageWidth,
    required this.pageHeight,
    required this.fieldLabel,
  });

  @override
  State<_PdfTapDialog> createState() => _PdfTapDialogState();
}

class _PdfTapDialogState extends State<_PdfTapDialog> {
  int _selectedPage = 0;
  double? _tapX;
  double? _tapY;
  Uint8List? _imageBytes;
  final _imageKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _renderPage();
  }

  Future<void> _renderPage() async {
    try {
      final page = await widget.document.getPage(_selectedPage + 1);
      final img = await page.render(width: page.width * 4, height: page.height * 4);
      page.close();
      if (mounted && img != null) setState(() => _imageBytes = img.bytes);
    } catch (e) {
      if (kDebugMode) print('Render error: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final maxW = (mq.size.width * 0.92).clamp(600.0, 1200.0);
    final maxH = mq.size.height * 0.88;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: maxW, maxHeight: maxH),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Row(
                children: [
                  Expanded(child: Text('Tap where: ${widget.fieldLabel}', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold))),
                  if (widget.document.pagesCount > 1)
                    DropdownButton<int>(
                      value: _selectedPage,
                      items: List.generate(widget.document.pagesCount, (i) => DropdownMenuItem(value: i, child: Text('Page ${i + 1}'))),
                      onChanged: (v) {
                        if (v != null) {
                          setState(() { _selectedPage = v; _tapX = null; _tapY = null; });
                          _renderPage();
                        }
                      },
                    ),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: _imageBytes != null
                    ? LayoutBuilder(
                        builder: (context, constraints) {
                          final displayWidth = constraints.maxWidth > 0 ? constraints.maxWidth : 600.0;
                          final aspectRatio = widget.pageWidth / widget.pageHeight;
                          final displayHeight = displayWidth / aspectRatio;
                          final displayScale = displayWidth / widget.pageWidth;

                          return GestureDetector(
                            onTapUp: (details) {
                              final box = _imageKey.currentContext?.findRenderObject() as RenderBox?;
                              if (box == null) return;
                              final local = box.globalToLocal(details.globalPosition);
                              final tapX = (local.dx / displayScale).clamp(0.0, widget.pageWidth);
                              final tapYFromTop = (local.dy / displayScale).clamp(0.0, widget.pageHeight);
                              final pdfY = (widget.pageHeight - tapYFromTop).clamp(0.0, widget.pageHeight);
                              setState(() { _tapX = tapX; _tapY = pdfY; });
                            },
                            child: Container(
                              key: _imageKey,
                              width: displayWidth,
                              height: displayHeight,
                              decoration: BoxDecoration(
                                border: Border.all(color: AppTheme.primaryBlue),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Stack(
                                children: [
                                  Image.memory(_imageBytes!, width: displayWidth, height: displayHeight, fit: BoxFit.fill),
                                  if (_tapX != null && _tapY != null)
                                    Positioned(
                                      left: _tapX! * displayScale - 16,
                                      top: (widget.pageHeight - _tapY!) * displayScale - 16,
                                      child: Container(
                                        width: 32,
                                        height: 32,
                                        decoration: BoxDecoration(
                                          color: AppTheme.primaryBlue.withOpacity(0.3),
                                          border: Border.all(color: AppTheme.primaryBlue, width: 2),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(Icons.place, size: 18, color: AppTheme.primaryBlue),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          );
                        },
                      )
                    : const SizedBox(height: 300, child: Center(child: CircularProgressIndicator())),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    onPressed: _tapX != null && _tapY != null
                        ? () => Navigator.pop(context, (page: _selectedPage, x: _tapX!, y: _tapY!))
                        : null,
                    style: ElevatedButton.styleFrom(backgroundColor: AppTheme.primaryBlueDark, foregroundColor: AppTheme.textOnDark),
                    child: const Text('Confirm'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
