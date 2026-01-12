import 'package:flutter/material.dart';
import '../models/unit_model.dart';
import '../theme/app_theme.dart';

class MapSearchBar extends StatefulWidget {
  final List<UnitModel> units;
  final ValueChanged<UnitModel?> onUnitSelected;
  final VoidCallback? onClear;

  const MapSearchBar({
    super.key,
    required this.units,
    required this.onUnitSelected,
    this.onClear,
  });

  @override
  State<MapSearchBar> createState() => _MapSearchBarState();
}

class _MapSearchBarState extends State<MapSearchBar> {
  final TextEditingController _searchController = TextEditingController();
  List<UnitModel> _filteredUnits = [];
  bool _showResults = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.toLowerCase();
    if (query.isEmpty) {
      setState(() {
        _filteredUnits = [];
        _showResults = false;
      });
      return;
    }

    setState(() {
      _filteredUnits = widget.units.where((unit) {
        return unit.unitNumber.toLowerCase().contains(query) ||
            (unit.tenantName != null && unit.tenantName!.toLowerCase().contains(query));
      }).toList();
      _showResults = true;
    });
  }

  void _selectUnit(UnitModel unit) {
    _searchController.clear();
    setState(() {
      _showResults = false;
    });
    widget.onUnitSelected(unit);
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() {
      _showResults = false;
    });
    widget.onUnitSelected(null);
    widget.onClear?.call();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _searchController,
            decoration: InputDecoration(
              hintText: 'Search units by number or tenant name...',
              prefixIcon: const Icon(Icons.search),
              suffixIcon: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear),
                      onPressed: _clearSearch,
                    )
                  : null,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              filled: true,
              fillColor: Colors.white,
            ),
          ),
          if (_showResults && _filteredUnits.isNotEmpty)
            Container(
              constraints: const BoxConstraints(maxHeight: 200),
              margin: const EdgeInsets.only(top: 4),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.1),
                    blurRadius: 4,
                    spreadRadius: 1,
                  ),
                ],
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: _filteredUnits.length,
                itemBuilder: (context, index) {
                  final unit = _filteredUnits[index];
                  return ListTile(
                    dense: true,
                    title: Text(unit.unitNumber),
                    subtitle: unit.tenantName != null
                        ? Text('Tenant: ${unit.tenantName}')
                        : Text('Status: ${unit.statusDisplayName}'),
                    trailing: Text(
                      '\$${unit.monthlyRate.toStringAsFixed(2)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primaryBlue,
                      ),
                    ),
                    onTap: () => _selectUnit(unit),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

