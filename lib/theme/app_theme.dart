import 'package:flutter/material.dart';

class AppColors {
  static const Color primary = Color(0xFF1F7BE5);
  static const Color backgroundDark = Color(0xFF111821);
  static const Color backgroundDark2 = Color(0xFF0B0E14);
  static const Color cardDark = Color(0xFF1A242F);
  static const Color cardDark2 = Color(0xFF161B22);
  static const Color accentDark = Color(0xFF243447);
  static const Color surfaceDark = Color(0xFF1A222C);
  static const Color borderDark = Color(0xFF243447);
  static const Color neonGreen = Color(0xFF39FF14);

  static const Color slate100 = Color(0xFFF1F5F9);
  static const Color slate200 = Color(0xFFE2E8F0);
  static const Color slate300 = Color(0xFFCBD5E1);
  static const Color slate400 = Color(0xFF94A3B8);
  static const Color slate500 = Color(0xFF64748B);
  static const Color slate700 = Color(0xFF334155);
  static const Color slate800 = Color(0xFF1E293B);
  static const Color slate900 = Color(0xFF0F172A);
  static const Color white = Color(0xFFFFFFFF);
  static const Color slateText = Color(0xFFF1F5F9);

  static Color primaryWithOpacity(double o) => primary.withOpacity(o);
}

class AppTheme {
  static ThemeData get dark {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: AppColors.backgroundDark,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.primary,
        surface: AppColors.cardDark,
        background: AppColors.backgroundDark,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.backgroundDark,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: AppColors.slateText),
        titleTextStyle: TextStyle(
          color: AppColors.slateText,
          fontSize: 18,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.3,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: MaterialStateProperty.all(AppColors.white),
        trackColor: MaterialStateProperty.resolveWith((s) =>
            s.contains(MaterialState.selected)
                ? AppColors.primary
                : AppColors.slate700),
        trackOutlineColor: MaterialStateProperty.all(Colors.transparent),
      ),
      sliderTheme: SliderThemeData(
        trackHeight: 6,
        activeTrackColor: AppColors.primary,
        inactiveTrackColor: AppColors.accentDark,
        thumbColor: AppColors.white,
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 10),
        overlayColor: AppColors.primary.withOpacity(0.2),
        overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
      ),
    );
  }
}
