import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

class IconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const IconBtn({super.key, required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, color: AppColors.slate400, size: 24),
      ),
    );
  }
}