import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../models/team_note_model.dart';
import '../services/team_notes_service.dart';
import '../theme/app_theme.dart';

/// Shared team notes for a facility (readable by all staff per Firestore rules).
class TeamNotesPanel extends StatefulWidget {
  final String facilityId;
  final bool compact;
  /// When false, only the composer and list are shown (e.g. dialog with its own title).
  final bool showHeader;
  /// When false, no right border (e.g. embedded in a dialog).
  final bool showTrailingBorder;

  const TeamNotesPanel({
    super.key,
    required this.facilityId,
    this.compact = false,
    this.showHeader = true,
    this.showTrailingBorder = true,
  });

  @override
  State<TeamNotesPanel> createState() => _TeamNotesPanelState();
}

class _TeamNotesPanelState extends State<TeamNotesPanel> {
  final TextEditingController _newNoteController = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _newNoteController.dispose();
    super.dispose();
  }

  Future<void> _submitNew() async {
    if (widget.facilityId.isEmpty || widget.facilityId == 'all') return;
    final text = _newNoteController.text.trim();
    if (text.isEmpty) return;
    setState(() => _submitting = true);
    try {
      await TeamNotesService.addNote(facilityId: widget.facilityId, body: text);
      _newNoteController.clear();
      if (mounted) {
        FocusScope.of(context).unfocus();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Note added')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not save note: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _editNote(TeamNoteModel note) async {
    final controller = TextEditingController(text: note.body);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Edit note'),
        content: TextField(
          controller: controller,
          maxLines: 8,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            alignLabelWithHint: true,
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Save')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await TeamNotesService.updateNote(
        facilityId: widget.facilityId,
        noteId: note.id,
        body: controller.text,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not update: $e'), backgroundColor: AppTheme.error),
        );
      }
    } finally {
      controller.dispose();
    }
  }

  Future<void> _confirmDelete(TeamNoteModel note) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete note?'),
        content: const Text('This removes the note for everyone at the facility.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await TeamNotesService.deleteNote(facilityId: widget.facilityId, noteId: note.id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not delete: $e'), backgroundColor: AppTheme.error),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    if (widget.facilityId.isEmpty || widget.facilityId == 'all') {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Select a facility to use team notes.',
            textAlign: TextAlign.center,
            style: TextStyle(color: cs.onSurfaceVariant),
          ),
        ),
      );
    }

    final uid = FirebaseAuth.instance.currentUser?.uid ?? '';

    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border: widget.showTrailingBorder
            ? Border(right: BorderSide(color: cs.outline))
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.showHeader)
            Container(
              padding: EdgeInsets.all(widget.compact ? 12 : 16),
              decoration: BoxDecoration(
                color: cs.surfaceContainerHighest,
                border: Border(bottom: BorderSide(color: cs.outline)),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.note_alt_outlined, color: cs.primary, size: 22),
                      const SizedBox(width: 8),
                      Text(
                        'Team notes',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              fontWeight: FontWeight.bold,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Shared with everyone who can access this facility.',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                  ),
                ],
              ),
            ),
          Padding(
            padding: EdgeInsets.all(widget.compact ? 8 : 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: _newNoteController,
                  maxLines: widget.compact ? 2 : 3,
                  maxLength: TeamNotesService.maxBodyLength,
                  decoration: InputDecoration(
                    hintText: 'Add a note for your team…',
                    border: const OutlineInputBorder(),
                    isDense: widget.compact,
                    counterText: '',
                  ),
                ),
                const SizedBox(height: 8),
                FilledButton.icon(
                  onPressed: _submitting ? null : _submitNew,
                  icon: _submitting
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                        )
                      : const Icon(Icons.add, size: 20),
                  label: Text(_submitting ? 'Saving…' : 'Add note'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.primaryBlue,
                    foregroundColor: AppTheme.textOnDark,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: StreamBuilder<List<TeamNoteModel>>(
              stream: TeamNotesService.watchNotes(widget.facilityId),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'Could not load notes.\n${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: AppTheme.error),
                      ),
                    ),
                  );
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final notes = snapshot.data!;
                if (notes.isEmpty) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        'No notes yet. Add one above.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: cs.onSurfaceVariant),
                      ),
                    ),
                  );
                }
                return ListView.separated(
                  padding: EdgeInsets.fromLTRB(12, 0, 12, widget.compact ? 12 : 16),
                  itemCount: notes.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, index) {
                    final note = notes[index];
                    final mine = note.createdByUid == uid;
                    final who = mine
                        ? 'You'
                        : (note.createdByDisplayName?.trim().isNotEmpty == true
                            ? note.createdByDisplayName!
                            : 'Teammate');
                    return Material(
                      color: cs.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      child: InkWell(
                        onTap: () => _editNote(note),
                        borderRadius: BorderRadius.circular(8),
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Expanded(
                                    child: Text(
                                      note.body,
                                      style: Theme.of(context).textTheme.bodyMedium,
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, size: 20),
                                    onPressed: () => _confirmDelete(note),
                                    tooltip: 'Delete',
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              Text(
                                '$who · ${_formatTime(note.updatedAt)} · tap to edit',
                                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                                      color: cs.onSurfaceVariant,
                                    ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  String _formatTime(DateTime t) {
    final local = t.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}
