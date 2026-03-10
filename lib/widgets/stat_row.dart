import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class StatsRow extends StatelessWidget {
  const StatsRow({super.key});


  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Row(
          children: [
            Expanded(
                child: _StatTile(
                    icon: Icons.history_rounded,
                    label: 'RECENT SCANS',
                    value: '128 Total')),
            const SizedBox(width: 16),
            Expanded(
                child: _StatTile(
                    icon: Icons.report_problem_outlined,
                    label: 'ANOMALIES DETECTED',
                    value: '42 Today')),
          ],
        ),
        const SizedBox(height: 16),
        _StatTile(
            icon: Icons.memory_outlined,
            label: 'AI MODEL',
            value: 'v4.2.0 Active',
            fullWidth: true),
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool fullWidth;

  const _StatTile({
    required this.icon,
    required this.label,
    required this.value,
    this.fullWidth = false,
  });

  @override
  Widget build(BuildContext context) {
    final tile = Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.cardDark2,
        borderRadius: BorderRadius.circular(12),
        border: const Border.fromBorderSide(
            BorderSide(color: Color(0xFF1E293B), width: 1)),
      ),
      child: Row(
        children: [
          Icon(icon, color: AppColors.primary, size: 22),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: AppColors.slate500,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: const TextStyle(
                    color: AppColors.slateText,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    if (fullWidth) return tile;
    return tile;
  }
}