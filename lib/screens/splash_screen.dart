import 'package:flutter/material.dart';
import 'dart:async';
import '../theme/app_theme.dart';
import 'home_screen.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _fadeIn;
  double _progress = 0.74;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 900));
    _fadeIn = CurvedAnimation(parent: _ctrl, curve: Curves.easeOut);
    _ctrl.forward();

    Future.delayed(const Duration(milliseconds: 2800), () {
      if (mounted) {
        Navigator.of(context).pushReplacement(PageRouteBuilder(
          pageBuilder: (_, __, ___) => const HomeScreen(),
          transitionsBuilder: (_, a, __, child) =>
              FadeTransition(opacity: a, child: child),
          transitionDuration: const Duration(milliseconds: 500),
        ));
      }
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      body: Stack(
        children: [
          // Radial gradient bg  — from-primary/10 via-transparent
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.center,
                  radius: 1.0,
                  colors: [
                    AppColors.primary.withOpacity(0.10),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          // Top 1px gradient line
          Positioned(
            top: 0, left: 0, right: 0,
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(colors: [
                  Colors.transparent,
                  AppColors.primary.withOpacity(0.4),
                  Colors.transparent,
                ]),
              ),
            ),
          ),
          // Main content
          FadeTransition(
            opacity: _fadeIn,
            child: SafeArea(
              child: Column(
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Logo block
                        Stack(
                          alignment: Alignment.center,
                          children: [
                            // Glow blur behind
                            Container(
                              width: 140,
                              height: 140,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: AppColors.primary.withOpacity(0.20),
                              ),
                            ),
                            // Main icon container
                            Container(
                              width: 128,
                              height: 128,
                              decoration: BoxDecoration(
                                color: Colors.black.withOpacity(0.5),
                                borderRadius: BorderRadius.circular(16),
                                border: Border.all(
                                    color: AppColors.primary.withOpacity(0.3),
                                    width: 1.5),
                                boxShadow: [
                                  BoxShadow(
                                    color: AppColors.primary.withOpacity(0.4),
                                    blurRadius: 20,
                                    spreadRadius: 0,
                                  ),
                                ],
                              ),
                              child: Stack(
                                children: [
                                  Center(
                                    child: Icon(Icons.analytics_rounded,
                                        color: AppColors.primary, size: 60),
                                  ),
                                  // Corner decorations (tl)
                                  Positioned(
                                    top: 0, left: 0,
                                    child: Container(
                                      width: 16, height: 16,
                                      decoration: BoxDecoration(
                                        border: Border(
                                          top: BorderSide(color: AppColors.primary, width: 2),
                                          left: BorderSide(color: AppColors.primary, width: 2),
                                        ),
                                        borderRadius: const BorderRadius.only(
                                            topLeft: Radius.circular(8)),
                                      ),
                                    ),
                                  ),
                                  // Corner (br)
                                  Positioned(
                                    bottom: 0, right: 0,
                                    child: Container(
                                      width: 16, height: 16,
                                      decoration: BoxDecoration(
                                        border: Border(
                                          bottom: BorderSide(color: AppColors.primary, width: 2),
                                          right: BorderSide(color: AppColors.primary, width: 2),
                                        ),
                                        borderRadius: const BorderRadius.only(
                                            bottomRight: Radius.circular(8)),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 48),
                        // Title — "Road ANOMALY Detector" uppercase
                        RichText(
                          textAlign: TextAlign.center,
                          text: TextSpan(
                            style: const TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.5,
                              height: 1.1,
                            ),
                            children: [
                              const TextSpan(
                                  text: 'ROAD ',
                                  style: TextStyle(color: AppColors.slateText)),
                              const TextSpan(
                                  text: 'ANOMALY',
                                  style: TextStyle(color: AppColors.primary)),
                              const TextSpan(
                                  text: '\nDETECTOR',
                                  style: TextStyle(color: AppColors.slateText)),
                            ],
                          ),
                        ),
                        const SizedBox(height: 16),
                        // Subtitle
                        const Text(
                          'AI-POWERED ROAD DAMAGE DETECTION',
                          style: TextStyle(
                            color: AppColors.slate400,
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 3.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Loading section at bottom
                  Padding(
                    padding: const EdgeInsets.fromLTRB(48, 0, 48, 48),
                    child: Column(
                      children: [
                        // Label + percentage
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              'INITIALIZING CORE AI',
                              style: TextStyle(
                                color: AppColors.primary.withOpacity(0.8),
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 2,
                              ),
                            ),
                            Text(
                              '74%',
                              style: TextStyle(
                                color: AppColors.primary.withOpacity(0.8),
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 2,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        // Progress bar
                        ClipRRect(
                          borderRadius: BorderRadius.circular(99),
                          child: Container(
                            height: 4,
                            color: AppColors.slate800,
                            child: FractionallySizedBox(
                              alignment: Alignment.centerLeft,
                              widthFactor: _progress,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: AppColors.primary,
                                  borderRadius: BorderRadius.circular(99),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.primary.withOpacity(0.4),
                                      blurRadius: 8,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        // Step indicators row
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            _StepItem(icon: Icons.sensors, label: 'SENSOR\nARRAY'),
                            const SizedBox(width: 28),
                            _StepItem(icon: Icons.satellite_alt_outlined, label: 'GPS\nLINK'),
                            const SizedBox(width: 28),
                            _StepItem(icon: Icons.memory_outlined, label: 'NEURAL\nENGINE'),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepItem extends StatelessWidget {
  final IconData icon;
  final String label;
  const _StepItem({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: 0.4,
      child: Row(
        children: [
          Icon(icon, size: 14, color: AppColors.slateText),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: AppColors.slateText,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
  }
}
