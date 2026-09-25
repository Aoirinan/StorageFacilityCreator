import 'package:flutter/material.dart';
import 'package:sfcapp/utils/unit_areas.dart';

/// The Area text field: free text, suggesting the facility's existing areas
/// as the owner types (or all of them on an empty field).
class UnitAreaField extends StatefulWidget {
  const UnitAreaField({
    super.key,
    required this.controller,
    required this.existingAreas,
    this.helperText,
    this.autofocus = false,
    this.onSubmitted,
  });

  final TextEditingController controller;
  final List<String> existingAreas;
  final String? helperText;
  final bool autofocus;
  final VoidCallback? onSubmitted;

  @override
  State<UnitAreaField> createState() => _UnitAreaFieldState();
}

class _UnitAreaFieldState extends State<UnitAreaField> {
  final _focusNode = FocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RawAutocomplete<String>(
      textEditingController: widget.controller,
      focusNode: _focusNode,
      optionsBuilder: (value) {
        final query = value.text.trim().toLowerCase();
        return widget.existingAreas.where((area) =>
            area.toLowerCase().contains(query) &&
            area.toLowerCase() != query);
      },
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextFormField(
          key: const ValueKey('unit-area-field'),
          controller: controller,
          focusNode: focusNode,
          autofocus: widget.autofocus,
          maxLength: unitAreaMaxLength,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            labelText: 'Area',
            hintText: 'e.g., Complex 2, Outdoor Storage',
            prefixIcon: const Icon(Icons.place_outlined),
            helperText: widget.helperText,
            helperMaxLines: 2,
            counterText: '',
          ),
          onFieldSubmitted: (_) {
            onFieldSubmitted();
            widget.onSubmitted?.call();
          },
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 240, maxWidth: 400),
              child: ListView(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                children: [
                  for (final option in options)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.place_outlined, size: 18),
                      title: Text(option),
                      onTap: () => onSelected(option),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
