import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;

import 'package:road_anomaly_detector/theme/app_theme.dart';
import 'package:road_anomaly_detector/services/model_service.dart';
import 'package:road_anomaly_detector/models/detection.dart';
import 'package:road_anomaly_detector/services/inference_isolate.dart';

class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen> {
  bool _hasFile = false;
  bool _detecting = false;
  bool _isProcessingFrame = false;

  File? _selectedFile;
  bool _isVideo = false;

  List<Detection> _detections = [];

  final InferenceIsolate _isolate = InferenceIsolate();
  bool _isIsolateReady = false;

  img.Image? _currentImage;
  ui.Image? _currentUiImage;

  @override
  void initState() {
    super.initState();
    _initIsolate();
  }

  Future<void> _initIsolate() async {
    final modelBytes = await ModelService.loadModelBytes();
    await _isolate.start(modelBytes);
    if (mounted) setState(() => _isIsolateReady = true);
  }

  @override
  void dispose() {
    _currentUiImage?.dispose();
    _isolate.dispose();
    super.dispose();
  }

  // ───────── PICK FILE & GENERATE THUMBNAIL ─────────

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.media);
    if (result == null) return;

    final file = File(result.files.single.path!);
    final extension = result.files.single.extension?.toLowerCase();

    _isVideo = extension == "mp4" || extension == "mov" || extension == "avi";

    setState(() {
      _selectedFile = file;
      _hasFile = true;
      _detections.clear();
      _detecting = false;
      _currentImage = null;
      _currentUiImage?.dispose();
      _currentUiImage = null;
      _isProcessingFrame = false;
    });

    // Instantly generate a preview thumbnail for the blank box
    if (_isVideo) {
      await _generateVideoPreview(file.path);
    }
  }

  Future<void> _generateVideoPreview(String path) async {
    final cap = cv.VideoCapture.fromFile(path);
    if (cap.isOpened) {
      final (ret, frameMat) = cap.read();
      if (ret && !frameMat.isEmpty) {
        final targetWidth = 640;
        final scale = targetWidth / frameMat.cols;
        final targetHeight = (frameMat.rows * scale).toInt();

        final resizedMat = cv.resize(frameMat, (targetWidth, targetHeight));
        final rgbaMat = cv.cvtColor(resizedMat, cv.COLOR_BGR2RGBA);

        final completer = Completer<ui.Image>();
        ui.decodeImageFromPixels(
          rgbaMat.data,
          rgbaMat.cols,
          rgbaMat.rows,
          ui.PixelFormat.rgba8888,
              (img) => completer.complete(img),
        );
        final uiImage = await completer.future;

        if (mounted) {
          setState(() {
            _currentUiImage = uiImage;
          });
        }
      }
      cap.release();
    }
  }

  // ───────── IMAGE PROCESS ─────────

  Future<void> _detectImage() async {
    if (_selectedFile == null) return;
    final bytes = await _selectedFile!.readAsBytes();
    final image = img.decodeImage(bytes);
    if (image == null) return;

    _currentImage = image;
    final detections = await _isolate.run(image);

    setState(() {
      _detections = detections;
    });
  }


