import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../widgets/info_row.dart';
import '../widgets/tunnel_painter.dart';

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      body: Column(
        children: [
          // ── Header ──
          SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: AppColors.primary.withOpacity(0.10),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(Icons.arrow_back,
                          color: AppColors.slateText, size: 20),
                    ),
                  ),
                  const Expanded(
                    child: Text('About',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.slateText,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        )),
                  ),
                  const SizedBox(width: 40), // balance
                ],
              ),
            ),
          ),

          // ── Scrollable body ──
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  // Hero image section — px-6 py-4
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
                    child: Stack(
                      children: [
                        // Glow behind
                        Positioned.fill(
                          child: Container(
                            margin: const EdgeInsets.all(4),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(16),
                              gradient: LinearGradient(
                                colors: [
                                  AppColors.primary.withOpacity(0.25),
                                  const Color(0xFF2563EB).withOpacity(0.25),
                                ],
                              ),
                            ),
                          ),
                        ),
                        // Image card
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: AspectRatio(
                            aspectRatio: 16 / 9,
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                CustomPaint(painter: TunnelPainter()),
                                Container(
                                  decoration: const BoxDecoration(
                                    gradient: LinearGradient(
                                      begin: Alignment.topCenter,
                                      end: Alignment.bottomCenter,
                                      colors: [Colors.transparent, Color(0xCC111821)],
                                    ),
                                  ),
                                ),
                                // Version badge
                                Positioned(
                                  bottom: 16, left: 16,
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 12, vertical: 6),
                                    decoration: BoxDecoration(
                                      color: AppColors.primary,
                                      borderRadius: BorderRadius.circular(99),
                                    ),
                                    child: const Text(
                                      'VERSION 1.0.0',
                                      style: TextStyle(
                                        color: AppColors.white,
                                        fontSize: 11,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 2,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // App Identity — pt-6 pb-2 text-center
                  const Padding(
                    padding: EdgeInsets.fromLTRB(24, 24, 24, 8),
                    child: Column(
                      children: [
                        Text(
                          'Road Anomaly Detector',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: AppColors.slateText,
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.3,
                          ),
                        ),
                        SizedBox(height: 8),
                        // Blue underline bar
                        SizedBox(
                          width: 48, height: 4,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: AppColors.primary,
                              borderRadius: BorderRadius.all(Radius.circular(99)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Description
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24, vertical: 16),
                    child: Text(
                      'An AI-powered mobile system for detecting road defects such as potholes and cracks using a deep learning model.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: AppColors.slate400,
                        fontSize: 15,
                        height: 1.6,
                      ),
                    ),
                  ),

                  // Technical detail cards — px-6 space-y-3
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 8, 24, 32),
                    child: Column(
                      children: const [
                        InfoRow(
                          icon: Icons.memory_outlined,
                          topLabel: 'MODEL USED',
                          value: 'YOLOv11s',
                        ),
                        SizedBox(height: 12),
                        InfoRow(
                          icon: Icons.person_outline_rounded,
                          topLabel: 'DEVELOPER',
                          value: 'Shatrunjaypratapsinh Gohil',
                        ),
                        SizedBox(height: 12),
                        InfoRow(
                          icon: Icons.verified_outlined,
                          topLabel: 'LICENSE',
                          value: 'Academic Research License',
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



// ─── Tunnel painter ──────────────────────────────────────────────────────

