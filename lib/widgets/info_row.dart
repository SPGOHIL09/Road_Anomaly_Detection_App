import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class InfoRow extends StatelessWidget {
  final IconData icon;
  final String topLabel;
  final String value;

  const InfoRow({
    super.key,
    required this.icon,
    required this.topLabel,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        // bg-slate-100 dark:bg-slate-800/50
        color: AppColors.slate800.withOpacity(0.50),
        borderRadius: BorderRadius.circular(12),
        border: const Border.fromBorderSide(
            BorderSide(color: Color(0xFF334155), width: 1)),
      ),
      child: Row(
        children: [
          Container(
            width: 40, height: 40,
            decoration: BoxDecoration(
              color: AppColors.primary.withOpacity(0.20),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, color: AppColors.primary, size: 22),
          ),
          const SizedBox(width: 16),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                topLabel,
                style: const TextStyle(
                  color: AppColors.slate500,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                value,
                style: const TextStyle(
                  color: AppColors.slateText,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}