// ───────── OPENCV VIDEO PROCESS (SMOOTH PLAYBACK + ASYNC AI) ─────────

  Future<void> _processVideoFramesOpenCV() async {
    if (_selectedFile == null) return;

    setState(() {
      _detecting = true;
      _detections.clear();
      _isProcessingFrame = false;
    });

    final cap = cv.VideoCapture.fromFile(_selectedFile!.path);

    if (!cap.isOpened) {
      debugPrint("Error: Could not open video.");
      if (mounted) setState(() => _detecting = false);
      return;
    }

    final double fps = cap.get(cv.CAP_PROP_FPS);
    // Fallback to 30 fps if the video metadata doesn't report it properly
    final double frameDelayMs = (fps > 0) ? (1000.0 / fps) : 33.33;

    final stopwatch = Stopwatch()..start();
    int expectedFrameIndex = 0;

    while (_detecting && mounted) {
      final int elapsedMs = stopwatch.elapsedMilliseconds;
      final int targetFrameIndex = (elapsedMs / frameDelayMs).floor();

      int framesToSkip = targetFrameIndex - expectedFrameIndex;

      // 🔥 THE FRONT: LIGHTNING FAST-FORWARD (Keeps video at 1x speed)
      // If the video falls slightly behind real-time, we skip reading colors
      // for the missed frames. cap.grab() is instant compared to cap.set()
      if (framesToSkip > 0) {
        for (int i = 0; i < framesToSkip - 1; i++) {
          cap.grab();
        }
        expectedFrameIndex = targetFrameIndex;
      }

      final (ret, frameMat) = cap.read();
      if (!ret || frameMat.isEmpty) break; // End of video stream
      expectedFrameIndex++;

      // Downscale to 640px to keep UI rendering effortless
      final int targetWidth = 640;
      final double scale = targetWidth / frameMat.cols;
      final int targetHeight = (frameMat.rows * scale).toInt();

      final resizedMat = cv.resize(frameMat, (targetWidth, targetHeight));

      // Convert to RGBA for Flutter UI rendering
      final rgbaMat = cv.cvtColor(resizedMat, cv.COLOR_BGR2RGBA);

      // Decode directly to GPU (Zero-Copy)
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rgbaMat.data,
        rgbaMat.cols,
        rgbaMat.rows,
        ui.PixelFormat.rgba8888,
            (img) => completer.complete(img),
      );
      final uiImage = await completer.future;

      final oldUiImage = _currentUiImage;
      if (mounted) {
        setState(() {
          _currentUiImage = uiImage; // Video plays forward seamlessly
        });
      }
      oldUiImage?.dispose();

      // 🔥 THE BEHIND: ASYNCHRONOUS AI PROCESSING
      // This runs completely independently. It grabs the current frame,
      // goes to the background, and updates the box when finished.
      // It DOES NOT use 'await', meaning the video loop never stops.
      if (!_isProcessingFrame) {
        _isProcessingFrame = true;

        final rgbMat = cv.cvtColor(resizedMat, cv.COLOR_BGR2RGB);

        final imageForAi = img.Image.fromBytes(
          width: rgbMat.cols,
          height: rgbMat.rows,
          bytes: Uint8List.fromList(rgbMat.data).buffer,
          numChannels: 3,
        );

        _isolate.run(imageForAi).then((detections) {
          if (mounted && _detecting) {
            setState(() {
              _detections = detections; // Box updates whenever AI is done
            });
          }
          _isProcessingFrame = false;
        }).catchError((e) {
          _isProcessingFrame = false;
        });
      }

      // Pace the video strictly to its native framerate (e.g., 30 FPS)
      final int nextFrameTimeMs = (expectedFrameIndex * frameDelayMs).toInt();
      final int sleepTimeMs = nextFrameTimeMs - stopwatch.elapsedMilliseconds;

      if (sleepTimeMs > 0) {
        await Future.delayed(Duration(milliseconds: sleepTimeMs));
      } else {
        await Future.delayed(const Duration(milliseconds: 1)); // Yield to UI
      }
    }

    cap.release();
    if (mounted) setState(() => _detecting = false);
  }

  Future<void> _detect() async {
    if (!_isIsolateReady) return;

    if (_isVideo) {
      if (_detecting) {
        setState(() => _detecting = false);
      } else {
        await _processVideoFramesOpenCV();
      }
    } else {
      await _detectImage();
    }
  }

  Rect _scaleBox(Rect box, Size containerSize) {
    double sourceWidth = 1.0;
    double sourceHeight = 1.0;

    if (_isVideo && _currentUiImage != null) {
      sourceWidth = _currentUiImage!.width.toDouble();
      sourceHeight = _currentUiImage!.height.toDouble();
    } else if (!_isVideo && _currentImage != null) {
      sourceWidth = _currentImage!.width.toDouble();
      sourceHeight = _currentImage!.height.toDouble();
    }

    final containerScale = (containerSize.width / sourceWidth < containerSize.height / sourceHeight)
        ? containerSize.width / sourceWidth
        : containerSize.height / sourceHeight;

    final displayWidth = sourceWidth * containerScale;
    final displayHeight = sourceHeight * containerScale;

    final dx = (containerSize.width - displayWidth) / 2;
    final dy = (containerSize.height - displayHeight) / 2;

    return Rect.fromLTWH(
      box.left * containerScale + dx,
      box.top * containerScale + dy,
      box.width * containerScale,
      box.height * containerScale,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.backgroundDark,
      appBar: AppBar(
        backgroundColor: AppColors.backgroundDark,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.slate400),
          onPressed: () => Navigator.pop(context),
        ),
        title: const Text(
          "ROAD ANOMALY DETECTOR",
          style: TextStyle(color: AppColors.slateText, fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: 2),
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 32, 16, 0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 24),
                decoration: BoxDecoration(
                  color: AppColors.surfaceDark.withOpacity(0.30),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.borderDark, width: 2),
                ),
                child: Column(
                  children: [
                    const Icon(Icons.cloud_upload_outlined, color: AppColors.primary, size: 40),
                    const SizedBox(height: 20),
                    Text(
                      _hasFile ? "File Ready" : "No Media Uploaded",
                      style: const TextStyle(color: AppColors.slateText, fontSize: 20, fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 20),
                    if (!_hasFile)
                      ElevatedButton.icon(
                        onPressed: _pickFile,
                        icon: const Icon(Icons.add_photo_alternate_outlined),
                        label: const Text("UPLOAD IMAGE OR VIDEO"),
                      ),
                  ],
                ),
              ),
            ),
            if (_hasFile) ...[
              const SizedBox(height: 24),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.surfaceDark,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.borderDark),
                  ),
                  child: Column(
                    children: [
                      SizedBox(
                        width: double.infinity,
                        height: 320,
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final size = Size(constraints.maxWidth, constraints.maxHeight);

                            return Stack(
                              fit: StackFit.expand,
                              children: [
                                // 🔥 RAW PIXEL RENDER (Replaced slow Image.memory wrapper)
                                if (_isVideo && _currentUiImage != null)
                                  RawImage(
                                    image: _currentUiImage!,
                                    fit: BoxFit.contain,
                                  ),

                                if (!_isVideo && _selectedFile != null)
                                  Image.file(_selectedFile!, fit: BoxFit.contain),

                                ..._detections
                                    .where((det) => det.confidence >= 0.25)
                                    .map((det) {
                                  final box = _scaleBox(det.boundingBox, size);

                                  final Color boxColor = det.confidence >= 0.7
                                      ? Colors.green
                                      : det.confidence >= 0.5
                                      ? Colors.yellow
                                      : Colors.orange;

                                  return Positioned(
                                    left: box.left,
                                    top: box.top,
                                    width: box.width,
                                    height: box.height,
                                    child: Stack(
                                      clipBehavior: Clip.none,
                                      children: [
                                        Container(
                                          decoration: BoxDecoration(border: Border.all(color: boxColor, width: 2)),
                                        ),
                                        Positioned(
                                          top: -20,
                                          left: 0,
                                          child: Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            color: boxColor,
                                            child: Text(
                                              "${det.label} ${(det.confidence * 100).toStringAsFixed(1)}%",
                                              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  );
                                })
                              ],
                            );
                          },
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _detect,
                              icon: const Icon(Icons.visibility_outlined),
                              label: Text(
                                _isVideo ? (_detecting ? "STOP DETECTION" : "START DETECTION") : "DETECT",
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          GestureDetector(
                            onTap: () {
                              setState(() {
                                _hasFile = false;
                                _selectedFile = null;
                                _detections.clear();
                                _detecting = false;
                                _currentUiImage?.dispose();
                                _currentUiImage = null;
                                _currentImage = null;
                                _isProcessingFrame = false;
                              });
                            },
                            child: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(color: AppColors.borderDark, borderRadius: BorderRadius.circular(8)),
                              child: const Icon(Icons.delete_outline, color: AppColors.slate300),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            ]
          ],
        ),
      ),
    );
  }
}