import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../models/lien_model.dart';
import '../services/lien_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_router.dart';

class LienDetailScreen extends ConsumerStatefulWidget {
  final LienModel lien;
  final String facilityId;

  const LienDetailScreen({
    super.key,
    required this.lien,
    required this.facilityId,
  });

  @override
  ConsumerState<LienDetailScreen> createState() => _LienDetailScreenState();
}

class _LienDetailScreenState extends ConsumerState<LienDetailScreen> {
  bool _isUpdating = false;
  LienModel? _currentLien;

  @override
  void initState() {
    super.initState();
    _currentLien = widget.lien;
    _refreshLien();
  }

  Future<void> _refreshLien() async {
    final lien = await LienService.getLien(
      facilityId: widget.facilityId,
      lienId: widget.lien.id,
    );
    if (lien != null) {
      setState(() {
        _currentLien = lien;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final lien = _currentLien ?? widget.lien;
    final dateFormat = DateFormat('MMM d, yyyy');
    
    return SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildStatusCard(lien),
            const SizedBox(height: 16),
            _buildLienInfo(lien, dateFormat),
            const SizedBox(height: 16),
            _buildAmountBreakdown(lien),
            const SizedBox(height: 16),
            _buildLegalDates(lien, dateFormat),
            if (lien.notes != null && lien.notes!.isNotEmpty) ...[
              const SizedBox(height: 16),
              _buildNotes(lien),
            ],
            if (lien.noticePdfUrl != null || lien.lienFilingPdfUrl != null || lien.auctionNoticePdfUrl != null) ...[
              const SizedBox(height: 16),
              _buildDocuments(lien),
            ],
          ],
        ),
      );
  }

