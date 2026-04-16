import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/product_model.dart';
import '../models/facility_model.dart';
import '../providers/facility_provider.dart';
import '../providers/auth_provider.dart';
import '../services/facility_creator_account_service.dart';
import '../services/inventory_service.dart';
import '../theme/app_theme.dart';
import '../router/app_route.dart';
import '../widgets/product_dialog.dart';

/// Provider for products stream (by facility)
final productsForFacilityProvider = StreamProvider.family<List<ProductModel>, String>((ref, facilityId) {
  return InventoryService.getProductsForFacilityStream(facilityId);
});

class InventoryListScreen extends ConsumerStatefulWidget {
  /// When set (e.g. deep link from POS), selects this facility if the user has access.
  final String? initialFacilityId;

  const InventoryListScreen({super.key, this.initialFacilityId});

  @override
  ConsumerState<InventoryListScreen> createState() => _InventoryListScreenState();
}

class _InventoryListScreenState extends ConsumerState<InventoryListScreen> {
  String _selectedFacilityId = '';
  ProductCategory? _categoryFilter;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _loadUserFacilities();
  }

  Future<void> _loadUserFacilities() async {
    try {
      final authState = ref.read(authStateProvider);
      if (authState.hasValue && authState.value != null) {
        final user = authState.value!;
        
        try {
          await FacilityCreatorAccountService.getOrCreateAccountForCurrentUser();
        } catch (accountError) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Account setup error: $accountError'),
                backgroundColor: AppTheme.warning,
              ),
            );
            return;
          }
        }
        
        await Future.delayed(const Duration(milliseconds: 500));
        
        final facilitiesAsync = await ref.read(userFacilitiesProvider(user.uid).future);
        final facilities = facilitiesAsync as List<FacilityModel>? ?? <FacilityModel>[];
        if (facilities.isNotEmpty) {
          setState(() {
            final initial = widget.initialFacilityId;
            if (initial != null &&
                initial.isNotEmpty &&
                facilities.any((f) => f.id == initial)) {
              _selectedFacilityId = initial;
            } else {
              _selectedFacilityId = facilities.first.id;
            }
          });
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading facilities: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: cs.surface,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Row(
              children: [
                Text(
                  'Inventory',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: cs.onSurface,
                      ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.point_of_sale_outlined),
                  onPressed: _selectedFacilityId.isEmpty
                      ? null
                      : () => context.go(
                            Uri(
                              path: AppRoute.pos,
                              queryParameters: {'facilityId': _selectedFacilityId},
                            ).toString(),
                          ),
                  tooltip: 'Open POS',
                ),
                IconButton(
                  icon: const Icon(Icons.receipt_long_outlined),
                  onPressed: _selectedFacilityId.isEmpty
                      ? null
                      : () => context.go(
                            Uri(
                              path: AppRoute.retailSales,
                              queryParameters: {'facilityId': _selectedFacilityId},
                            ).toString(),
                          ),
                  tooltip: 'View Sales History',
                ),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () => _showAddProductDialog(),
                  tooltip: 'Add Product',
                ),
              ],
            ),
          ),
        ),
        Divider(height: 1, color: Theme.of(context).dividerColor),
        Expanded(
          child: _selectedFacilityId.isEmpty
              ? _buildNoFacilitiesMessage()
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildFilters(),
                    _buildStats(),
                    Expanded(child: _buildProductsList()),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildNoFacilitiesMessage() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.business, size: 64, color: AppTheme.textTertiary),
          const SizedBox(height: 16),
          Text(
            'No Facilities',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    return Container(
      padding: const EdgeInsets.all(16.0),
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
      ),
      child: Column(
        children: [
          FutureBuilder<List<FacilityModel>>(
            future: ref.read(authStateProvider).maybeWhen(
              data: (user) => user != null
                  ? ref.read(userFacilitiesProvider(user.uid).future)
                  : Future.value(<FacilityModel>[]),
              orElse: () => Future.value(<FacilityModel>[]),
            ),
            builder: (context, snapshot) {
              final facilities = snapshot.data ?? [];
              if (facilities.isEmpty) return const SizedBox.shrink();
              
              return DropdownButtonFormField<String>(
                value: _selectedFacilityId.isEmpty ? null : _selectedFacilityId,
                decoration: InputDecoration(
                  labelText: 'Facility',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                items: facilities.map((facility) {
                  return DropdownMenuItem(
                    value: facility.id,
                    child: Text(facility.name),
                  );
                }).toList(),
                onChanged: (value) {
                  if (value != null) {
                    setState(() {
                      _selectedFacilityId = value;
                    });
                  }
                },
              );
            },
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  decoration: InputDecoration(
                    labelText: 'Search Products',
                    prefixIcon: const Icon(Icons.search),
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  onChanged: (value) {
                    setState(() {
                      _searchQuery = value;
                    });
                  },
                ),
              ),
              const SizedBox(width: 12),
              DropdownButtonFormField<ProductCategory?>(
                value: _categoryFilter,
                decoration: InputDecoration(
                  labelText: 'Category',
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
                items: [
                  const DropdownMenuItem(value: null, child: Text('All Categories')),
                  ...ProductCategory.values.map((category) {
                    return DropdownMenuItem(
                      value: category,
                      child: Text(_getCategoryLabel(category)),
                    );
                  }),
                ],
                onChanged: (value) {
                  setState(() {
                    _categoryFilter = value;
                  });
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStats() {
    if (_selectedFacilityId.isEmpty) return const SizedBox.shrink();

    final productsAsync = ref.watch(productsForFacilityProvider(_selectedFacilityId));

    return productsAsync.when(
      data: (products) {
        final total = products.length;
        final lowStock = products.where((p) => p.isLowStock).length;
        final outOfStock = products.where((p) => p.isOutOfStock).length;
        final totalValue = products.fold(0.0, (sum, p) => sum + (p.price * p.stockQuantity));

        return Container(
          padding: const EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color: AppTheme.backgroundLight,
            border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
          ),
          child: Row(
            children: [
              _buildStatCard('Total Products', total.toString(), Icons.inventory_2),
              const SizedBox(width: 16),
              _buildStatCard('Low Stock', lowStock.toString(), Icons.warning, AppTheme.warning),
              const SizedBox(width: 16),
              _buildStatCard('Out of Stock', outOfStock.toString(), Icons.error, AppTheme.error),
              const SizedBox(width: 16),
              _buildStatCard('Total Value', '\$${totalValue.toStringAsFixed(2)}', Icons.attach_money, AppTheme.success),
            ],
          ),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(16.0),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (error, stack) => Padding(
        padding: const EdgeInsets.all(16.0),
        child: Text('Error loading stats: $error', style: TextStyle(color: AppTheme.error)),
      ),
    );
  }

  Widget _buildStatCard(String label, String value, IconData icon, [Color? color]) {
    return Expanded(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Row(
            children: [
              Icon(icon, color: color ?? AppTheme.primaryBlue, size: 24),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      value,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: color ?? AppTheme.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildProductsList() {
    if (_selectedFacilityId.isEmpty) {
      return const Center(child: Text('Select a facility'));
    }

    final productsAsync = ref.watch(productsForFacilityProvider(_selectedFacilityId));

    return productsAsync.when(
      data: (products) {
        var filteredProducts = products;
        
        if (_categoryFilter != null) {
          filteredProducts = filteredProducts.where((p) => p.category == _categoryFilter).toList();
        }
        
        if (_searchQuery.isNotEmpty) {
          filteredProducts = filteredProducts.where((p) {
            return p.name.toLowerCase().contains(_searchQuery.toLowerCase()) ||
                (p.sku != null && p.sku!.toLowerCase().contains(_searchQuery.toLowerCase()));
          }).toList();
        }

        if (filteredProducts.isEmpty) {
          return Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.inventory_2, size: 64, color: AppTheme.textTertiary),
                const SizedBox(height: 16),
                Text(
                  _searchQuery.isNotEmpty || _categoryFilter != null
                      ? 'No products match your filters'
                      : 'No products yet',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                ElevatedButton.icon(
                  onPressed: () => _showAddProductDialog(),
                  icon: const Icon(Icons.add),
                  label: const Text('Add First Product'),
                ),
              ],
            ),
          );
        }

        return ListView.builder(
          padding: const EdgeInsets.all(16.0),
          itemCount: filteredProducts.length,
          itemBuilder: (context, index) {
            final product = filteredProducts[index];
            return _buildProductCard(product);
          },
        );
      },
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, stack) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: AppTheme.error),
            const SizedBox(height: 16),
            Text(
              'Error loading products',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                color: AppTheme.error,
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => ref.invalidate(productsForFacilityProvider(_selectedFacilityId)),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildProductCard(ProductModel product) {
    final stockColor = product.isOutOfStock
        ? AppTheme.error
        : product.isLowStock
            ? AppTheme.warning
            : AppTheme.success;

    return Card(
      margin: const EdgeInsets.only(bottom: 12.0),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: stockColor.withOpacity(0.1),
          child: Icon(
            Icons.inventory_2,
            color: stockColor,
          ),
        ),
        title: Text(
          product.name,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${product.categoryDisplayName} • ${product.formattedPrice}'),
            if (product.trackInventory)
              Text(
                'Stock: ${product.stockQuantity} ${product.unit ?? 'each'}',
                style: TextStyle(
                  color: stockColor,
                  fontWeight: FontWeight.w500,
                ),
              ),
            if (product.sku != null)
              Text('SKU: ${product.sku}', style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (product.isLowStock || product.isOutOfStock)
              Icon(
                product.isOutOfStock ? Icons.error : Icons.warning,
                color: stockColor,
                size: 20,
              ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(Icons.edit),
              onPressed: () => _showEditProductDialog(product),
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

  void _showAddProductDialog() {
    showDialog(
      context: context,
      builder: (context) => ProductDialog(
        facilityId: _selectedFacilityId,
        onSaved: () {
          // Refresh will happen automatically via stream
          Navigator.pop(context);
        },
      ),
    );
  }

  void _showEditProductDialog(ProductModel product) {
    showDialog(
      context: context,
      builder: (context) => ProductDialog(
        facilityId: _selectedFacilityId,
        product: product,
        onSaved: () {
          // Refresh will happen automatically via stream
          Navigator.pop(context);
        },
      ),
    );
  }
}

