import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../services/inference_isolate.dart';
import '../models/detection.dart';
import '../theme/app_theme.dart';

class LiveDetectionScreen extends StatefulWidget {
  const LiveDetectionScreen({super.key});

  @override
  State<LiveDetectionScreen> createState() => _LiveDetectionScreenState();
}

class _LiveDetectionScreenState extends State<LiveDetectionScreen> {

  CameraController? _cameraController;
  final InferenceIsolate _inferenceIsolate = InferenceIsolate();

  List<Detection> _detections = [];
  List<Detection> _previousDetections = [];

  bool _isProcessing = false;
  bool _isDetecting = false;

  double _fps = 0;
  double _cpu = 12;

  DateTime _lastInference = DateTime.now();
  final Duration _inferenceInterval = const Duration(milliseconds: 120);

  @override
  void initState() {
    super.initState();
    _initializeCamera();
    _inferenceIsolate.start();
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _inferenceIsolate.dispose();
    super.dispose();
  }

  Future<void> _initializeCamera() async {

    final cameras = await availableCameras();

    _cameraController = CameraController(
      cameras.first,
      ResolutionPreset.medium,
      enableAudio: false,
    );

    await _cameraController!.initialize();
    await _cameraController!.startImageStream(_processFrame);

    setState(() {});
  }

  Future<void> _processFrame(CameraImage image) async {

    if (!_isDetecting) return;

    final now = DateTime.now();

    if (now.difference(_lastInference) < _inferenceInterval) return;
    if (_isProcessing) return;

    _isProcessing = true;

    try {

      final start = DateTime.now();

      final img.Image rgb = _convertCameraImage(image);

      final detections = await _inferenceIsolate.run(rgb);

      final smoothed = _smoothDetections(detections);

      final end = DateTime.now();
      final frameTime = end.difference(start).inMilliseconds;

      setState(() {
        _detections = smoothed;
        _fps = 1000 / frameTime;
      });

      _lastInference = DateTime.now();

    } catch (e) {
      debugPrint("Detection error: $e");
    }

    _isProcessing = false;
  }

  img.Image _convertCameraImage(CameraImage cameraImage) {

    final width = cameraImage.width;
    final height = cameraImage.height;

    final img.Image imgBuffer = img.Image(width: width, height: height);

    final planeY = cameraImage.planes[0];
    final planeU = cameraImage.planes[1];
    final planeV = cameraImage.planes[2];

    final uvRowStride = planeU.bytesPerRow;
    final uvPixelStride = planeU.bytesPerPixel!;

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {

        final uvIndex =
            uvPixelStride * (x ~/ 2) + uvRowStride * (y ~/ 2);

        final index = y * width + x;

        final yp = planeY.bytes[index];
        final up = planeU.bytes[uvIndex];
        final vp = planeV.bytes[uvIndex];

        int r = (yp + vp * 1436 / 1024 - 179).round();
        int g = (yp - up * 46549 / 131072 + 44 - vp * 93604 / 131072 + 91).round();
        int b = (yp + up * 1814 / 1024 - 227).round();

        r = r.clamp(0, 255);
        g = g.clamp(0, 255);
        b = b.clamp(0, 255);

        imgBuffer.setPixelRgb(x, y, r, g, b);
      }
    }

