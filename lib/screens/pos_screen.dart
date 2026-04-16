import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../models/product_model.dart';
import '../models/sale_model.dart';
import '../models/tenant_model.dart';
import '../services/sale_service.dart';
import '../services/stripe_service.dart';
import '../providers/inventory_provider.dart';
import '../services/tenant_service.dart';
import '../theme/app_theme.dart';
import '../router/app_route.dart';
import '../ui/payments/stripe_embedded_payment_dialog.dart';
import '../utils/error_message_helper.dart';

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

class _POSScreenState extends ConsumerState<POSScreen>
    with SingleTickerProviderStateMixin {
  String? _selectedTenantId;
  /// Matches checkout UI: "Walk-in customer" or tenant line from dropdown.
  String _buyerDisplayName = 'Walk-in customer';
  final List<SaleLineItem> _cart = [];
  PaymentMethod _paymentMethod = PaymentMethod.cash;
  bool _useTerminalReader = false;
  double? _taxRate;
  bool _isProcessing = false;
  late final TabController _posTabController;

  static const double _posSideBySideBreakpoint = 720;

  @override
  void initState() {
    super.initState();
    _selectedTenantId = widget.tenantId;
    if (widget.tenantId != null && widget.tenantId!.isNotEmpty) {
      _syncBuyerDisplayNameForTenantId(widget.tenantId);
    }
    _posTabController = TabController(length: 2, vsync: this);
  }

  static String _buyerLabelForTenant(TenantModel tenant) {
    return '${tenant.name} - ${tenant.unitNumber}';
  }

  Future<void> _syncBuyerDisplayNameForTenantId(String? tenantId) async {
    if (tenantId == null || tenantId.isEmpty) {
      if (mounted) {
        setState(() => _buyerDisplayName = 'Walk-in customer');
      } else {
        _buyerDisplayName = 'Walk-in customer';
      }
      return;
    }
    try {
      final tenants =
          await TenantService.getTenantsForFacility(widget.facilityId);
      if (!mounted) return;
      TenantModel? match;
      for (final t in tenants) {
        if (t.id == tenantId) {
          match = t;
          break;
        }
      }
      setState(() {
        _buyerDisplayName =
            match != null ? _buyerLabelForTenant(match) : 'Tenant';
      });
    } catch (_) {
      if (mounted) {
        setState(() => _buyerDisplayName = 'Tenant');
      }
    }
  }

  @override
  void dispose() {
    _posTabController.dispose();
    super.dispose();
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

    if (_paymentMethod == PaymentMethod.creditCard) {
      await _processCardSale();
      return;
    }

    if (_paymentMethod == PaymentMethod.ach) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('ACH is not available at POS. Use cash, check, or card.'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      final sale = await SaleService.createSale(
        facilityId: widget.facilityId,
        tenantId: _selectedTenantId,
        buyerDisplayName: _buyerDisplayName,
        lineItems: _cart,
        paymentMethod: _paymentMethod,
        tax: _calculateTax(),
        updateInventory: true,
        createLedgerEntry:
            _selectedTenantId != null && _selectedTenantId!.isNotEmpty,
      );

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sale completed: ${sale.saleNumber}'),
            backgroundColor: AppTheme.success,
            duration: const Duration(seconds: 3),
          ),
        );

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
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  /// Card data is collected only in Stripe Payment Element (PCI-safe), then sale is recorded.
  Future<void> _processCardSale() async {
    if (!kIsWeb) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Card payments on Retail (POS) are available on the web app.'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }

    final total = _calculateTotal();
    final cents = (total * 100).round();
    if (cents < 50) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Minimum card charge is \$0.50.'),
            backgroundColor: AppTheme.warning,
          ),
        );
      }
      return;
    }

    setState(() {
      _isProcessing = true;
    });

    try {
      if (_useTerminalReader) {
        await _processTerminalReaderSale(cents);
        return;
      }

      final data = await StripeService.createPosRetailPaymentIntent(
        facilityId: widget.facilityId,
        amountCents: cents,
        tenantId: _selectedTenantId,
      );
      final clientSecret = data['clientSecret'] as String?;
      final publishableKey = data['publishableKey'] as String?;
      final connectedAccountId = data['connectedAccountId'] as String?;
      if (clientSecret == null || clientSecret.isEmpty) {
        throw Exception('Could not start card payment');
      }
      if (!mounted) return;

      final baseUrl = Uri.base.origin;
      final returnQuery = StringBuffer(
          'facilityId=${Uri.encodeQueryComponent(widget.facilityId)}');
      if (_selectedTenantId != null && _selectedTenantId!.isNotEmpty) {
        returnQuery
            .write('&tenantId=${Uri.encodeQueryComponent(_selectedTenantId!)}');
      }
      final returnUrl = '$baseUrl/#${AppRoute.pos}?${returnQuery.toString()}';

      final result = await showStripeEmbeddedDialog(
        context: context,
        clientSecret: clientSecret,
        mode: 'payment',
        returnUrl: returnUrl,
        publishableKeyFromBackend: publishableKey,
        stripeAccount: connectedAccountId,
      );

      if (!mounted) return;
      if (result == null || !result.succeeded) {
        if (result?.error != null && result!.error!.isNotEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
                content: Text(result.error!), backgroundColor: AppTheme.error),
          );
        }
        return;
      }

      await _recordCompletedCardSale(result.paymentIntentId);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ErrorMessageHelper.getUserFriendlyMessage(e)),
            backgroundColor: AppTheme.error,
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false;
        });
      }
    }
  }

  Future<void> _processTerminalReaderSale(int cents) async {
    final readers = await StripeService.listPosTerminalReaders(
      facilityId: widget.facilityId,
    );
    if (readers.isEmpty) {
      throw Exception(
          'No Stripe readers found. Register and connect a reader in Stripe Terminal, then refresh.');
    }

    final readerId = await _promptForTerminalReader(readers);
    if (readerId == null || readerId.isEmpty) {
      throw Exception('Reader selection cancelled.');
    }

    final startResult = await StripeService.processPosTerminalPayment(
      facilityId: widget.facilityId,
      amountCents: cents,
      readerId: readerId,
      tenantId: _selectedTenantId,
    );
    final paymentIntentId = (startResult['paymentIntentId'] as String?)?.trim();
    if (paymentIntentId == null || paymentIntentId.isEmpty) {
      throw Exception('Could not start reader payment.');
    }

    const maxAttempts = 45;
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
      final statusResult = await StripeService.getPosTerminalPaymentStatus(
        facilityId: widget.facilityId,
        paymentIntentId: paymentIntentId,
      );
      final status = (statusResult['status'] as String?) ?? 'unknown';
      final succeeded = statusResult['succeeded'] == true;
      if (succeeded) {
        await _recordCompletedCardSale(paymentIntentId);
        return;
      }
      if (status == 'canceled' || status == 'requires_payment_method') {
        throw Exception('Reader payment was not completed ($status).');
      }
      await Future<void>.delayed(const Duration(seconds: 2));
    }

    throw Exception(
        'Reader payment is still pending. Check the reader and payment status, then try again.');
  }

  Future<void> _recordCompletedCardSale(String? paymentIntentId) async {
    final sale = await SaleService.createSale(
      facilityId: widget.facilityId,
      tenantId: _selectedTenantId,
      buyerDisplayName: _buyerDisplayName,
      lineItems: List<SaleLineItem>.from(_cart),
      paymentMethod: PaymentMethod.creditCard,
      tax: _calculateTax(),
      stripePaymentIntentId: paymentIntentId,
      updateInventory: true,
      createLedgerEntry:
          _selectedTenantId != null && _selectedTenantId!.isNotEmpty,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Sale completed: ${sale.saleNumber}'),
        backgroundColor: AppTheme.success,
        duration: const Duration(seconds: 3),
      ),
    );
    setState(() {
      _cart.clear();
    });
  }

  Future<String?> _promptForTerminalReader(
      List<Map<String, dynamic>> readers) async {
    if (!mounted) return null;
    String? selectedReaderId = (readers.first['id'] as String?)?.trim();

    return showDialog<String>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Select card reader'),
              content: SizedBox(
                width: 420,
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: readers.length,
                  itemBuilder: (context, index) {
                    final reader = readers[index];
                    final readerId = (reader['id'] as String?) ?? '';
                    final label =
                        (reader['label'] as String?) ?? 'Unnamed reader';
                    final status = (reader['status'] as String?) ?? 'unknown';
                    return RadioListTile<String>(
                      value: readerId,
                      groupValue: selectedReaderId,
                      onChanged: (value) {
                        setDialogState(() {
                          selectedReaderId = value;
                        });
                      },
                      title: Text(label),
                      subtitle: Text(status),
                    );
                  },
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed:
                      selectedReaderId == null || selectedReaderId!.isEmpty
                          ? null
                          : () => Navigator.of(ctx).pop(selectedReaderId),
                  child: const Text('Use Reader'),
                ),
              ],
            );
          },
        );
      },
    );
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
          content:
              Text('Insufficient stock. Available: ${product.stockQuantity}'),
          backgroundColor: AppTheme.error,
        ),
      );
      return;
    }

    setState(() {
      final existingIndex =
          _cart.indexWhere((item) => item.productId == product.id);
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
    if (MediaQuery.sizeOf(context).width < _posSideBySideBreakpoint) {
      _posTabController.animateTo(1);
    }
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
    // AppShell (ShellRoute) already provides sidebar + global top bar. Do not nest
    // ModernPageWrapper/Scaffold here — it collapses the body to a blank area.
    final cs = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final sideBySide = width >= _posSideBySideBreakpoint;
    final headerPadH = sideBySide ? 24.0 : 12.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: cs.surface,
          child: Padding(
            padding: EdgeInsets.symmetric(horizontal: headerPadH, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Retail (POS)',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: cs.onSurface,
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (sideBySide) ...[
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
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: () => context.go(
                      Uri(
                        path: AppRoute.retailSales,
                        queryParameters: {'facilityId': widget.facilityId},
                      ).toString(),
                    ),
                    icon: const Icon(Icons.receipt_long_outlined, size: 20),
                    label: const Text('Sales history'),
                  ),
                ] else ...[
                  IconButton(
                    tooltip: 'Products & stock',
                    onPressed: () => context.go(
                      Uri(
                        path: AppRoute.inventory,
                        queryParameters: {'facilityId': widget.facilityId},
                      ).toString(),
                    ),
                    icon: const Icon(Icons.inventory_2_outlined),
                  ),
                  IconButton(
                    tooltip: 'Sales history',
                    onPressed: () => context.go(
                      Uri(
                        path: AppRoute.retailSales,
                        queryParameters: {'facilityId': widget.facilityId},
                      ).toString(),
                    ),
                    icon: const Icon(Icons.receipt_long_outlined),
                  ),
                ],
              ],
            ),
          ),
        ),
        Divider(height: 1, color: Theme.of(context).dividerColor),
        Expanded(
          child: sideBySide
              ? Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 2, child: _buildProductSelection()),
                    Expanded(flex: 1, child: _buildCart(splitPane: true)),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Material(
                      color: cs.surface,
                      child: TabBar(
                        controller: _posTabController,
                        tabs: [
                          const Tab(text: 'Products'),
                          Tab(text: 'Cart (${_cart.length})'),
                        ],
                      ),
                    ),
                    Expanded(
                      child: TabBarView(
                        controller: _posTabController,
                        children: [
                          _buildProductSelection(),
                          _buildCart(splitPane: false),
                        ],
                      ),
                    ),
                  ],
                ),
        ),
      ],
    );
  }

  Widget _buildProductSelection() {
    final productsAsync =
        ref.watch(productsForFacilityProvider(widget.facilityId));

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
                  future:
                      TenantService.getTenantsForFacility(widget.facilityId),
                  builder: (context, snapshot) {
                    final tenants = snapshot.data ?? [];
                    return DropdownButtonFormField<String?>(
                      value: _selectedTenantId,
                      decoration: const InputDecoration(
                        labelText: 'Sell to Tenant (Optional)',
                        border: OutlineInputBorder(),
                      ),
                      items: [
                        const DropdownMenuItem(
                            value: null, child: Text('Walk-in Customer')),
                        ...tenants.map((tenant) => DropdownMenuItem(
                              value: tenant.id,
                              child:
                                  Text('${tenant.name} - ${tenant.unitNumber}'),
                            )),
                      ],
                      onChanged: (value) {
                        setState(() {
                          _selectedTenantId = value;
                          if (value == null || value.isEmpty) {
                            _buyerDisplayName = 'Walk-in customer';
                          } else {
                            TenantModel? match;
                            for (final t in tenants) {
                              if (t.id == value) {
                                match = t;
                                break;
                              }
                            }
                            _buyerDisplayName = match != null
                                ? _buyerLabelForTenant(match)
                                : 'Tenant';
                          }
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
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 420),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.inventory_2,
                            size: 64, color: AppTheme.textTertiary),
                        const SizedBox(height: 16),
                        Text(
                          'No products yet',
                          style:
                              Theme.of(context).textTheme.titleMedium?.copyWith(
                                    color: AppTheme.textSecondary,
                                    fontWeight: FontWeight.w600,
                                  ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Add locks, boxes, and other retail SKUs under Products & stock.',
                          textAlign: TextAlign.center,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    color: AppTheme.textTertiary,
                                  ),
                        ),
                        const SizedBox(height: 20),
                        FilledButton.icon(
                          onPressed: () => context.go(
                            Uri(
                              path: AppRoute.inventory,
                              queryParameters: {
                                'facilityId': widget.facilityId
                              },
                            ).toString(),
                          ),
                          icon: const Icon(Icons.add),
                          label: const Text('Add products'),
                        ),
                      ],
                    ),
                  ),
                );
              }

              return LayoutBuilder(
                builder: (context, constraints) {
                  final w = constraints.maxWidth;
                  var crossAxisCount = 4;
                  if (w < 380) {
                    crossAxisCount = 2;
                  } else if (w < 560) {
                    crossAxisCount = 3;
                  } else if (w < 840) {
                    crossAxisCount = 3;
                  }
                  final aspect = w < 400 ? 0.72 : 0.8;
                  return GridView.builder(
                    padding: const EdgeInsets.all(16.0),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: aspect,
                    ),
                    itemCount: products.length,
                    itemBuilder: (context, index) {
                      final product = products[index];
                      return _buildProductCard(product);
                    },
                  );
                },
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, stack) => Center(
              child: Text('Error loading products: $error',
                  style: TextStyle(color: AppTheme.error)),
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

  Widget _buildCartLine(int index, SaleLineItem item, {required bool compact}) {
    if (compact) {
      return Card(
        margin: const EdgeInsets.only(bottom: 8.0),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                item.productName,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 2),
              Text(
                '\$${item.unitPrice.toStringAsFixed(2)} each',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.remove_circle_outline),
                    onPressed: () =>
                        _updateCartQuantity(index, item.quantity - 1),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Text(
                      '${item.quantity}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.add_circle_outline),
                    onPressed: () =>
                        _updateCartQuantity(index, item.quantity + 1),
                  ),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _removeFromCart(index),
                    color: AppTheme.error,
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

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
  }

  Widget _buildCart({required bool splitPane}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compactLineItems = constraints.maxWidth < 360;
        return Container(
          decoration: BoxDecoration(
            color: AppTheme.backgroundLight,
            border: splitPane
                ? Border(left: BorderSide(color: AppTheme.borderLight))
                : null,
          ),
          child: Column(
            children: [
              // Cart Header
              Container(
                padding: const EdgeInsets.all(16.0),
                decoration: BoxDecoration(
                  color: AppTheme.primaryBlue,
                  border:
                      Border(bottom: BorderSide(color: AppTheme.borderLight)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.shopping_cart, color: Colors.white),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Cart (${_cart.length})',
                        style:
                            Theme.of(context).textTheme.titleLarge?.copyWith(
                                  color: Colors.white,
                                  fontWeight: FontWeight.bold,
                                ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
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
                            Icon(Icons.shopping_cart_outlined,
                                size: 64, color: AppTheme.textTertiary),
                            const SizedBox(height: 16),
                            Text(
                              'Cart is empty',
                              style: Theme.of(context)
                                  .textTheme
                                  .titleMedium
                                  ?.copyWith(
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
                          return _buildCartLine(
                            index,
                            item,
                            compact: compactLineItems,
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
                        Text('Subtotal:',
                            style: Theme.of(context).textTheme.bodyLarge),
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
                          Text('Tax:',
                              style: Theme.of(context).textTheme.bodyLarge),
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
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(
                                fontWeight: FontWeight.bold,
                              ),
                        ),
                        Text(
                          '\$${_calculateTotal().toStringAsFixed(2)}',
                          style: Theme.of(context)
                              .textTheme
                              .titleLarge
                              ?.copyWith(
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
                      isExpanded: true,
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
                    if (_paymentMethod == PaymentMethod.creditCard) ...[
                      const SizedBox(height: 8),
                      SwitchListTile.adaptive(
                        contentPadding: EdgeInsets.zero,
                        value: _useTerminalReader,
                        onChanged: kIsWeb
                            ? (value) {
                                setState(() {
                                  _useTerminalReader = value;
                                });
                              }
                            : null,
                        title: const Text('Use Stripe card reader'),
                        subtitle: Text(
                          kIsWeb
                              ? 'Turn on to collect payment on a connected Stripe Terminal reader.'
                              : 'Reader payments are available on web.',
                        ),
                      ),
                      Text(
                        _useTerminalReader ? 'Tap Complete Sale to send this charge to a Stripe reader.'
                            : 'Tap Complete Sale to open a secure Stripe form. Card numbers are not entered in this app.',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isProcessing || _cart.isEmpty
                            ? null
                            : _processSale,
                        style: ElevatedButton.styleFrom(
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          backgroundColor: AppTheme.primaryBlue,
                          foregroundColor: Colors.white,
                        ),
                        child: _isProcessing
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white),
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
      },
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
