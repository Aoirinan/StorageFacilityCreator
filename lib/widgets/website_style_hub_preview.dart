import 'package:flutter/material.dart';

/// The owner's preview of their public rental hub (Online Rentals screen).
///
/// It showed "Rent Now" and "Reserve storage online in minutes" whatever the
/// online rentals switch said, while the public pages, and the reservation
/// hold behind them, turn renters away when it is off. [rentalsEnabled] is
/// that switch, so the preview shows what renters will see.
class WebsiteStyleHubPreview extends StatelessWidget {
  final String facilityName;
  final String marketingText;
  final String logoUrl;
  final bool rentalsEnabled;
  final VoidCallback onViewUnits;
  final VoidCallback onViewMap;
  final VoidCallback onRentNow;

  const WebsiteStyleHubPreview({
    super.key,
    required this.facilityName,
    required this.marketingText,
    required this.logoUrl,
    required this.rentalsEnabled,
    required this.onViewUnits,
    required this.onViewMap,
    required this.onRentNow,
  });

  @override
  Widget build(BuildContext context) {
    final headline = marketingText.isNotEmpty
        ? marketingText
        : rentalsEnabled
            ? 'Reserve storage online in minutes'
            : 'Call us to rent a unit';

    return Card(
      clipBehavior: Clip.antiAlias,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                colors: [Color(0xFF0E3A8A), Color(0xFF1D4ED8)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (logoUrl.isNotEmpty)
                      Container(
                        width: 56,
                        height: 56,
                        margin: const EdgeInsets.only(right: 12),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: Image.network(
                            logoUrl,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const Icon(Icons.store),
                          ),
                        ),
                      ),
                    Expanded(
                      child: Text(
                        facilityName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 26,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(
                  headline,
                  style: const TextStyle(
                    color: Color(0xFFE5EDFF),
                    fontSize: 15,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(14),
            child: Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                OutlinedButton.icon(
                  onPressed: onViewUnits,
                  icon: const Icon(Icons.view_list),
                  label: const Text('View Units'),
                ),
                OutlinedButton.icon(
                  onPressed: onViewMap,
                  icon: const Icon(Icons.map_outlined),
                  label: const Text('View Map'),
                ),
                if (rentalsEnabled)
                  FilledButton.icon(
                    onPressed: onRentNow,
                    icon: const Icon(Icons.shopping_cart_checkout),
                    label: const Text('Rent Now'),
                  )
                else
                  // What renters get in its place: nothing to press here.
                  const OutlinedButton(
                    onPressed: null,
                    child: Text('Call to rent'),
                  ),
              ],
            ),
          ),
          if (!rentalsEnabled)
            const Padding(
              padding: EdgeInsets.fromLTRB(14, 0, 14, 14),
              child: Text(
                'Online rentals are off, so your public pages offer "Call to rent" '
                'instead of Rent Now. Turn on Enable Public Online Rentals and save '
                'to take rentals online.',
              ),
            ),
        ],
      ),
    );
  }
}