    return imgBuffer;
  }

  List<Detection> _smoothDetections(List<Detection> newDetections) {

    if (_previousDetections.isEmpty) {
      _previousDetections = newDetections;
      return newDetections;
    }

    List<Detection> smoothed = [];

    for (int i = 0; i < newDetections.length; i++) {

      if (i >= _previousDetections.length) {
        smoothed.add(newDetections[i]);
        continue;
      }

      final oldBox = _previousDetections[i].boundingBox;
      final newBox = newDetections[i].boundingBox;

      final smoothBox = Rect.fromLTWH(
        oldBox.left * 0.7 + newBox.left * 0.3,
        oldBox.top * 0.7 + newBox.top * 0.3,
        oldBox.width * 0.7 + newBox.width * 0.3,
        oldBox.height * 0.7 + newBox.height * 0.3,
      );

      smoothed.add(
        Detection(
          label: newDetections[i].label,
          confidence: newDetections[i].confidence,
          boundingBox: smoothBox,
        ),
      );
    }

    _previousDetections = smoothed;
    return smoothed;
  }

  Rect _scaleBox(Rect box, Size screenSize) {

    const modelSize = 640;

    final scaleX = screenSize.width / modelSize;
    final scaleY = screenSize.height / modelSize;

    return Rect.fromLTWH(
      box.left * scaleX,
      box.top * scaleY,
      box.width * scaleX,
      box.height * scaleY,
    );
  }

  void _toggleDetection() {

    setState(() {

      _isDetecting = !_isDetecting;

      if (!_isDetecting) {
        _detections.clear();
        _previousDetections.clear();
      }
    });
  }

  @override
  Widget build(BuildContext context) {

    final screenSize = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: Colors.black,
      extendBodyBehindAppBar: true,
      body: Stack(
        children: [

          if (_cameraController != null &&
              _cameraController!.value.isInitialized)
            Positioned.fill(
              child: CameraPreview(_cameraController!),
            ),

          ..._detections.map((det) {

            final box = _scaleBox(det.boundingBox, screenSize);

            return Positioned(
              left: box.left,
              top: box.top,
              width: box.width,
              height: box.height,
              child: _BBox(
                label:
                "${det.label} ${(det.confidence * 100).toStringAsFixed(1)}%",
              ),
            );
          }),

          _header(),

          _statsPanel(screenSize),

          _controlButton(screenSize),
        ],
      ),
    );
  }

  Widget _header() {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              /// Back
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: _circleButton(Icons.arrow_back),
              ),

              const SizedBox(width: 12),

              const Row(
                children: [
                  Icon(Icons.circle, size: 10, color: Colors.green),
                  SizedBox(width: 6),
                  Text(
                    "SYSTEM ACTIVE",
                    style: TextStyle(
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      letterSpacing: 1.2,
                    ),
                  )
                ],
              ),

              const Spacer(),

              /// Settings
              _circleButton(Icons.settings),
            ],
          ),
        ),
      ),
    );
  }

  Widget _circleButton(IconData icon) {
    return Container(
      width: 40,
      height: 40,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.35),
        shape: BoxShape.circle,
      ),
      child: Icon(icon, color: Colors.white),
    );
  }

  Widget _statsPanel(Size screenSize) {
    return Positioned(
      right: screenSize.width * 0.04,
      top: screenSize.height * 0.25,
      child: Column(
        children: [
          _statCard("FPS", _fps.toStringAsFixed(1)),
          const SizedBox(height: 12),
          _statCard("CPU", "${_cpu.toStringAsFixed(0)}%"),
        ],
      ),
    );
  }

  Widget _statCard(String title, String value) {
    return Container(
      width: 85,
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.45),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Colors.white54,
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: Colors.greenAccent,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _controlButton(Size screenSize) {
    return Positioned(
      bottom: screenSize.height * 0.05,
      left: screenSize.width * 0.1,
      right: screenSize.width * 0.1,
      child: GestureDetector(
        onTap: _toggleDetection,
        child: Container(
          height: 65,
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: _isDetecting
                  ? [Colors.redAccent, Colors.red]
                  : [Colors.blueAccent, Colors.blue],
            ),
            borderRadius: BorderRadius.circular(40),
          ),
          child: Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isDetecting ? Icons.stop_circle : Icons.play_circle_fill,
                  color: Colors.white,
                  size: 26,
                ),
                const SizedBox(width: 10),
                Text(
                  _isDetecting ? "STOP DETECTION" : "START DETECTION",
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.2,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BBox extends StatelessWidget {

  final String label;

  const _BBox({required this.label});

  @override
  Widget build(BuildContext context) {

    return Container(
      decoration: BoxDecoration(
        border: Border.all(
          color: AppColors.neonGreen,
          width: 2,
        ),
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: Container(
          padding:
          const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          color: AppColors.neonGreen,
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.bold,
              color: Colors.black,
            ),
          ),
        ),
      ),
    );
  }
}