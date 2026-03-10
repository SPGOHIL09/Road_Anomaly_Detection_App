import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import 'home_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  bool _gpuAcceleration = true;
  bool _boundingBoxLabels = true;
  bool _audioNotifications = false;
  double _confidence = 0.75;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      body: Column(
        children: [
          // ── Sticky Header ──
          SafeArea(
            bottom: false,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              color: AppColors.backgroundDark,
              child: Row(
                children: [
                  // Back
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: SizedBox(
                      width: 48, height: 48,
                      child: const Icon(Icons.arrow_back, color: AppColors.slateText),
                    ),
                  ),
                  const Expanded(
                    child: Text('Settings',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: AppColors.slateText,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        )),
                  ),
                  // Memory icon (right)
                  SizedBox(
                    width: 48, height: 48,
                    child: const Icon(Icons.memory_outlined, color: AppColors.primary),
                  ),
                ],
              ),
            ),
          ),

          // ── Scrollable content ──
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── DETECTION ENGINE ──
                  _SectionLabel('DETECTION ENGINE'),
                  const SizedBox(height: 12),

                  // GPU Acceleration card
                  _Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text('GPU Acceleration',
                                      style: TextStyle(
                                          color: AppColors.slateText,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600)),
                                  SizedBox(height: 4),
                                  Text('Utilize neural engine for real-time processing',
                                      style: TextStyle(
                                          color: AppColors.slate400, fontSize: 12)),
                                ],
                              ),
                            ),
                            Switch(
                              value: _gpuAcceleration,
                              onChanged: (v) =>
                                  setState(() => _gpuAcceleration = v),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        // Circuit board image placeholder — aspect 21/9
                        AspectRatio(
                          aspectRatio: 21 / 9,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              decoration: BoxDecoration(
                                color: AppColors.accentDark,
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(color: AppColors.accentDark),
                              ),
                              child: CustomPaint(
                                  painter: _CircuitPainter()),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 16),

                  // Confidence threshold card
                  _Card(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            const Text('Detection Confidence',
                                style: TextStyle(
                                    color: AppColors.slateText,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600)),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 5),
                              decoration: BoxDecoration(
                                color: AppColors.primary.withOpacity(0.10),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                _confidence.toStringAsFixed(2),
                                style: const TextStyle(
                                    color: AppColors.primary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Slider(
                          value: _confidence,
                          min: 0, max: 1,
                          onChanged: (v) => setState(() => _confidence = v),
                        ),
                        const Text(
                          'Minimum score to trigger an anomaly alert',
                          style: TextStyle(color: AppColors.slate400, fontSize: 12),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // ── VISUAL INTERFACE ──
                  _SectionLabel('VISUAL INTERFACE'),
                  const SizedBox(height: 12),

                  // Bounding box + Audio in one card
                  Container(
                    decoration: BoxDecoration(
                      color: AppColors.cardDark,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: AppColors.accentDark.withOpacity(0.3)),
                    ),
                    child: Column(
                      children: [
                        // Bounding Box Labels
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 18),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Bounding Box Labels',
                                        style: TextStyle(
                                            color: AppColors.slateText,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600)),
                                    SizedBox(height: 4),
                                    Text('Display class names on detections',
                                        style: TextStyle(
                                            color: AppColors.slate400,
                                            fontSize: 12)),
                                  ],
                                ),
                              ),
                              Switch(
                                value: _boundingBoxLabels,
                                onChanged: (v) =>
                                    setState(() => _boundingBoxLabels = v),
                              ),
                            ],
                          ),
                        ),
                        Divider(
                            height: 1,
                            color: AppColors.accentDark.withOpacity(0.3)),
                        // Audio Notifications
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 18),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text('Audio Notifications',
                                        style: TextStyle(
                                            color: AppColors.slateText,
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600)),
                                    SizedBox(height: 4),
                                    Text('Voice alert when anomaly is detected',
                                        style: TextStyle(
                                            color: AppColors.slate400,
                                            fontSize: 12)),
                                  ],
                                ),
                              ),
                              Switch(
                                value: _audioNotifications,
                                onChanged: (v) =>
                                    setState(() => _audioNotifications = v),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 24),

                  // ── STORAGE & LOGS ──
                  _SectionLabel('STORAGE & LOGS'),
                  const SizedBox(height: 12),

                  _Card(
                    child: Row(
                      children: [
                        Container(
                          width: 40, height: 40,
                          decoration: BoxDecoration(
                            color: AppColors.primary.withOpacity(0.10),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(Icons.storage_outlined,
                              color: AppColors.primary, size: 20),
                        ),
                        const SizedBox(width: 12),
                        const Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Incident History',
                                  style: TextStyle(
                                      color: AppColors.slateText,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600)),
                              Text('2.4 GB used',
                                  style: TextStyle(
                                      color: AppColors.slate400, fontSize: 12)),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () {},
                          child: const Text('Clear All',
                              style: TextStyle(
                                  color: AppColors.primary,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w700)),
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

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: const TextStyle(
          color: AppColors.slate400,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 2.5,
        ),
      ),
    );
  }
}

class _Card extends StatelessWidget {
  final Widget child;
  const _Card({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppColors.cardDark,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.accentDark.withOpacity(0.3)),
      ),
      child: child,
    );
  }
}



class _CircuitPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = const Color(0xFF0A1520));

    final p = Paint()
      ..color = const Color(0xFF1A3A1A)
      ..strokeWidth = 2;

    final cx = size.width / 2, cy = size.height / 2;
    const chipW = 50.0, chipH = 30.0;

    // Chip body
    canvas.drawRect(
        Rect.fromCenter(center: Offset(cx, cy), width: chipW, height: chipH),
        Paint()..color = const Color(0xFF1A3A1A));
    canvas.drawRect(
        Rect.fromCenter(center: Offset(cx, cy), width: chipW, height: chipH),
        Paint()
          ..color = const Color(0xFF2A6A2A)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5);

    // Trace lines from chip edges
    final traces = [
      [Offset(cx - chipW / 2, cy - 8), Offset(cx - chipW / 2 - 25, cy - 8)],
      [Offset(cx - chipW / 2, cy + 4), Offset(cx - chipW / 2 - 25, cy + 4)],
      [Offset(cx + chipW / 2, cy - 8), Offset(cx + chipW / 2 + 25, cy - 8)],
      [Offset(cx + chipW / 2, cy + 4), Offset(cx + chipW / 2 + 25, cy + 4)],
      [Offset(cx - 12, cy - chipH / 2), Offset(cx - 12, cy - chipH / 2 - 15)],
      [Offset(cx + 4, cy - chipH / 2), Offset(cx + 4, cy - chipH / 2 - 15)],
      [Offset(cx - 12, cy + chipH / 2), Offset(cx - 12, cy + chipH / 2 + 15)],
      [Offset(cx + 4, cy + chipH / 2), Offset(cx + 4, cy + chipH / 2 + 15)],
    ];

    for (final t in traces) {
      canvas.drawLine(t[0], t[1], p);
      canvas.drawCircle(t[1], 2.5,
          Paint()..color = const Color(0xFFD4A017));
    }

    // Center label
    const textStyle = TextStyle(
        color: Color(0xFF2A9A2A), fontSize: 8, fontWeight: FontWeight.w700);
    final tp = TextPainter(
        text: const TextSpan(text: 'NEURAL\nENGINE', style: textStyle),
        textAlign: TextAlign.center,
        textDirection: TextDirection.ltr)
      ..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
  }

  @override
  bool shouldRepaint(_) => false;
}
