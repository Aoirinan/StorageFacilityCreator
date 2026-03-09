import 'package:flutter/material.dart';
import 'package:sfcapp/theme/app_theme.dart';

/// Simple donut chart widget for displaying metrics
class DonutChart extends StatelessWidget {
  final double value; // 0.0 to 1.0
  final String label;
  final Color? color;
  final double size;

  const DonutChart({
    super.key,
    required this.value,
    required this.label,
    this.color,
    this.size = 120,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final chartColor = color ?? colorScheme.primary;
    final clampedValue = value.clamp(0.0, 1.0);
    final percentage = (clampedValue * 100).round();

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Background circle
          SizedBox(
            width: size,
            height: size,
            child: CircularProgressIndicator(
              value: clampedValue,
              strokeWidth: 12,
              backgroundColor: colorScheme.outline,
              valueColor: AlwaysStoppedAnimation<Color>(chartColor),
            ),
          ),
          // Center text
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$percentage%',
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.onSurface,
                ),
              ),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10,
                  color: colorScheme.onSurfaceVariant,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

