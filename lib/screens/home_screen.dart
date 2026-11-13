import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../widgets/icon_button.dart';
import '../widgets/stat_row.dart';
import 'live_detection_screen.dart';
import 'upload_screen.dart';
import 'settings_screen.dart';
import 'about_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDark2,
      body: Column(
        children: [
          // Sticky AppBar — bg-background-dark/80 backdrop-blur border-b border-slate-800
          _AppBar(context),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // "Control Center" heading
                  const Text(
                    'Control Center',
                    style: TextStyle(
                      color: AppColors.white,
                      fontSize: 36,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Select an inspection mode to begin real-time analysis.',
                    style: TextStyle(
                      color: AppColors.slate400,
                      fontSize: 14,
                    ),
                  ),
                  const SizedBox(height: 32),

                  // Live Detection Card
                  _ModeCard(
                    heroIcon: Icons.videocam_outlined,
                    title: 'Live Detection',
                    showLiveBadge: true,
                    subtitle:
                        'Detect road anomalies like potholes and cracks using real-time camera feed from your vehicle.',
                    buttonLabel: 'Start Detection',
                    buttonIcon: Icons.sensors_outlined,
                    buttonPrimary: true,
                    onPressed: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const LiveDetectionScreen())),
                  ),
                  const SizedBox(height: 24),

                  // Upload Media Card
                  _ModeCard(
                    heroIcon: Icons.upload_file_outlined,
                    title: 'Upload Media',
                    showLiveBadge: false,
                    subtitle:
                        'Upload existing images or high-resolution video recordings for deep AI analysis and reporting.',
                    buttonLabel: 'Upload Media',
                    buttonIcon: Icons.cloud_upload_outlined,
                    buttonPrimary: true,
                    onPressed: () => Navigator.push(context,
                        MaterialPageRoute(builder: (_) => const UploadScreen())),
                  ),
                  const SizedBox(height: 32),

                  // Stats row — grid-cols-3
                  StatsRow(),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _AppBar(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.backgroundDark2.withOpacity(0.85),
        border: const Border(
          bottom: BorderSide(
            color: Color(0xFF1E293B),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              // Logo
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppColors.primary.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.analytics_rounded,
                  color: AppColors.primary,
                  size: 22,
                ),
              ),

              const SizedBox(width: 12),

              // Title
              const Expanded(
                child: Text(
                  "Road Anomaly Detection",
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppColors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.2,
                  ),
                ),
              ),

              // Info Button
              IconBtn(
                icon: Icons.info_outline,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const AboutScreen()),
                ),
              ),

              const SizedBox(width: 6),

              // Settings Button
              IconBtn(
                icon: Icons.settings_outlined,
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}



class _ModeCard extends StatefulWidget {
  final IconData heroIcon;
  final String title;
  final bool showLiveBadge;
  final String subtitle;
  final String buttonLabel;
  final IconData buttonIcon;
  final bool buttonPrimary;
  final VoidCallback onPressed;

  const _ModeCard({
    required this.heroIcon,
    required this.title,
    required this.showLiveBadge,
    required this.subtitle,
    required this.buttonLabel,
    required this.buttonIcon,
    required this.buttonPrimary,
    required this.onPressed,
  });

  @override
  State<_ModeCard> createState() => _ModeCardState();
}

class _ModeCardState extends State<_ModeCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (_) => setState(() => _hovered = true),
      onTapUp: (_) {
        setState(() => _hovered = false);
        widget.onPressed();
      },
      onTapCancel: () => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: AppColors.cardDark2,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _hovered
                ? AppColors.primary.withOpacity(0.4)
                : const Color(0xFF1E293B),
            width: 1,
          ),
          boxShadow: _hovered
              ? [
                  BoxShadow(
                    color: AppColors.primary.withOpacity(0.15),
                    blurRadius: 20,
                    spreadRadius: 0,
                  )
                ]
              : [],
        ),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Hero image area — aspect-video
              AspectRatio(
                aspectRatio: 16 / 9,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    color: AppColors.slate800.withOpacity(0.5),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // gradient overlay
                        Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                AppColors.primary.withOpacity(0.20),
                                Colors.transparent,
                              ],
                            ),
                          ),
                        ),
                        Center(
                          child: Icon(widget.heroIcon,
                              size: 56,
                              color: _hovered
                                  ? AppColors.primary
                                  : AppColors.primary.withOpacity(0.5)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Title + LIVE badge
                    Row(
                      children: [
                        Text(
                          widget.title,
                          style: const TextStyle(
                            color: AppColors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (widget.showLiveBadge) ...[
                          const SizedBox(width: 10),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0x1AEF4444),
                              borderRadius: BorderRadius.circular(99),
                              border: Border.all(
                                  color: const Color(0x33EF4444), width: 1),
                            ),
                            child: const Text(
                              'LIVE',
                              style: TextStyle(
                                color: Color(0xFFEF4444),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.subtitle,
                      style: const TextStyle(
                        color: AppColors.slate400,
                        fontSize: 14,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 20),
                    // Button
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: widget.onPressed,
                        icon: Icon(widget.buttonIcon, size: 20),
                        label: Text(widget.buttonLabel),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: widget.buttonPrimary
                              ? AppColors.primary
                              : AppColors.slate800,
                          foregroundColor: widget.buttonPrimary
                              ? AppColors.white
                              : AppColors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          elevation: 0,
                          textStyle: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

