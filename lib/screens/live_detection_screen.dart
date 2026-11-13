import 'package:camera/camera.dart';
import 'package:flutter/material.dart';

import '../services/inference_isolate.dart';
import '../services/model_service.dart';
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
  bool _isIsolateReady = false;

  double _fps = 0;
  double _cpu = 12;

  DateTime _lastInference = DateTime.now();
  final Duration _inferenceInterval = const Duration(milliseconds: 120);

  @override
  void initState() {
    super.initState();
    _initAll();
  }

  Future<void> _initAll() async {
    await _initIsolate();
    await _initializeCamera();
  }

  Future<void> _initIsolate() async {
    try {
      final modelBytes = await ModelService.loadModelBytes();
      await _inferenceIsolate.start(modelBytes);
      _isIsolateReady = true;
      debugPrint("Live isolate ready");
    } catch (e) {
      debugPrint("Isolate init error: $e");
    }
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
    if (!_isDetecting || !_isIsolateReady) return;

    final now = DateTime.now();
    if (now.difference(_lastInference) < _inferenceInterval) return;
    if (_isProcessing) return;

    _isProcessing = true;
    final start = DateTime.now();

    try {
      final planeY = image.planes[0];
      final planeU = image.planes[1];
      final planeV = image.planes[2];

      // 🔥 Send lightweight raw bytes to background without blocking UI
      _inferenceIsolate.runFromCamera(
        image.width,
        image.height,
        planeY.bytes,
        planeU.bytes,
        planeV.bytes,
        planeU.bytesPerRow,
        planeU.bytesPerPixel!,
      ).then((detections) {
        if (mounted && _isDetecting) {
          final smoothed = _smoothDetections(detections);
          final end = DateTime.now();
          final frameTime = end.difference(start).inMilliseconds;

          setState(() {
            _detections = smoothed;
            _fps = frameTime > 0 ? 1000 / frameTime : 0;
          });
        }
        _lastInference = DateTime.now();
        _isProcessing = false;
      }).catchError((e) {
        debugPrint("Detection error: $e");
        _isProcessing = false;
      });

    } catch (e) {
      debugPrint("Stream extraction error: $e");
      _isProcessing = false;
    }
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

  // UPDATED: Now scales to the internal camera aspect ratio container rather than the screen
  Rect _scaleBox(Rect box, double innerWidth, double innerHeight) {
    const modelSize = 640.0; // Assuming 640x640 YOLO input
    final scaleX = innerWidth / modelSize;
    final scaleY = innerHeight / modelSize;

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
          if (_cameraController != null && _cameraController!.value.isInitialized)
            _buildCameraFeedWithBBoxes(), // UPDATED: Replaced direct Positioned.fill

          _header(),
          _statsPanel(screenSize),
          _controlButton(screenSize),
        ],
      ),
    );
  }

  // NEW METHOD: Handles the native, un-squeezed camera view and aligned bounding boxes
  Widget _buildCameraFeedWithBBoxes() {
    final size = MediaQuery.of(context).size;
    final cameraRatio = _cameraController!.value.aspectRatio;

    // We set an arbitrary base dimension for the inner canvas.
    // The FittedBox will scale this up perfectly to the actual screen size.
    const double baseDimension = 1000.0;
    final double innerWidth = baseDimension;
    final double innerHeight = baseDimension * cameraRatio;

    return SizedBox(
      width: size.width,
      height: size.height,
      child: FittedBox(
        fit: BoxFit.cover, // Scales up to fill screen, cropping edges without squeezing
        child: SizedBox(
          width: innerWidth,
          height: innerHeight,
          child: Stack(
            children: [
              // 1. The Camera Feed
              Positioned.fill(
                child: CameraPreview(_cameraController!),
              ),

              // 2. The Bounding Boxes
              ..._detections.map((det) {
                // Scale boxes relative to the inner container, NOT the screen
                final box = _scaleBox(det.boundingBox, innerWidth, innerHeight);
                return Positioned(
                  left: box.left,
                  top: box.top,
                  width: box.width,
                  height: box.height,
                  child: _BBox(
                    label: "${det.label} ${(det.confidence * 100).toStringAsFixed(1)}%",
                  ),
                );
              }),
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() {
    return Positioned(
      top: 0, left: 0, right: 0,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Row(
            children: [
              GestureDetector(
                onTap: () => Navigator.pop(context),
                child: _circleButton(Icons.arrow_back),
              ),
              const SizedBox(width: 12),
              const Row(
                children: [
                  Icon(Icons.circle, size: 10, color: Colors.green),
                  SizedBox(width: 6),
                  Text("SYSTEM ACTIVE",
                    style: TextStyle(
                      color: Colors.green, fontWeight: FontWeight.bold, fontSize: 12,
                    ),
                  )
                ],
              ),
              const Spacer(),
              _circleButton(Icons.settings),
            ],
          ),
        ),
      ),
    );
  }

  Widget _circleButton(IconData icon) {
    return Container(
      width: 40, height: 40,
      decoration: BoxDecoration(
        color: Colors.black.withOpacity(0.35), shape: BoxShape.circle,
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
        color: Colors.black.withOpacity(0.45), borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Text(title, style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 6),
          Text(value,
              style: const TextStyle(color: Colors.greenAccent, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _controlButton(Size screenSize) {
    return Positioned(
      bottom: screenSize.height * 0.05,
      left: screenSize.width * 0.1, right: screenSize.width * 0.1,
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
                ),
                const SizedBox(width: 10),
                Text(
                  _isDetecting ? "STOP DETECTION" : "START DETECTION",
                  style: const TextStyle(color: Colors.white),
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
        border: Border.all(color: AppColors.neonGreen, width: 2),
      ),
      child: Align(
        alignment: Alignment.topLeft,
        child: Container(
          color: AppColors.neonGreen,
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          child: Text(
            label,
            style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.black),
          ),
        ),
      ),
    );
  }
}