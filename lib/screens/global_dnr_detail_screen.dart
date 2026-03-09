import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_picker/image_picker.dart';
import '../models/global_dnr_model.dart';
import '../providers/dnr_provider.dart';
import '../services/global_dnr_service.dart';
import '../theme/app_theme.dart';

/// Detail view for a global DNR entry: full details, evidence gallery, upload, status change.
class GlobalDNRDetailScreen extends ConsumerStatefulWidget {
  final GlobalDNREntryModel entry;

  const GlobalDNRDetailScreen({super.key, required this.entry});

  @override
  ConsumerState<GlobalDNRDetailScreen> createState() => _GlobalDNRDetailScreenState();
}

class _GlobalDNRDetailScreenState extends ConsumerState<GlobalDNRDetailScreen> {
  bool _isUpdating = false;
  String? _errorMessage;

  @override
  Widget build(BuildContext context) {
    final entry = widget.entry;
    return Scaffold(
      appBar: AppBar(
        title: Text(entry.fullName),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          if (entry.isActive)
            PopupMenuButton<String>(
              onSelected: (v) => _handleStatusChange(v),
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'inactive', child: Text('Mark inactive')),
                const PopupMenuItem(value: 'appealed', child: Text('Mark appealed')),
              ],
            ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_errorMessage != null) ...[
              Container(
                padding: const EdgeInsets.all(12),
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: AppTheme.error.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: AppTheme.error),
                ),
                child: Text(_errorMessage!, style: const TextStyle(color: AppTheme.error)),
              ),
            ],
            _buildInfoCard(entry),
            const SizedBox(height: 16),
            const Text('Evidence (photos/documents)', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            _buildEvidenceSection(entry.id),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _isUpdating ? null : () => _pickAndUploadEvidence(entry.id),
              icon: const Icon(Icons.upload_file),
              label: const Text('Upload photo or document'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoCard(GlobalDNREntryModel entry) {
    return Card(
      elevation: 1,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Chip(label: Text(entry.severity.value), backgroundColor: AppTheme.primaryBlue.withOpacity(0.2)),
                const SizedBox(width: 8),
                Chip(
                  label: Text(entry.status.value),
                  backgroundColor: entry.isActive ? AppTheme.success.withOpacity(0.2) : AppTheme.textTertiary.withOpacity(0.2),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _row('Full name', entry.fullName),
            _row('Email', entry.email),
            _row('Phone', entry.phone),
            if (entry.dob != null && entry.dob!.isNotEmpty) _row('DOB', entry.dob!),
            if (entry.driversLicenseLast4 != null) _row('ID/License last 4', entry.driversLicenseLast4!),
            _row('Reason', entry.reason),
            if (entry.notes != null && entry.notes!.isNotEmpty) _row('Notes', entry.notes!),
            const Divider(height: 24),
            _row('Created by facility', entry.createdByFacilityName ?? entry.createdByFacilityId),
            if (entry.createdByState != null && entry.createdByState!.isNotEmpty) _row('State', entry.createdByState!),
            _row('Evidence count', '${entry.evidenceCount}'),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(width: 140, child: Text(label, style: const TextStyle(fontWeight: FontWeight.w600))),
          Expanded(child: Text(value)),
        ],
      ),
    );
  }

  Widget _buildEvidenceSection(String entryId) {
    final evidenceAsync = ref.watch(globalDnrEvidenceProvider(entryId));
    return evidenceAsync.when(
      data: (list) {
        if (list.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppTheme.textTertiary.withOpacity(0.08),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.borderLight),
            ),
            child: const Center(
              child: Text('No evidence yet. Upload photos or documents below.'),
            ),
          );
        }
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
            childAspectRatio: 0.85,
          ),
          itemCount: list.length,
          itemBuilder: (context, index) {
            final ev = list[index];
            return _evidenceTile(ev);
          },
        );
      },
      loading: () => const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator())),
      error: (e, _) => Text('Error loading evidence: $e', style: const TextStyle(color: AppTheme.error)),
    );
  }

  Widget _evidenceTile(GlobalDNREvidenceModel ev) {
    final isPhoto = ev.type == 'photo';
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: ev.downloadUrl != null && ev.downloadUrl!.isNotEmpty && isPhoto
                ? Image.network(ev.downloadUrl!, fit: BoxFit.cover)
                : Center(
                    child: Icon(isPhoto ? Icons.image : Icons.description, size: 48, color: AppTheme.textTertiary),
                  ),
          ),
          if (ev.caption != null && ev.caption!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(4),
              child: Text(ev.caption!, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 11)),
            ),
        ],
      ),
    );
  }

  Future<void> _pickAndUploadEvidence(String entryId) async {
    final source = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library),
              title: const Text('Choose from gallery'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            ListTile(
              leading: const Icon(Icons.upload_file),
              title: const Text('Choose file'),
              onTap: () => Navigator.pop(context, 'file'),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;

    Uint8List? bytes;
    String filename = 'evidence';

    if (source == 'gallery') {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(source: ImageSource.gallery, imageQuality: 85);
      if (xfile == null) return;
      bytes = await xfile.readAsBytes();
      filename = xfile.name;
    } else {
      final result = await FilePicker.platform.pickFiles(type: FileType.any, allowMultiple: false);
      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;
      if (file.bytes != null) {
        bytes = file.bytes;
        filename = file.name;
      } else {
        return;
      }
    }

    if (bytes == null || bytes.isEmpty) {
      return;
    }

    setState(() => _isUpdating = true);
    try {
      await GlobalDNRService.addEvidence(
        entryId: entryId,
        bytes: bytes,
        filename: filename,
        isPhoto: source == 'gallery',
      );
      if (mounted) {
        ref.invalidate(globalDnrEvidenceProvider(entryId));
        ref.invalidate(globalDnrEntryDetailProvider(entryId));
        ref.invalidate(globalDnrEntriesFromGlobalCollectionProvider);
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Evidence added')));
      }
    } catch (e) {
      if (mounted) setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

  Future<void> _handleStatusChange(String value) async {
    final status = value == 'appealed' ? GlobalDnrStatus.appealed : GlobalDnrStatus.inactive;
    setState(() => _isUpdating = true);
    try {
      await GlobalDNRService.updateGlobalDNREntry(entryId: widget.entry.id, status: status);
      if (mounted) {
        ref.invalidate(globalDnrEntryDetailProvider(widget.entry.id));
        ref.invalidate(globalDnrEntriesFromGlobalCollectionProvider);
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Entry marked ${status.value}')));
      }
    } catch (e) {
      if (mounted) setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }
}
