import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../services/live/detection_tracker.dart';
import '../services/live/live_frame.dart';
import '../services/live/live_inference_isolate.dart';
import '../services/model_service.dart';
import '../models/detection.dart';
import '../theme/app_theme.dart';

/// Live camera detection. Uses its own pipeline under `services/live/`
/// (separate from the upload pipeline): camera frame -> [LiveFrame] ->
/// [LiveInferenceIsolate] -> [DetectionTracker] -> overlay.
class LiveDetectionScreen extends StatefulWidget {
  const LiveDetectionScreen({super.key});

  @override
  State<LiveDetectionScreen> createState() => _LiveDetectionScreenState();
}

class _LiveDetectionScreenState extends State<LiveDetectionScreen> {
  CameraController? _cameraController;
  CameraDescription? _camera;
  final LiveInferenceIsolate _inferenceIsolate = LiveInferenceIsolate();
  final DetectionTracker _tracker = DetectionTracker();

  /// Boxes normalized (0..1) to the upright camera frame.
  List<Detection> _detections = [];

  bool _isProcessing = false;
  bool _isDetecting = false;
  bool _isIsolateReady = false;
  bool _disposed = false;
  bool _loggedFirstFrame = false;
  String? _error;

  double _fps = 0;
  double _cpu = 12;

  DateTime _lastInference = DateTime.now();
  DateTime? _lastResultAt;
  final Duration _inferenceInterval = const Duration(milliseconds: 120);

  /// Incremented when detection stops so late results are discarded.
  int _session = 0;

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
      if (mounted) setState(() => _error = "Model failed to load: $e");
    }
  }

  @override
  void dispose() {
    _disposed = true;
    final controller = _cameraController;
    _cameraController = null;
    if (controller != null) {
      if (controller.value.isStreamingImages) {
        controller.stopImageStream().catchError((_) {});
      }
      controller.dispose();
    }
    _inferenceIsolate.dispose();
    super.dispose();
  }

  Future<void> _initializeCamera() async {
    try {
      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        if (mounted) setState(() => _error = "No camera found on this device");
        return;
      }
      _camera = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );

      final controller = CameraController(
        _camera!,
        ResolutionPreset.medium,
        enableAudio: false,
        // Android streams YUV planes, iOS streams a single BGRA plane.
        imageFormatGroup: Platform.isIOS
            ? ImageFormatGroup.bgra8888
            : ImageFormatGroup.yuv420,
      );
      await controller.initialize();
      if (_disposed) {
        controller.dispose();
        return;
      }
      _cameraController = controller;
      await controller.startImageStream(_processFrame);
      if (mounted) setState(() {});
    } on CameraException catch (e) {
      debugPrint("Camera error: ${e.code} ${e.description}");
      if (mounted) {
        setState(
          () => _error = e.code == 'CameraAccessDenied'
              ? "Camera permission denied. Enable it in Settings."
              : "Camera error: ${e.description ?? e.code}",
        );
      }
    } catch (e) {
      debugPrint("Camera error: $e");
      if (mounted) setState(() => _error = "Camera error: $e");
    }
  }

  void _processFrame(CameraImage image) {
    if (!_isDetecting || !_isIsolateReady || _isProcessing) return;

    final now = DateTime.now();
    if (now.difference(_lastInference) < _inferenceInterval) return;

    final camera = _camera;
    if (camera == null) return;

    final frame = LiveFrame.fromCameraImage(
      image,
      sensorOrientation: camera.sensorOrientation,
      mirror: camera.lensDirection == CameraLensDirection.front,
    );
    if (frame == null) {
      debugPrint("Unsupported camera format: ${image.format.group}");
      return;
    }

    if (!kReleaseMode && !_loggedFirstFrame) {
      _loggedFirstFrame = true;
      debugPrint(
        "📷 live: first frame ${image.width}x${image.height} "
        "${image.format.group.name}, planes=${image.planes.length}, "
        "rotation=${frame.rotation}",
      );
    }

    _isProcessing = true;
    _lastInference = now;
    final session = _session;

    // 🔥 Heavy work (colour conversion, resize, inference) runs in the
    // live isolate; the UI thread only hands over the plane buffers.
    _inferenceIsolate
        .process(frame)
        .then((result) {
          if (!mounted || !_isDetecting || session != _session) return;
          if (!kReleaseMode) {
            debugPrint(
              "📷 live: ${result.detections.length} detections "
              "(${result.inferenceMs}ms)",
            );
          }
          final smoothed = _tracker.update(result.detections);
          final at = DateTime.now();
          final last = _lastResultAt;
          _lastResultAt = at;
          setState(() {
            _detections = smoothed;
            if (last != null) {
              final instant =
                  1000 / at.difference(last).inMilliseconds.clamp(1, 100000);
              _fps = _fps == 0 ? instant : _fps * 0.7 + instant * 0.3;
            }
          });
        })
        .catchError((e) {
          debugPrint("Detection error: $e");
        })
        .whenComplete(() {
          _isProcessing = false;
        });
  }

  void _toggleDetection() {
    setState(() {
      _isDetecting = !_isDetecting;
      _session++;
      _detections = [];
      _tracker.reset();
      _lastResultAt = null;
      _fps = 0;
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
            _buildCameraFeedWithBBoxes(),

          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white70, fontSize: 16),
                ),
              ),
            ),

          _header(),
          _statsPanel(screenSize),
          _controlButton(screenSize),
        ],
      ),
    );
  }

  /// Camera preview and boxes share one portrait canvas with the preview's
  /// aspect ratio, scaled to cover the screen, so boxes stay aligned.
  Widget _buildCameraFeedWithBBoxes() {
    final size = MediaQuery.of(context).size;
    final previewRatio = _cameraController!.value.aspectRatio; // landscape w/h

    const double baseDimension = 1000.0;
    const double innerWidth = baseDimension;
    final double innerHeight = baseDimension * previewRatio;

    return SizedBox(
      width: size.width,
      height: size.height,
      child: FittedBox(
        fit: BoxFit.cover,
        child: SizedBox(
          width: innerWidth,
          height: innerHeight,
          child: Stack(
            children: [
              Positioned.fill(child: CameraPreview(_cameraController!)),
              ..._detections.map((det) {
                final b = det.boundingBox; // normalized to upright frame
                return Positioned(
                  left: b.left * innerWidth,
                  top: b.top * innerHeight,
                  width: b.width * innerWidth,
                  height: b.height * innerHeight,
                  child: _BBox(
                    label:
                        "${det.label} ${(det.confidence * 100).toStringAsFixed(1)}%",
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
      top: 0,
      left: 0,
      right: 0,
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
                  Text(
                    "SYSTEM ACTIVE",
                    style: TextStyle(
                      color: Colors.green,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
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
          Text(title, style: const TextStyle(color: Colors.white54)),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: Colors.greenAccent,
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
