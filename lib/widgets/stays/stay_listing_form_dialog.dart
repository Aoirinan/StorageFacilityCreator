import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:sfcapp/models/stays/stay_enums.dart';
import 'package:sfcapp/models/stays/stay_listing.dart';
import 'package:sfcapp/models/stays/stays_callable_models.dart';
import 'package:sfcapp/providers/stays_providers.dart';
import 'package:sfcapp/services/stays/stays_display.dart';
import 'package:sfcapp/utils/request_id.dart';
import 'package:sfcapp/widgets/stays/stays_feedback.dart';

/// Adds a listing through staysSaveListing: a name, what it is, and an
/// optional nightly rate. Everything else (capacity, turnovers, access) keeps
/// its default and is edited later. Returns the saved listing, or null.
Future<StaysSaveListingResult?> showStayListingFormDialog(
  BuildContext context, {
  required String facilityId,
  List<StayListing> existing = const [],
}) =>
    showDialog<StaysSaveListingResult>(
      context: context,
      builder: (_) => StayListingFormDialog(facilityId: facilityId, existing: existing),
    );

class StayListingFormDialog extends ConsumerStatefulWidget {
  const StayListingFormDialog({super.key, required this.facilityId, this.existing = const []});

  final String facilityId;

  /// The facility's listings, for the next sort order and unique short codes.
  final List<StayListing> existing;

  @override
  ConsumerState<StayListingFormDialog> createState() => _StayListingFormDialogState();
}

class _StayListingFormDialogState extends ConsumerState<StayListingFormDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _shortCode = TextEditingController();
  final _rate = TextEditingController();

  /// One id per dialog: a retried save lands on the same listing.
  late final String _requestId = newRequestId();
  StayListingKind? _kind;
  bool _codeEdited = false;
  bool _saving = false;
  String? _error;

  Iterable<String> get _takenCodes => widget.existing.where((l) => !l.archived).map((l) => l.shortCode);

  @override
  void dispose() {
    _name.dispose();
    _shortCode.dispose();
    _rate.dispose();
    super.dispose();
  }

  void _nameChanged(String value) {
    if (_codeEdited) return;
    _shortCode.text = value.trim().isEmpty ? '' : suggestShortCode(value, _takenCodes);
  }

  Future<void> _save() async {
    if (_saving) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final kind = _kind!;
    final listing = StayListing(
      id: '',
      facilityId: widget.facilityId,
      name: _name.text.trim(),
      shortCode: _shortCode.text.trim(),
      kind: kind,
      sortOrder: widget.existing.length,
      active: true,
      rates: StayListingRates(nightly: parseDollarsToCents(_rate.text) ?? 0),
    );
    try {
      final result = await ref.read(staysCallablesProvider).saveListing(StaysSaveListingRequest(
            facilityId: widget.facilityId,
            requestId: _requestId,
            listing: listing.toInputMap(),
          ));
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = staysErrorMessage(e);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add a listing'),
      content: SizedBox(
        width: 420,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  key: const Key('stay-listing-name'),
                  controller: _name,
                  autofocus: true,
                  maxLength: 80,
                  decoration: const InputDecoration(labelText: 'Name', hintText: 'e.g. Blue House, Cabin 2, RV 3'),
                  onChanged: _nameChanged,
                  validator: (v) => (v ?? '').trim().isEmpty ? 'Give the listing a name' : null,
                ),
                const SizedBox(height: 8),
                DropdownButtonFormField<StayListingKind>(
                  key: const Key('stay-listing-kind'),
                  initialValue: _kind,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'What is it?'),
                  items: [
                    for (final k in setupListingKinds) DropdownMenuItem(value: k, child: Text(listingKindLabel(k))),
                  ],
                  onChanged: (k) => setState(() => _kind = k),
                  validator: (k) => k == null ? 'Pick what kind of listing this is' : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  key: const Key('stay-listing-code'),
                  controller: _shortCode,
                  maxLength: 8,
                  decoration: const InputDecoration(
                    labelText: 'Short code',
                    helperText: 'Shown on the calendar. Must be different for each listing.',
                  ),
                  onChanged: (_) => _codeEdited = true,
                  validator: (v) {
                    final code = (v ?? '').trim();
                    if (code.isEmpty) return 'Give it a short code, e.g. C2';
                    final taken = _takenCodes.any((t) => t.trim().toLowerCase() == code.toLowerCase());
                    return taken ? 'Another listing already uses $code' : null;
                  },
                ),
                const SizedBox(height: 8),
                TextFormField(
                  key: const Key('stay-listing-rate'),
                  controller: _rate,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Nightly rate (optional)',
                    prefixText: r'$ ',
                    helperText: 'For your own bookings. Airbnb keeps its own prices.',
                  ),
                  validator: (v) {
                    try {
                      parseDollarsToCents(v ?? '');
                      return null;
                    } on FormatException catch (e) {
                      return e.message;
                    }
                  },
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const Key('stay-listing-save'),
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
              : const Text('Add listing'),
        ),
      ],
    );
  }
}
