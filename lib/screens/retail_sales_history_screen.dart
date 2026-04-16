import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../models/sale_model.dart';
import '../services/sale_service.dart';
import '../theme/app_theme.dart';

class RetailSalesHistoryScreen extends StatelessWidget {
  final String facilityId;

  const RetailSalesHistoryScreen({
    super.key,
    required this.facilityId,
  });

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
            child: Text(
              'Retail Sales History',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: cs.onSurface,
                  ),
            ),
          ),
        ),
        Divider(height: 1, color: Theme.of(context).dividerColor),
        Expanded(
          child: StreamBuilder<List<SaleModel>>(
            stream: SaleService.getSalesForFacilityStream(facilityId),
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Center(
                  child: Text(
                    'Could not load sales: ${snapshot.error}',
                    style: const TextStyle(color: AppTheme.error),
                  ),
                );
              }
              final sales = snapshot.data ?? const <SaleModel>[];
              if (sales.isEmpty) {
                return Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.receipt_long_outlined,
                        size: 64,
                        color: AppTheme.textTertiary,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        'No sales found for this facility',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                              color: AppTheme.textSecondary,
                            ),
                      ),
                    ],
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: sales.length,
                separatorBuilder: (_, __) => const SizedBox(height: 8),
                itemBuilder: (context, index) {
                  final sale = sales[index];
                  return _SaleCard(sale: sale);
                },
              );
            },
          ),
        ),
      ],
    );
  }
}

class _SaleCard extends StatelessWidget {
  final SaleModel sale;

  const _SaleCard({required this.sale});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final date = DateFormat.yMd().add_jm().format(sale.saleDate);
    final itemCount = sale.lineItems.fold<int>(0, (sum, item) => sum + item.quantity);
    final itemSummary = sale.lineItems
        .map((item) => '${item.quantity}x ${item.productName}')
        .join(', ');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  sale.saleNumber,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                ),
                const Spacer(),
                Text(
                  sale.formattedTotal,
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                        color: AppTheme.primaryBlue,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  Icons.person_outline,
                  size: 18,
                  color: AppTheme.textSecondary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: cs.onSurface,
                          ),
                      children: [
                        TextSpan(
                          text: 'Sold to ',
                          style: TextStyle(
                            color: AppTheme.textSecondary,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        TextSpan(
                          text: sale.buyerSummary,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              '$date  •  ${sale.paymentMethodDisplayName}  •  $itemCount item${itemCount == 1 ? '' : 's'}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
            ),
            if (itemSummary.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                'Items',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: AppTheme.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
              ),
              const SizedBox(height: 4),
              Text(
                itemSummary,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