  Widget _buildStatusCard(LienModel lien) {
    final stageColor = _getStageColor(lien.currentStage);
    
    return Card(
      color: stageColor.withOpacity(0.1),
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Row(
          children: [
            CircleAvatar(
              backgroundColor: stageColor,
              child: Icon(
                _getStageIcon(lien.currentStage),
                color: AppTheme.textOnDark,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    lien.stageDisplayName,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      color: stageColor,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    lien.formattedTotal,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLienInfo(LienModel lien, DateFormat dateFormat) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Lien Information',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildInfoRow('Lien ID', lien.id.substring(0, 12) + '...'),
            if (lien.lienNumber != null)
              _buildInfoRow('Lien Number', lien.lienNumber!),
            if (lien.county != null)
              _buildInfoRow('County', lien.county!),
            if (lien.auctionCompany != null)
              _buildInfoRow('Auction Company', lien.auctionCompany!),
            if (lien.auctionReference != null)
              _buildInfoRow('Auction Reference', lien.auctionReference!),
            _buildInfoRow('Status', lien.statusDisplayName),
            _buildInfoRow('Created', dateFormat.format(lien.createdAt)),
          ],
        ),
      ),
    );
  }

  Widget _buildAmountBreakdown(LienModel lien) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Amount Breakdown',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            _buildAmountRow('Principal', lien.principalAmount),
            _buildAmountRow('Late Fees', lien.lateFees),
            if (lien.lienFilingFee != null)
              _buildAmountRow('Lien Filing Fee', lien.lienFilingFee!),
            if (lien.auctionFee != null)
              _buildAmountRow('Auction Fee', lien.auctionFee!),
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Total Amount:',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                Text(
                  lien.formattedTotal,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegalDates(LienModel lien, DateFormat dateFormat) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Legal Dates',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            if (lien.noticeSentDate != null)
              _buildInfoRow('Notice Sent', dateFormat.format(lien.noticeSentDate!)),
            if (lien.lienFiledDate != null)
              _buildInfoRow('Lien Filed', dateFormat.format(lien.lienFiledDate!)),
            if (lien.auctionScheduledDate != null)
              _buildInfoRow('Auction Scheduled', dateFormat.format(lien.auctionScheduledDate!)),
            if (lien.auctionCompleteDate != null)
              _buildInfoRow('Auction Complete', dateFormat.format(lien.auctionCompleteDate!)),
            if (lien.resolvedDate != null)
              _buildInfoRow('Resolved', dateFormat.format(lien.resolvedDate!)),
            if (lien.cancelledDate != null)
              _buildInfoRow('Cancelled', dateFormat.format(lien.cancelledDate!)),
          ],
        ),
      ),
    );
  }

  Widget _buildNotes(LienModel lien) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Notes',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              lien.notes!,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDocuments(LienModel lien) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Documents',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 16),
            if (lien.noticePdfUrl != null)
              ListTile(
                leading: const Icon(Icons.description, color: AppTheme.info),
                title: const Text('Lien Notice PDF'),
                trailing: IconButton(
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () {
                    // Open PDF in browser
                  },
                ),
              ),
            if (lien.lienFilingPdfUrl != null)
              ListTile(
                leading: const Icon(Icons.description, color: AppTheme.info),
                title: const Text('Lien Filing Document'),
                trailing: IconButton(
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () {
                    // Open PDF in browser
                  },
                ),
              ),
            if (lien.auctionNoticePdfUrl != null)
              ListTile(
                leading: const Icon(Icons.description, color: AppTheme.info),
                title: const Text('Auction Notice PDF'),
                trailing: IconButton(
                  icon: const Icon(Icons.open_in_new),
                  onPressed: () {
                    // Open PDF in browser
                  },
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppTheme.textSecondary,
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAmountRow(String label, double amount) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(
            '\$${amount.toStringAsFixed(2)}',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Color _getStageColor(LienStage stage) {
    switch (stage) {
      case LienStage.notStarted:
        return AppTheme.textSecondary;
      case LienStage.noticeSent:
        return AppTheme.warning;
      case LienStage.lienFiled:
        return AppTheme.info;
      case LienStage.auctionScheduled:
        return AppTheme.error;
      case LienStage.auctionComplete:
        return AppTheme.textSecondary;
      case LienStage.resolved:
        return AppTheme.success;
      case LienStage.cancelled:
        return AppTheme.textSecondary;
    }
  }

  IconData _getStageIcon(LienStage stage) {
    switch (stage) {
      case LienStage.notStarted:
        return Icons.pending;
      case LienStage.noticeSent:
        return Icons.send;
      case LienStage.lienFiled:
        return Icons.description;
      case LienStage.auctionScheduled:
        return Icons.calendar_today;
      case LienStage.auctionComplete:
        return Icons.check_circle;
      case LienStage.resolved:
        return Icons.verified;
      case LienStage.cancelled:
        return Icons.cancel;
    }
  }

  void _handleMenuAction(String action) {
    switch (action) {
      case 'send_notice':
        _updateStage(LienStage.noticeSent);
        break;
      case 'file_lien':
        _showFileLienDialog();
        break;
      case 'schedule_auction':
        _showScheduleAuctionDialog();
        break;
      case 'complete_auction':
        _updateStage(LienStage.auctionComplete);
        break;
      case 'resolve':
        _updateStage(LienStage.resolved);
        break;
      case 'cancel':
        _updateStage(LienStage.cancelled);
        break;
    }
  }

  void _showFileLienDialog() {
    final lienNumberController = TextEditingController();
    final countyController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('File Lien'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: lienNumberController,
              decoration: const InputDecoration(
                labelText: 'Lien Number',
                hintText: 'County lien number',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: countyController,
              decoration: const InputDecoration(
                labelText: 'County',
                hintText: 'County where lien is filed',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              _updateStage(
                LienStage.lienFiled,
                lienNumber: lienNumberController.text.isEmpty ? null : lienNumberController.text,
                county: countyController.text.isEmpty ? null : countyController.text,
              );
              Navigator.pop(context);
            },
            child: const Text('File Lien'),
          ),
        ],
      ),
    );
  }

  void _showScheduleAuctionDialog() {
    final auctionCompanyController = TextEditingController();
    final auctionReferenceController = TextEditingController();
    DateTime? auctionDate = DateTime.now().add(const Duration(days: 30));
    final auctionFeeController = TextEditingController();

    showDialog(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Schedule Auction'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: auctionCompanyController,
                  decoration: const InputDecoration(
                    labelText: 'Auction Company',
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: auctionReferenceController,
                  decoration: const InputDecoration(
                    labelText: 'Auction Reference Number',
                  ),
                ),
                const SizedBox(height: 16),
                ListTile(
                  title: const Text('Auction Date'),
                  subtitle: Text(DateFormat('MMM d, yyyy').format(auctionDate!)),
                  trailing: IconButton(
                    icon: const Icon(Icons.calendar_today),
                    onPressed: () async {
                      final date = await showDatePicker(
                        context: context,
                        initialDate: auctionDate!,
                        firstDate: DateTime.now(),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (date != null) {
                        setState(() {
                          auctionDate = date;
                        });
                      }
                    },
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: auctionFeeController,
                  decoration: const InputDecoration(
                    labelText: 'Auction Fee (\$)',
                    prefixText: '\$',
                  ),
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                _updateStage(
                  LienStage.auctionScheduled,
                  auctionCompany: auctionCompanyController.text.isEmpty ? null : auctionCompanyController.text,
                  auctionReference: auctionReferenceController.text.isEmpty ? null : auctionReferenceController.text,
                  auctionScheduledDate: auctionDate,
                  auctionFee: double.tryParse(auctionFeeController.text),
                );
                Navigator.pop(context);
              },
              child: const Text('Schedule'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _updateStage(
    LienStage newStage, {
    String? lienNumber,
    String? county,
    String? auctionCompany,
    String? auctionReference,
    DateTime? auctionScheduledDate,
    double? auctionFee,
  }) async {
    setState(() {
      _isUpdating = true;
    });

    try {
      await LienService.updateLienStage(
        facilityId: widget.facilityId,
        lienId: widget.lien.id,
        newStage: newStage,
        lienNumber: lienNumber,
        county: county,
        auctionCompany: auctionCompany,
        auctionReference: auctionReference,
        auctionScheduledDate: auctionScheduledDate,
        auctionFee: auctionFee,
      );

      // Generate notice PDF if sending notice
      if (newStage == LienStage.noticeSent) {
        try {
          await LienService.generateAndUploadLienNoticePDF(
            lien: widget.lien,
            facilityId: widget.facilityId,
            lienId: widget.lien.id,
          );
        } catch (e) {
          // Don't fail if PDF generation fails
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Lien updated but PDF generation failed: $e'),
                backgroundColor: AppTheme.warning,
              ),
            );
          }
        }
      }

      await _refreshLien();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Lien updated to ${_getStageLabel(newStage)}'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error updating lien: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
        setState(() {
          _isUpdating = false;
        });
      }
    }
  }

  String _getStageLabel(LienStage stage) {
    switch (stage) {
      case LienStage.notStarted:
        return 'Not Started';
      case LienStage.noticeSent:
        return 'Notice Sent';
      case LienStage.lienFiled:
        return 'Lien Filed';
      case LienStage.auctionScheduled:
        return 'Auction Scheduled';
      case LienStage.auctionComplete:
        return 'Auction Complete';
      case LienStage.resolved:
        return 'Resolved';
      case LienStage.cancelled:
        return 'Cancelled';
    }
  }
}

