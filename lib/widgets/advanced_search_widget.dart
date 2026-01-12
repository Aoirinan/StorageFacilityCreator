import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/advanced_search_filter_model.dart';
import '../services/advanced_search_service.dart';
import '../theme/app_theme.dart';
import '../providers/auth_provider.dart';
import '../providers/facility_provider.dart';

/// Advanced search widget/dialog
class AdvancedSearchWidget extends ConsumerStatefulWidget {
  final String? facilityId;
  final Function(List<Map<String, dynamic>> results)? onResults;

  const AdvancedSearchWidget({
    super.key,
    this.facilityId,
    this.onResults,
  });

  @override
  ConsumerState<AdvancedSearchWidget> createState() => _AdvancedSearchWidgetState();
}

class _AdvancedSearchWidgetState extends ConsumerState<AdvancedSearchWidget> {
  SearchEntityType _selectedEntityType = SearchEntityType.tenants;
  final List<SearchFilter> _filters = [];
  String? _sortBy;
  bool _sortDescending = false;
  bool _isSearching = false;
  List<Map<String, dynamic>> _results = [];

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 800,
        height: 700,
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            // Header
            Row(
              children: [
                const Icon(Icons.search, size: 28, color: AppTheme.primaryBlue),
                const SizedBox(width: 12),
                const Expanded(
                  child: Text(
                    'Advanced Search',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
            const Divider(height: 32),
            // Entity Type Selector
            _buildEntityTypeSelector(),
            const SizedBox(height: 24),
            // Filters
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Filter Builder
                  Expanded(
                    flex: 2,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Text(
                              'Filters',
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            TextButton.icon(
                              icon: const Icon(Icons.add),
                              label: const Text('Add Filter'),
                              onPressed: _addFilter,
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Expanded(
                          child: _filters.isEmpty
                              ? Center(
                                  child: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      Icon(
                                        Icons.filter_list_outlined,
                                        size: 64,
                                        color: AppTheme.textTertiary,
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        'No filters added',
                                        style: TextStyle(
                                          color: AppTheme.textSecondary,
                                          fontSize: 16,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      ElevatedButton.icon(
                                        icon: const Icon(Icons.add),
                                        label: const Text('Add Your First Filter'),
                                        onPressed: _addFilter,
                                      ),
                                    ],
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: _filters.length,
                                  itemBuilder: (context, index) {
                                    return _buildFilterCard(_filters[index], index);
                                  },
                                ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  // Sort & Search
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Sort & Options',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _buildSortOptions(),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            icon: _isSearching
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : const Icon(Icons.search),
                            label: Text(_isSearching ? 'Searching...' : 'Search'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppTheme.primaryBlue,
                              foregroundColor: AppTheme.textOnDark,
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                            onPressed: _isSearching ? null : _performSearch,
                          ),
                        ),
                        if (_results.isNotEmpty) ...[
                          const SizedBox(height: 24),
                          const Text(
                            'Results',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Expanded(
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(color: AppTheme.borderLight),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: ListView.builder(
                                itemCount: _results.length,
                                itemBuilder: (context, index) {
                                  return _buildResultItem(_results[index]);
                                },
                              ),
                            ),
                          ),
                        ],
                      ],
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

  Widget _buildEntityTypeSelector() {
    return SegmentedButton<SearchEntityType>(
      segments: [
        const ButtonSegment(
          value: SearchEntityType.tenants,
          label: Text('Tenants'),
          icon: Icon(Icons.people),
        ),
        const ButtonSegment(
          value: SearchEntityType.units,
          label: Text('Units'),
          icon: Icon(Icons.home),
        ),
        const ButtonSegment(
          value: SearchEntityType.facilities,
          label: Text('Facilities'),
          icon: Icon(Icons.business),
        ),
        const ButtonSegment(
          value: SearchEntityType.all,
          label: Text('All'),
          icon: Icon(Icons.search),
        ),
      ],
      selected: {_selectedEntityType},
      onSelectionChanged: (Set<SearchEntityType> selected) {
        setState(() {
          _selectedEntityType = selected.first;
          _filters.clear(); // Clear filters when changing entity type
        });
      },
    );
  }

  Widget _buildSortOptions() {
    final sortFields = _getSortFieldsForEntityType(_selectedEntityType);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          value: _sortBy,
          decoration: const InputDecoration(
            labelText: 'Sort By',
            border: OutlineInputBorder(),
          ),
          items: [
            const DropdownMenuItem<String>(
              value: null,
              child: Text('No Sorting'),
            ),
            ...sortFields.map((field) {
              return DropdownMenuItem<String>(
                value: field['value'],
                child: Text(field['label']),
              );
            }),
          ],
          onChanged: (value) {
            setState(() {
              _sortBy = value;
            });
          },
        ),
        if (_sortBy != null) ...[
          const SizedBox(height: 12),
          SwitchListTile(
            title: const Text('Descending'),
            value: _sortDescending,
            onChanged: (value) {
              setState(() {
                _sortDescending = value;
              });
            },
          ),
        ],
      ],
    );
  }

  List<Map<String, String>> _getSortFieldsForEntityType(SearchEntityType type) {
    switch (type) {
      case SearchEntityType.tenants:
        return [
          {'value': 'name', 'label': 'Name'},
          {'value': 'unitNumber', 'label': 'Unit Number'},
          {'value': 'monthlyRate', 'label': 'Monthly Rate'},
          {'value': 'email', 'label': 'Email'},
        ];
      case SearchEntityType.units:
        return [
          {'value': 'unitNumber', 'label': 'Unit Number'},
          {'value': 'monthlyRate', 'label': 'Monthly Rate'},
          {'value': 'status', 'label': 'Status'},
        ];
      case SearchEntityType.facilities:
        return [
          {'value': 'name', 'label': 'Name'},
          {'value': 'address', 'label': 'Address'},
        ];
      default:
        return [];
    }
  }

  void _addFilter() {
    showDialog(
      context: context,
      builder: (context) => _FilterDialog(
        entityType: _selectedEntityType,
        onFilterAdded: (filter) {
          setState(() {
            _filters.add(filter);
          });
        },
      ),
    );
  }

  Widget _buildFilterCard(SearchFilter filter, int index) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ListTile(
        title: Text(
          _getFilterDisplayText(filter),
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        subtitle: Text(_getFilterOperatorText(filter.operator)),
        trailing: IconButton(
          icon: const Icon(Icons.delete, color: AppTheme.error),
          onPressed: () {
            setState(() {
              _filters.removeAt(index);
            });
          },
        ),
        onTap: () {
          // Edit filter
          showDialog(
            context: context,
            builder: (context) => _FilterDialog(
              entityType: _selectedEntityType,
              existingFilter: filter,
              onFilterAdded: (updatedFilter) {
                setState(() {
                  _filters[index] = updatedFilter;
                });
              },
            ),
          );
        },
      ),
    );
  }

  String _getFilterDisplayText(SearchFilter filter) {
    final fieldLabel = _getFieldLabel(filter.field);
    return '$fieldLabel: ${filter.value}';
  }

  String _getFieldLabel(String field) {
    // Map field names to display labels
    final labels = {
      'name': 'Name',
      'email': 'Email',
      'phone': 'Phone',
      'unitNumber': 'Unit Number',
      'monthlyRate': 'Monthly Rate',
      'status': 'Status',
      'isActive': 'Active',
      'leadSource': 'Lead Source',
    };
    return labels[field] ?? field;
  }

  String _getFilterOperatorText(FilterOperator operator) {
    switch (operator) {
      case FilterOperator.equals:
        return 'Equals';
      case FilterOperator.contains:
        return 'Contains';
      case FilterOperator.startsWith:
        return 'Starts With';
      case FilterOperator.greaterThan:
        return 'Greater Than';
      case FilterOperator.lessThan:
        return 'Less Than';
      case FilterOperator.between:
        return 'Between';
      case FilterOperator.inList:
        return 'In List';
    }
  }

  Widget _buildResultItem(Map<String, dynamic> result) {
    final entityType = result['entityType'] as String;
    final name = result['name'] ?? result['unitNumber'] ?? 'Unknown';

    return ListTile(
      leading: Icon(_getEntityIcon(entityType)),
      title: Text(name),
      subtitle: _buildResultSubtitle(result),
      onTap: () {
        widget.onResults?.call(_results);
        Navigator.of(context).pop();
      },
    );
  }

  Widget _buildResultSubtitle(Map<String, dynamic> result) {
    final entityType = result['entityType'] as String;
    switch (entityType) {
      case 'tenant':
        return Text('${result['unitNumber']} • ${result['email']}');
      case 'unit':
        return Text('${result['status']} • \$${result['monthlyRate']}');
      case 'facility':
        return Text(result['address'] ?? '');
      default:
        return const Text('');
    }
  }

  IconData _getEntityIcon(String entityType) {
    switch (entityType) {
      case 'tenant':
        return Icons.person;
      case 'unit':
        return Icons.home;
      case 'facility':
        return Icons.business;
      default:
        return Icons.search;
    }
  }

  Future<void> _performSearch() async {
    final authState = ref.read(authStateProvider);
    final user = authState.valueOrNull;
    if (user == null) return;

    setState(() {
      _isSearching = true;
      _results = [];
    });

    try {
      final criteria = AdvancedSearchCriteria(
        entityType: _selectedEntityType,
        filters: _filters,
        facilityId: widget.facilityId,
        sortBy: _sortBy,
        sortDescending: _sortDescending,
        limit: 100,
      );

      final results = await AdvancedSearchService.search(
        criteria: criteria,
        ownerUid: user.uid,
      );

      setState(() {
        _results = results;
        _isSearching = false;
      });

      widget.onResults?.call(results);
    } catch (e) {
      setState(() {
        _isSearching = false;
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Search error: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }
}

/// Dialog for creating/editing a filter
class _FilterDialog extends StatefulWidget {
  final SearchEntityType entityType;
  final SearchFilter? existingFilter;
  final Function(SearchFilter) onFilterAdded;

  const _FilterDialog({
    required this.entityType,
    this.existingFilter,
    required this.onFilterAdded,
  });

  @override
  State<_FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<_FilterDialog> {
  late String _selectedField;
  late FilterOperator _selectedOperator;
  String? _textValue;
  double? _numberValue;
  DateTime? _dateValue;
  DateTime? _dateValue2;

  @override
  void initState() {
    super.initState();
    final fields = _getAvailableFields();
    _selectedField = widget.existingFilter?.field ?? fields.first;
    _selectedOperator = widget.existingFilter?.operator ?? FilterOperator.contains;
    _initializeValues();
  }

  void _initializeValues() {
    if (widget.existingFilter != null) {
      final filter = widget.existingFilter!;
      if (filter.value is String) {
        _textValue = filter.value as String;
      } else if (filter.value is num) {
        _numberValue = (filter.value as num).toDouble();
      } else if (filter.value is DateTime || filter.value is Timestamp) {
        _dateValue = filter.value is DateTime
            ? filter.value as DateTime
            : (filter.value as Timestamp).toDate();
        if (filter.value2 != null) {
          _dateValue2 = filter.value2 is DateTime
              ? filter.value2 as DateTime
              : (filter.value2 as Timestamp).toDate();
        }
      }
    }
  }

  List<String> _getAvailableFields() {
    switch (widget.entityType) {
      case SearchEntityType.tenants:
        return ['name', 'email', 'phone', 'unitNumber', 'monthlyRate', 'isActive', 'leadSource'];
      case SearchEntityType.units:
        return ['unitNumber', 'status', 'monthlyRate', 'tenantName'];
      case SearchEntityType.facilities:
        return ['name', 'address'];
      default:
        return ['name'];
    }
  }

  bool get _isNumberField {
    return _selectedField == 'monthlyRate';
  }

  bool get _isDateField {
    return _selectedField.contains('Date') || _selectedField.contains('date');
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existingFilter == null ? 'Add Filter' : 'Edit Filter'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DropdownButtonFormField<String>(
              value: _selectedField,
              decoration: const InputDecoration(labelText: 'Field'),
              items: _getAvailableFields().map((field) {
                return DropdownMenuItem(
                  value: field,
                  child: Text(_getFieldLabel(field)),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _selectedField = value;
                    _textValue = null;
                    _numberValue = null;
                    _dateValue = null;
                    _dateValue2 = null;
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<FilterOperator>(
              value: _selectedOperator,
              decoration: const InputDecoration(labelText: 'Operator'),
              items: _getAvailableOperators().map((op) {
                return DropdownMenuItem(
                  value: op,
                  child: Text(_getOperatorLabel(op)),
                );
              }).toList(),
              onChanged: (value) {
                if (value != null) {
                  setState(() {
                    _selectedOperator = value;
                  });
                }
              },
            ),
            const SizedBox(height: 16),
            if (_isDateField)
              _buildDateInput()
            else if (_isNumberField)
              _buildNumberInput()
            else
              _buildTextInput(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _saveFilter,
          child: const Text('Save'),
        ),
      ],
    );
  }

  Widget _buildTextInput() {
    return TextFormField(
      initialValue: _textValue,
      decoration: const InputDecoration(labelText: 'Value'),
      onChanged: (value) {
        setState(() {
          _textValue = value;
        });
      },
    );
  }

  Widget _buildNumberInput() {
    return TextFormField(
      initialValue: _numberValue?.toString(),
      decoration: const InputDecoration(labelText: 'Value'),
      keyboardType: TextInputType.number,
      onChanged: (value) {
        setState(() {
          _numberValue = double.tryParse(value);
        });
      },
    );
  }

  Widget _buildDateInput() {
    return Column(
      children: [
        ListTile(
          title: Text(_dateValue != null
              ? DateFormat('MM/dd/yyyy').format(_dateValue!)
              : 'Select Date'),
          trailing: const Icon(Icons.calendar_today),
          onTap: () async {
            final date = await showDatePicker(
              context: context,
              initialDate: _dateValue ?? DateTime.now(),
              firstDate: DateTime(2000),
              lastDate: DateTime(2100),
            );
            if (date != null) {
              setState(() {
                _dateValue = date;
              });
            }
          },
        ),
        if (_selectedOperator == FilterOperator.between)
          ListTile(
            title: Text(_dateValue2 != null
                ? DateFormat('MM/dd/yyyy').format(_dateValue2!)
                : 'Select End Date'),
            trailing: const Icon(Icons.calendar_today),
            onTap: () async {
              final date = await showDatePicker(
                context: context,
                initialDate: _dateValue2 ?? _dateValue ?? DateTime.now(),
                firstDate: _dateValue ?? DateTime(2000),
                lastDate: DateTime(2100),
              );
              if (date != null) {
                setState(() {
                  _dateValue2 = date;
                });
              }
            },
          ),
      ],
    );
  }

  List<FilterOperator> _getAvailableOperators() {
    if (_isDateField || _isNumberField) {
      return [
        FilterOperator.equals,
        FilterOperator.greaterThan,
        FilterOperator.lessThan,
        FilterOperator.between,
      ];
    }
    return [
      FilterOperator.equals,
      FilterOperator.contains,
      FilterOperator.startsWith,
    ];
  }

  String _getOperatorLabel(FilterOperator op) {
    switch (op) {
      case FilterOperator.equals:
        return 'Equals';
      case FilterOperator.contains:
        return 'Contains';
      case FilterOperator.startsWith:
        return 'Starts With';
      case FilterOperator.greaterThan:
        return 'Greater Than';
      case FilterOperator.lessThan:
        return 'Less Than';
      case FilterOperator.between:
        return 'Between';
      case FilterOperator.inList:
        return 'In List';
    }
  }

  String _getFieldLabel(String field) {
    final labels = {
      'name': 'Name',
      'email': 'Email',
      'phone': 'Phone',
      'unitNumber': 'Unit Number',
      'monthlyRate': 'Monthly Rate',
      'status': 'Status',
      'isActive': 'Active',
      'leadSource': 'Lead Source',
      'tenantName': 'Tenant Name',
      'address': 'Address',
    };
    return labels[field] ?? field;
  }

  void _saveFilter() {
    dynamic value;
    if (_isDateField) {
      if (_dateValue == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please select a date')),
        );
        return;
      }
      value = _dateValue;
    } else if (_isNumberField) {
      if (_numberValue == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter a number')),
        );
        return;
      }
      value = _numberValue;
    } else {
      if (_textValue == null || _textValue!.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter a value')),
        );
        return;
      }
      value = _textValue;
    }

    final filter = SearchFilter(
      field: _selectedField,
      operator: _selectedOperator,
      value: value,
      value2: _selectedOperator == FilterOperator.between ? _dateValue2 : null,
    );

    widget.onFilterAdded(filter);
    Navigator.of(context).pop();
  }
}

