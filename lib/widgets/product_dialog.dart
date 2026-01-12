import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/product_model.dart';
import '../services/inventory_service.dart';
import '../theme/app_theme.dart';

class ProductDialog extends StatefulWidget {
  final String facilityId;
  final ProductModel? product; // If provided, we're editing; otherwise, adding
  final VoidCallback onSaved;

  const ProductDialog({
    super.key,
    required this.facilityId,
    this.product,
    required this.onSaved,
  });

  @override
  State<ProductDialog> createState() => _ProductDialogState();
}

class _ProductDialogState extends State<ProductDialog> {
  final _formKey = GlobalKey<FormState>();
  late TextEditingController _nameController;
  late TextEditingController _descriptionController;
  late TextEditingController _skuController;
  late TextEditingController _priceController;
  late TextEditingController _costController;
  late TextEditingController _stockQuantityController;
  late TextEditingController _lowStockThresholdController;
  late TextEditingController _unitController;

  ProductCategory _selectedCategory = ProductCategory.other;
  bool _trackInventory = true;
  bool _isActive = true;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    final product = widget.product;
    _nameController = TextEditingController(text: product?.name ?? '');
    _descriptionController = TextEditingController(text: product?.description ?? '');
    _skuController = TextEditingController(text: product?.sku ?? '');
    _priceController = TextEditingController(text: product?.price.toStringAsFixed(2) ?? '0.00');
    _costController = TextEditingController(text: product?.cost?.toStringAsFixed(2) ?? '');
    _stockQuantityController = TextEditingController(text: product?.stockQuantity.toString() ?? '0');
    _lowStockThresholdController = TextEditingController(text: product?.lowStockThreshold?.toString() ?? '');
    _unitController = TextEditingController(text: product?.unit ?? 'each');
    _selectedCategory = product?.category ?? ProductCategory.other;
    _trackInventory = product?.trackInventory ?? true;
    _isActive = product?.isActive ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _skuController.dispose();
    _priceController.dispose();
    _costController.dispose();
    _stockQuantityController.dispose();
    _lowStockThresholdController.dispose();
    _unitController.dispose();
    super.dispose();
  }

  Future<void> _saveProduct() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isSaving = true;
    });

    try {
      final price = double.tryParse(_priceController.text) ?? 0.0;
      final cost = _costController.text.isNotEmpty
          ? double.tryParse(_costController.text)
          : null;
      final stockQuantity = int.tryParse(_stockQuantityController.text) ?? 0;
      final lowStockThreshold = _lowStockThresholdController.text.isNotEmpty
          ? int.tryParse(_lowStockThresholdController.text)
          : null;

      if (widget.product != null) {
        // Update existing product
        await InventoryService.updateProduct(
          facilityId: widget.facilityId,
          productId: widget.product!.id,
          name: _nameController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          sku: _skuController.text.trim().isEmpty
              ? null
              : _skuController.text.trim(),
          category: _selectedCategory,
          price: price,
          cost: cost,
          stockQuantity: stockQuantity,
          lowStockThreshold: lowStockThreshold,
          unit: _unitController.text.trim(),
          trackInventory: _trackInventory,
          isActive: _isActive,
        );
      } else {
        // Create new product
        await InventoryService.createProduct(
          facilityId: widget.facilityId,
          name: _nameController.text.trim(),
          description: _descriptionController.text.trim().isEmpty
              ? null
              : _descriptionController.text.trim(),
          sku: _skuController.text.trim().isEmpty
              ? null
              : _skuController.text.trim(),
          category: _selectedCategory,
          price: price,
          cost: cost,
          stockQuantity: stockQuantity,
          lowStockThreshold: lowStockThreshold,
          unit: _unitController.text.trim(),
          trackInventory: _trackInventory,
        );
      }

      if (mounted) {
        widget.onSaved();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.product != null
                ? 'Product updated successfully'
                : 'Product created successfully'),
            backgroundColor: AppTheme.success,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error saving product: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      child: Container(
        width: 600,
        constraints: const BoxConstraints(maxHeight: 700),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                color: AppTheme.primaryBlue,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    widget.product != null ? Icons.edit : Icons.add,
                    color: Colors.white,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.product != null ? 'Edit Product' : 'Add Product',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            // Form
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Form(
                  key: _formKey,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Name
                      TextFormField(
                        controller: _nameController,
                        decoration: const InputDecoration(
                          labelText: 'Product Name *',
                          border: OutlineInputBorder(),
                        ),
                        validator: (value) {
                          if (value == null || value.trim().isEmpty) {
                            return 'Product name is required';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 16),
                      // Description
                      TextFormField(
                        controller: _descriptionController,
                        decoration: const InputDecoration(
                          labelText: 'Description',
                          border: OutlineInputBorder(),
                        ),
                        maxLines: 3,
                      ),
                      const SizedBox(height: 16),
                      // SKU
                      TextFormField(
                        controller: _skuController,
                        decoration: const InputDecoration(
                          labelText: 'SKU',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      const SizedBox(height: 16),
                      // Category
                      DropdownButtonFormField<ProductCategory>(
                        value: _selectedCategory,
                        decoration: const InputDecoration(
                          labelText: 'Category *',
                          border: OutlineInputBorder(),
                        ),
                        items: ProductCategory.values.map((category) {
                          return DropdownMenuItem(
                            value: category,
                            child: Text(_getCategoryLabel(category)),
                          );
                        }).toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              _selectedCategory = value;
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      // Price and Cost
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              controller: _priceController,
                              decoration: const InputDecoration(
                                labelText: 'Price *',
                                prefixText: '\$',
                                border: OutlineInputBorder(),
                              ),
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
                              ],
                              validator: (value) {
                                if (value == null || value.isEmpty) {
                                  return 'Price is required';
                                }
                                final price = double.tryParse(value);
                                if (price == null || price <= 0) {
                                  return 'Price must be greater than 0';
                                }
                                return null;
                              },
                            ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: TextFormField(
                              controller: _costController,
                              decoration: const InputDecoration(
                                labelText: 'Cost (optional)',
                                prefixText: '\$',
                                border: OutlineInputBorder(),
                              ),
                              keyboardType: const TextInputType.numberWithOptions(decimal: true),
                              inputFormatters: [
                                FilteringTextInputFormatter.allow(RegExp(r'^\d+\.?\d{0,2}')),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Track Inventory Toggle
                      SwitchListTile(
                        title: const Text('Track Inventory'),
                        subtitle: const Text('Enable stock quantity tracking'),
                        value: _trackInventory,
                        onChanged: (value) {
                          setState(() {
                            _trackInventory = value;
                          });
                        },
                      ),
                      if (_trackInventory) ...[
                        const SizedBox(height: 16),
                        // Stock Quantity and Low Stock Threshold
                        Row(
                          children: [
                            Expanded(
                              child: TextFormField(
                                controller: _stockQuantityController,
                                decoration: const InputDecoration(
                                  labelText: 'Stock Quantity *',
                                  border: OutlineInputBorder(),
                                ),
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                                validator: (value) {
                                  if (_trackInventory) {
                                    if (value == null || value.isEmpty) {
                                      return 'Stock quantity is required';
                                    }
                                    final qty = int.tryParse(value);
                                    if (qty == null || qty < 0) {
                                      return 'Stock quantity must be 0 or greater';
                                    }
                                  }
                                  return null;
                                },
                              ),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: TextFormField(
                                controller: _lowStockThresholdController,
                                decoration: const InputDecoration(
                                  labelText: 'Low Stock Threshold',
                                  border: OutlineInputBorder(),
                                ),
                                keyboardType: TextInputType.number,
                                inputFormatters: [
                                  FilteringTextInputFormatter.digitsOnly,
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                      const SizedBox(height: 16),
                      // Unit
                      TextFormField(
                        controller: _unitController,
                        decoration: const InputDecoration(
                          labelText: 'Unit (e.g., each, box, pack)',
                          border: OutlineInputBorder(),
                        ),
                      ),
                      if (widget.product != null) ...[
                        const SizedBox(height: 16),
                        // Active Toggle (only for existing products)
                        SwitchListTile(
                          title: const Text('Active'),
                          subtitle: const Text('Product is available for sale'),
                          value: _isActive,
                          onChanged: (value) {
                            setState(() {
                              _isActive = value;
                            });
                          },
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            // Footer
            Container(
              padding: const EdgeInsets.all(16.0),
              decoration: BoxDecoration(
                color: AppTheme.backgroundLight,
                border: Border(top: BorderSide(color: AppTheme.borderLight)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: _isSaving ? null : _saveProduct,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primaryBlue,
                      foregroundColor: Colors.white,
                    ),
                    child: _isSaving
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : Text(widget.product != null ? 'Update' : 'Create'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _getCategoryLabel(ProductCategory category) {
    switch (category) {
      case ProductCategory.locks:
        return 'Locks';
      case ProductCategory.boxes:
        return 'Boxes';
      case ProductCategory.packingSupplies:
        return 'Packing Supplies';
      case ProductCategory.movingSupplies:
        return 'Moving Supplies';
      case ProductCategory.other:
        return 'Other';
    }
  }
}

