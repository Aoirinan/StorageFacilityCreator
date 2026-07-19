import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:go_router/go_router.dart';
import '../models/global_dnr_model.dart';
import '../providers/dnr_provider.dart';
import '../router/app_route.dart';
import '../services/global_dnr_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import 'global_dnr_entry_screen.dart';

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
    return ModernPageWrapper(
      currentRoute: '/dnr',
      title: 'DNR Entry \u2022 ${entry.fullName}',
      actions: [
        IconButton(
          icon: const Icon(Icons.attach_file),
          tooltip: 'Add evidence (photo or document)',
          onPressed: _isUpdating ? null : () => _pickAndUploadEvidence(entry.id),
        ),
        PopupMenuButton<String>(
          tooltip: 'Entry actions',
          icon: const Icon(Icons.more_vert),
          onSelected: (v) {
            switch (v) {
              case 'edit':
                _openEdit(entry);
                break;
              case 'delete':
                _confirmDelete(entry);
                break;
              default:
                _handleStatusChange(v);
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'edit', child: Text('Edit entry')),
            if (entry.isActive) ...[
              const PopupMenuItem(value: 'inactive', child: Text('Mark inactive')),
              const PopupMenuItem(value: 'appealed', child: Text('Mark appealed')),
            ] else
              const PopupMenuItem(value: 'active', child: Text('Reactivate')),
            const PopupMenuDivider(),
            const PopupMenuItem(
              value: 'delete',
              child: Text('Delete entry',
                  style: TextStyle(color: AppTheme.error)),
            ),
          ],
        ),
        IconButton(
          icon: const Icon(Icons.close),
          tooltip: 'Back to DNR list',
          onPressed: () => Navigator.of(context).pop(),
        ),
      ],
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
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
          ],
            ),
          ),
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
            if (entry.reportedByName != null && entry.reportedByName!.isNotEmpty)
              _row(
                'Reported by',
                '${entry.reportedByName}${entry.reportedByEmail != null && entry.reportedByEmail!.isNotEmpty ? ' (${entry.reportedByEmail})' : ''}',
              ),
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
              child: Text('No evidence attached to this entry.'),
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
    // Single picker (photos and documents alike); photo-ness is detected from
    // the file extension so images get thumbnails and correct content types.
    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: true,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    setState(() => _isUpdating = true);
    var added = 0;
    try {
      for (final file in result.files) {
        final bytes = file.bytes;
        if (bytes == null || bytes.isEmpty) continue;
        await GlobalDNRService.addEvidence(
          entryId: entryId,
          bytes: bytes,
          filename: file.name,
          isPhoto: GlobalDNRService.isPhotoFilename(file.name),
        );
        added++;
      }
      if (mounted && added > 0) {
        ref.invalidate(globalDnrEvidenceProvider(entryId));
        ref.invalidate(globalDnrEntryDetailProvider(entryId));
        ref.invalidate(globalDnrEntriesFromGlobalCollectionProvider);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(added == 1 ? 'Evidence added' : '$added evidence files added')));
      }
    } catch (e) {
      if (mounted) setState(() => _errorMessage = e.toString());
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

  Future<void> _handleStatusChange(String value) async {
    final status = switch (value) {
      'appealed' => GlobalDnrStatus.appealed,
      'active' => GlobalDnrStatus.active,
      _ => GlobalDnrStatus.inactive,
    };
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

  Future<void> _openEdit(GlobalDNREntryModel entry) async {
    final result = await context.push(
      AppRoute.legacyScreen,
      extra: GlobalDNREntryScreen(existing: entry),
    );
    if (result != true || !mounted) return;

    ref.invalidate(globalDnrEntryDetailProvider(entry.id));
    ref.invalidate(globalDnrEntriesFromGlobalCollectionProvider);
    ref.invalidate(globalDnrSearchProvider);

    // Refresh this screen with the updated entry (widget.entry is stale).
    final updated = await GlobalDNRService.getGlobalDNREntry(entry.id);
    if (!mounted) return;
    if (updated != null) {
      context.pushReplacement(AppRoute.legacyScreen,
          extra: GlobalDNRDetailScreen(entry: updated));
    } else {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _confirmDelete(GlobalDNREntryModel entry) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete DNR entry'),
        content: Text(
            'Permanently delete "${entry.fullName}" from the Global DNR list?\n\n'
            'This removes the entry and all attached evidence for every facility on the platform, and cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.error,
              foregroundColor: AppTheme.textOnDark,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isUpdating = true);
    try {
      await GlobalDNRService.deleteGlobalDNREntry(entry.id);
      if (mounted) {
        ref.invalidate(globalDnrEntriesFromGlobalCollectionProvider);
        ref.invalidate(globalDnrSearchProvider);
        Navigator.of(context).pop(true);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('"${entry.fullName}" deleted from Global DNR')),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isUpdating = false;
          _errorMessage = e.toString();
        });
      }
    }
  }
}
