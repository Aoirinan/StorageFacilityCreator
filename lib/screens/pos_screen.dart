import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/product_model.dart';
import '../models/sale_model.dart';
import '../models/tenant_model.dart';
import '../services/sale_service.dart';
import '../providers/inventory_provider.dart';
import '../services/tenant_service.dart';
import '../theme/app_theme.dart';
import '../widgets/modern_page_wrapper.dart';
import '../services/modern_navigation_service.dart';
import '../router/app_route.dart';

class POSScreen extends ConsumerStatefulWidget {
  final String facilityId;
  final String? tenantId; // Optional: pre-select tenant

  const POSScreen({
    super.key,
    required this.facilityId,
    this.tenantId,
  });

  @override
  ConsumerState<POSScreen> createState() => _POSScreenState();
}

class _POSScreenState extends ConsumerState<POSScreen> {
  String? _selectedTenantId;
  final List<SaleLineItem> _cart = [];
  PaymentMethod _paymentMethod = PaymentMethod.cash;
  double? _taxRate;
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    _selectedTenantId = widget.tenantId;
  }

  Future<void> _processSale() async {
    if (_cart.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Cart is empty'),
          backgroundColor: AppTheme.warning,
        ),
      );
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      final sale = await SaleService.createSale(
        facilityId: widget.facilityId,
        tenantId: _selectedTenantId,
        lineItems: _cart,
        paymentMethod: _paymentMethod,
        tax: _calculateTax(),
        updateInventory: true,
        createLedgerEntry: _selectedTenantId != null && _selectedTenantId!.isNotEmpty,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sale completed: ${sale.saleNumber}'),
            backgroundColor: AppTheme.success,
            duration: const Duration(seconds: 3),
          ),
        );
        
        // Clear cart
        setState(() {
          _cart.clear();
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error processing sale: $e'),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      setState(() {
        _isProcessing = false;
      });
    }
  }

  double _calculateSubtotal() {
    return _cart.fold(0.0, (sum, item) => sum + item.total);
  }

  double _calculateTax() {
    if (_taxRate == null) return 0.0;
    return _calculateSubtotal() * (_taxRate! / 100);
  }

  double _calculateTotal() {
    return _calculateSubtotal() + _calculateTax();
  }

  void _addToCart(ProductModel product, int quantity) {
    if (product.trackInventory && product.stockQuantity < quantity) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Insufficient stock. Available: ${product.stockQuantity}'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    setState(() {
      final existingIndex = _cart.indexWhere((item) => item.productId == product.id);
      if (existingIndex >= 0) {
        final existing = _cart[existingIndex];
        _cart[existingIndex] = SaleLineItem(
          productId: product.id,
          productName: product.name,
          unitPrice: product.price,
          quantity: existing.quantity + quantity,
          total: product.price * (existing.quantity + quantity),
        );
      } else {
        _cart.add(SaleLineItem(
          productId: product.id,
          productName: product.name,
          unitPrice: product.price,
          quantity: quantity,
          total: product.price * quantity,
        ));
      }
    });
  }

  void _removeFromCart(int index) {
    setState(() {
      _cart.removeAt(index);
    });
  }

  void _updateCartQuantity(int index, int quantity) {
    if (quantity <= 0) {
      _removeFromCart(index);
      return;
    }

    setState(() {
      final item = _cart[index];
      _cart[index] = SaleLineItem(
        productId: item.productId,
        productName: item.productName,
        unitPrice: item.unitPrice,
        quantity: quantity,
        total: item.unitPrice * quantity,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return ModernPageWrapper(
      currentRoute: '/pos',
      title: 'Retail (POS)',
      onNavigate: (route) {
        ModernNavigationService.navigateToRoute(context, route);
      },
      actions: [
        TextButton.icon(
          onPressed: () => context.go(
            Uri(
              path: AppRoute.inventory,
              queryParameters: {'facilityId': widget.facilityId},
            ).toString(),
          ),
          icon: const Icon(Icons.inventory_2_outlined, size: 20),
          label: const Text('Products & stock'),
        ),
      ],
      child: Row(
        children: [
          // Product Selection
          Expanded(
            flex: 2,
            child: _buildProductSelection(),
          ),
          // Cart and Checkout
          Expanded(
            flex: 1,
            child: _buildCart(),
          ),
        ],
      ),
    );
  }

  Widget _buildProductSelection() {
    final productsAsync = ref.watch(productsForFacilityProvider(widget.facilityId));

    return Column(
      children: [
        // Tenant Selection
        Container(
          padding: const EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color: AppTheme.backgroundLight,
            border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
          ),
          child: Row(
            children: [
              Expanded(
                child: FutureBuilder<List<TenantModel>>(
                  future: TenantService.getTenantsForFacility(widget.facilityId),
                  builder: (context, snapshot) {
                    final tenants = snapshot.data ?? [];
                    return DropdownButtonFormField<String?>(
                      value: _selectedTenantId,
                      decoration: const InputDecoration(
                        labelText: 'Sell to Tenant (Optional)',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(value: null, child: Text('Walk-in Customer')),
                        ...tenants.map((tenant) => DropdownMenuItem(
                          value: tenant.id,
                          child: Text('${tenant.name} - ${tenant.unitNumber}'),
                        )),
                      ],
                      onChanged: (value) {
                        setState(() {
                          _selectedTenantId = value;
                        });
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
        // Products Grid
        Expanded(
          child: productsAsync.when(
            data: (products) {
              if (products.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inventory_2, size: 64, color: AppTheme.textTertiary),
                      const SizedBox(height: 16),
                      Text(
                        'No products available',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                      ),
                    ],
                  ),
                );
              }

              return GridView.builder(
                padding: const EdgeInsets.all(16.0),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 4,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 12,
                  childAspectRatio: 0.8,
                ),
                itemCount: products.length,
                itemBuilder: (context, index) {
                  final product = products[index];
                  return _buildProductCard(product);
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stack) => Center(
              child: Text('Error loading products: $error', style: TextStyle(color: AppTheme.error)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildProductCard(ProductModel product) {
    final isOutOfStock = product.isOutOfStock;
    final isLowStock = product.isLowStock;

    return Card(
      color: isOutOfStock ? AppTheme.error.withOpacity(0.1) : null,
      child: InkWell(
        onTap: isOutOfStock ? null : () => _addToCart(product, 1),
        child: Padding(
          padding: const EdgeInsets.all(12.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.inventory_2,
                size: 48,
                color: isOutOfStock
                    ? AppTheme.error
                    : isLowStock
                        ? AppTheme.warning
                        : AppTheme.primaryBlue,
              ),
              const SizedBox(height: 8),
              Text(
                product.name,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Text(
                product.formattedPrice,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                  color: AppTheme.primaryBlue,
                ),
              ),
              if (product.trackInventory)
                Text(
                  'Stock: ${product.stockQuantity}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isOutOfStock
                        ? AppTheme.error
                        : isLowStock
                            ? AppTheme.warning
                            : AppTheme.textSecondary,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCart() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.backgroundLight,
        border: Border(left: BorderSide(color: AppTheme.borderLight)),
      ),
      child: Column(
        children: [
          // Cart Header
          Container(
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: AppTheme.primaryBlue,
              border: Border(bottom: BorderSide(color: AppTheme.borderLight)),
            ),
            child: Row(
              children: [
                const Icon(Icons.shopping_cart, color: Colors.white),
                const SizedBox(width: 8),
                Text(
                  'Cart (${_cart.length})',
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          // Cart Items
          Expanded(
            child: _cart.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.shopping_cart_outlined, size: 64, color: AppTheme.textTertiary),
                        const SizedBox(height: 16),
                        Text(
                          'Cart is empty',
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(8.0),
                    itemCount: _cart.length,
                    itemBuilder: (context, index) {
                      final item = _cart[index];
                      return Card(
                        margin: const EdgeInsets.only(bottom: 8.0),
                        child: ListTile(
                          title: Text(item.productName),
                          subtitle: Text('\$${item.unitPrice.toStringAsFixed(2)} each'),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.remove),
                                onPressed: () => _updateCartQuantity(index, item.quantity - 1),
                              ),
                              Text('${item.quantity}'),
                              IconButton(
                                icon: const Icon(Icons.add),
                                onPressed: () => _updateCartQuantity(index, item.quantity + 1),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete),
                                onPressed: () => _removeFromCart(index),
                                color: AppTheme.error,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          // Totals and Checkout
          Container(
            padding: const EdgeInsets.all(16.0),
            decoration: BoxDecoration(
              color: AppTheme.backgroundLight,
              border: Border(top: BorderSide(color: AppTheme.borderLight)),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('Subtotal:', style: Theme.of(context).textTheme.bodyLarge),
                    Text(
                      '\$${_calculateSubtotal().toStringAsFixed(2)}',
                      style: Theme.of(context).textTheme.bodyLarge,
                    ),
                  ],
                ),
                if (_taxRate != null) ...[
                  const SizedBox(height: 8),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text('Tax:', style: Theme.of(context).textTheme.bodyLarge),
                      Text(
                        '\$${_calculateTax().toStringAsFixed(2)}',
                        style: Theme.of(context).textTheme.bodyLarge,
                      ),
                    ],
                  ),
                ],
                const Divider(),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Total:',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    Text(
                      '\$${_calculateTotal().toStringAsFixed(2)}',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primaryBlue,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<PaymentMethod>(
                  value: _paymentMethod,
                  decoration: const InputDecoration(
                    labelText: 'Payment Method',
                    border: OutlineInputBorder(),
                  ),
                  items: PaymentMethod.values.map((method) {
                    return DropdownMenuItem(
                      value: method,
                      child: Text(_getPaymentMethodLabel(method)),
                    );
                  }).toList(),
                  onChanged: (value) {
                    if (value != null) {
                      setState(() {
                        _paymentMethod = value;
                      });
                    }
                  },
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isProcessing || _cart.isEmpty ? null : _processSale,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: AppTheme.primaryBlue,
                      foregroundColor: Colors.white,
                    ),
                    child: _isProcessing
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                          )
                        : const Text('Complete Sale'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getPaymentMethodLabel(PaymentMethod method) {
    switch (method) {
      case PaymentMethod.cash:
        return 'Cash';
      case PaymentMethod.check:
        return 'Check';
      case PaymentMethod.creditCard:
        return 'Credit Card';
      case PaymentMethod.ach:
        return 'ACH';
    }
  }
}

