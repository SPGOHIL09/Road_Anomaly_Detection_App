import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import 'package:road_anomaly_detector/theme/app_theme.dart';
import 'package:road_anomaly_detector/services/model_service.dart';
import 'package:road_anomaly_detector/models/detection.dart';
import 'package:road_anomaly_detector/services/inference_isolate.dart';
import 'package:road_anomaly_detector/services/detector/gpu_detector_service.dart';
import 'package:road_anomaly_detector/services/upload/video_analysis_service.dart';
import 'package:road_anomaly_detector/services/upload/defect_tracks.dart';
import 'package:road_anomaly_detector/services/upload/video_detection_track.dart';

/// Upload pipeline: still images go through [InferenceIsolate]; videos are
/// analysed by [VideoAnalysisService] and played back with [VideoPlayer],
/// with boxes looked up by playback position from a [VideoDetectionTrack].
class UploadScreen extends StatefulWidget {
  const UploadScreen({super.key});

  @override
  State<UploadScreen> createState() => _UploadScreenState();
}

class _UploadScreenState extends State<UploadScreen>
    with SingleTickerProviderStateMixin {
  bool _hasFile = false;

  File? _selectedFile;
  bool _isVideo = false;

  // ───── Image state ─────
  List<Detection> _detections = [];
  final InferenceIsolate _isolate = InferenceIsolate();
  bool _isIsolateReady = false;
  Size? _imageSize;
  bool _detectingImage = false;

  // ───── Video state ─────
  /// Detection spacing adapts between these (video time) to the phone's
  /// inference speed; the track tolerates gaps up to the maximum.
  static const int _minDetectIntervalMs = 100;
  static const int _sampleIntervalMs = 500;

  Uint8List? _modelBytes;
  VideoPlayerController? _video;
  final VideoAnalysisService _analysis = VideoAnalysisService(
    minIntervalMs: _minDetectIntervalMs,
    maxIntervalMs: _sampleIntervalMs,
  );
  StreamSubscription<VideoAnalysisEvent>? _analysisSub;
  VideoDetectionTrack _track = VideoDetectionTrack(
    sampleIntervalMs: _sampleIntervalMs,
  );

  /// Stable per-defect tracks built from the whole-video scan.
  DefectTracks _defects = DefectTracks.empty;
  final ValueNotifier<List<Detection>> _videoBoxes = ValueNotifier(const []);
  late final Ticker _ticker;

  bool _analyzing = false;
  bool _wantsPlay = false;
  String? _videoError;

  // Playback clock: video_player only reports position every ~500ms, so we
  // poll it and extrapolate between polls to place boxes on every frame.
  int _anchorPosMs = 0;
  final Stopwatch _anchorClock = Stopwatch();
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    _initIsolate();
  }

  Future<void> _initIsolate() async {
    final modelBytes = await ModelService.loadModelBytes();
    _modelBytes = modelBytes;
    await _isolate.start(modelBytes, gpu: GpuDetectorService.port);
    if (GpuDetectorService.port == null) {
      GpuDetectorService.portListenable.addListener(_onGpuReady);
    }
    if (mounted) setState(() => _isIsolateReady = true);
  }

  /// The shared GPU engine finished starting: move this screen's photo and
  /// video detection onto it.
  void _onGpuReady() {
    final gpu = GpuDetectorService.port;
    if (gpu == null || !mounted) return;
    GpuDetectorService.portListenable.removeListener(_onGpuReady);
    _isolate.useGpu(gpu);
    _analysis.useGpu(gpu);
  }

  @override
  void dispose() {
    GpuDetectorService.portListenable.removeListener(_onGpuReady);
    _ticker.dispose();
    _stopAnalysis();
    _video?.dispose();
    _videoBoxes.dispose();
    _isolate.dispose();
    super.dispose();
  }

  // ───────── PICK FILE ─────────

  Future<void> _pickFile() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.media);
    if (result == null) return;

    final file = File(result.files.single.path!);
    final extension = result.files.single.extension?.toLowerCase();

    _resetVideo();
    _isVideo = extension == "mp4" || extension == "mov" || extension == "avi";

    setState(() {
      _selectedFile = file;
      _hasFile = true;
      _detections.clear();
      _imageSize = null;
      _detectingImage = false;
    });

    if (_isVideo) {
      await _openVideo(file);
    }
  }

  Future<void> _openVideo(File file) async {
    final controller = VideoPlayerController.file(file);
    try {
      await controller.initialize();
    } catch (e) {
      controller.dispose();
      if (mounted) setState(() => _videoError = "Could not open video: $e");
      return;
    }
    if (!mounted || _selectedFile != file) {
      controller.dispose();
      return;
    }
    controller.addListener(_onVideoValue);
    setState(() => _video = controller);
    if (!_ticker.isActive) _ticker.start();
  }

  void _resetVideo() {
    _stopAnalysis();
    _ticker.stop();
    _video?.removeListener(_onVideoValue);
    _video?.dispose();
    _video = null;
    _track = VideoDetectionTrack(sampleIntervalMs: _sampleIntervalMs);
    _defects = DefectTracks.empty;
    _videoBoxes.value = const [];
    _wantsPlay = false;
    _videoError = null;
  }

  // ───────── IMAGE PROCESS ─────────

  Future<void> _detectImage() async {
    if (_selectedFile == null) return;
    final file = _selectedFile!;
    setState(() => _detectingImage = true);
    final sw = Stopwatch()..start();
    // Decode + detect both happen in the upload isolate (native OpenCV).
    final result = await _isolate.runFile(file.path);
    if (!kReleaseMode) {
      debugPrint(
        "🖼️ image ${result.width}x${result.height}: "
        "${result.detections.length} detections (${sw.elapsedMilliseconds}ms)",
      );
    }
    if (!mounted || _selectedFile != file) return;

    setState(() {
      _detectingImage = false;
      _imageSize = Size(result.width.toDouble(), result.height.toDouble());
      _detections = result.detections;
    });
  }

  // ───────── VIDEO: ANALYSIS ─────────

  void _startAnalysis() {
    final file = _selectedFile;
    final bytes = _modelBytes;
    if (file == null || bytes == null) return;

    _track = VideoDetectionTrack(sampleIntervalMs: _sampleIntervalMs);
    _defects = DefectTracks.empty;
    _videoBoxes.value = const [];
    _videoError = null;
    setState(() => _analyzing = true);

    final shown = _video?.value.size;
    _analysisSub = _analysis
        .start(
          file.path,
          bytes,
          expectPortrait: shown == null || shown.isEmpty
              ? null
              : shown.height > shown.width,
          gpu: GpuDetectorService.port,
        )
        .listen((event) {
          if (!mounted) return;
          switch (event) {
            case VideoAnalysisInfo():
              _checkOrientation(event);
            case VideoFrameDetections():
              _track.add(event.timestampMs, event.detections);
              // Repaint the progress bar a few times per second, not per sample.
              if (_track.sampleCount % 5 == 0) setState(() {});
            case VideoAnalysisDone():
              _track.complete = true;
              _finishScan(play: true);
            case VideoAnalysisError():
              _videoError = event.message;
              _finishScan(play: false);
          }
        });
  }

  /// Whole video scanned (or scan stopped): link detections into stable
  /// tracks, then play from the start with the boxes.
  void _finishScan({required bool play}) {
    _analysisSub?.cancel();
    _analysisSub = null;
    _analysis.stop();
    final defects = DefectTracks.build(_track.samples);
    if (!kReleaseMode) {
      debugPrint(
        "🎞️ scan: ${_track.sampleCount} frames, ${defects.count} defects",
      );
    }
    setState(() {
      _analyzing = false;
      _defects = defects;
    });
    final c = _video;
    if (play && c != null) {
      c.seekTo(Duration.zero).then((_) {
        if (!mounted) return;
        setState(() => _wantsPlay = true);
        c.play();
      });
    }
  }

  void _stopAnalysis() {
    _analysisSub?.cancel();
    _analysisSub = null;
    _analysis.stop();
    _analyzing = false;
  }

  void _checkOrientation(VideoAnalysisInfo info) {
    final size = _video?.value.size;
    if (size == null || size.isEmpty || info.frameHeight == 0) return;
    final analysedLandscape = info.frameWidth > info.frameHeight;
    final shownLandscape = size.width > size.height;
    if (analysedLandscape != shownLandscape) {
      debugPrint(
        "⚠️ Analysed frames ${info.frameWidth}x${info.frameHeight} "
        "but player shows ${size.width}x${size.height}; boxes may be rotated.",
      );
    }
  }

  // ───────── VIDEO: PLAYBACK SYNC ─────────

  int get _durationMs => _video?.value.duration.inMilliseconds ?? 0;

  void _onVideoValue() {
    final v = _video?.value;
    if (v == null) return;
    if (!v.isPlaying) {
      _anchorPosMs = v.position.inMilliseconds;
      _anchorClock
        ..stop()
        ..reset();
    } else if (!_anchorClock.isRunning) {
      _anchorPosMs = v.position.inMilliseconds;
      _anchorClock
        ..reset()
        ..start();
    }
    if (v.isCompleted && _wantsPlay && !v.isPlaying) {
      setState(() => _wantsPlay = false);
    }
  }

  void _onTick(Duration _) {
    final c = _video;
    if (c == null || !c.value.isInitialized) return;
    final v = c.value;

    int pos;
    if (v.isPlaying) {
      pos =
          _anchorPosMs +
          (_anchorClock.elapsedMilliseconds * v.playbackSpeed).round();
      if (!_polling) {
        _polling = true;
        c.position
            .then((p) {
              if (p != null && c.value.isPlaying) {
                _anchorPosMs = p.inMilliseconds;
                _anchorClock
                  ..reset()
                  ..start();
              }
            })
            .whenComplete(() => _polling = false);
      }
    } else {
      pos = v.position.inMilliseconds;
    }
    final dur = _durationMs;
    if (dur > 0 && pos > dur) pos = dur;

    // Everything is scanned before playback, so boxes are a lookup.
    final boxes = _analyzing ? const <Detection>[] : _defects.at(pos);
    if (!identical(boxes, _videoBoxes.value)) _videoBoxes.value = boxes;
  }

  Future<void> _togglePlay() async {
    final c = _video;
    if (c == null) return;
    if (_analyzing) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Scanning the video… it plays when the scan is done"),
        ),
      );
      return;
    }
    if (_wantsPlay) {
      setState(() => _wantsPlay = false);
      await c.pause();
      return;
    }
    if (c.value.isCompleted ||
        (_durationMs > 0 && c.value.position.inMilliseconds >= _durationMs)) {
      await c.seekTo(Duration.zero);
    }
    setState(() => _wantsPlay = true);
    await c.play();
  }

  // ───────── DETECT BUTTON ─────────

  Future<void> _detect() async {
    if (!_isIsolateReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text("Model is still loading, try again in a moment"),
        ),
      );
      return;
    }

    if (_isVideo) {
      final c = _video;
      if (c == null) return;
      if (_analyzing) {
        // STOP DETECTION: keep what was scanned so far, do not auto-play.
        _finishScan(play: false);
      } else {
        // START DETECTION: scan the whole video first (paused), like a
        // photo; playback with boxes starts automatically when done.
        await c.pause();
        await c.seekTo(Duration.zero);
        setState(() => _wantsPlay = false);
        _startAnalysis();
      }
    } else {
      await _detectImage();
    }
  }

  // ───────── IMAGE BOX SCALING ─────────

  Rect _scaleBox(Rect box, Size containerSize) {
    double sourceWidth = 1.0;
    double sourceHeight = 1.0;

    if (_imageSize != null) {
      sourceWidth = _imageSize!.width;
      sourceHeight = _imageSize!.height;
    }

    final containerScale =
        (containerSize.width / sourceWidth <
            containerSize.height / sourceHeight)
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

  static Color _boxColor(double confidence) => confidence >= 0.7
      ? Colors.green
      : confidence >= 0.5
      ? Colors.yellow
      : Colors.orange;

  Widget _boxWidget(Detection det, Rect box) {
    final boxColor = _boxColor(det.confidence);
    return Positioned(
      left: box.left,
      top: box.top,
      width: box.width,
      height: box.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: boxColor, width: 2),
            ),
          ),
          Positioned(
            top: -20,
            left: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              color: boxColor,
              child: Text(
                "${det.label} ${(det.confidence * 100).toStringAsFixed(1)}%",
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.black,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ───────── VIDEO VIEW ─────────

  /// Video and its boxes share one canvas sized like the video, then scaled
  /// to fit, so normalized boxes land exactly on the picture.
  Widget _buildVideoView() {
    final c = _video;
    if (c == null || !c.value.isInitialized) {
      return Center(
        child: _videoError != null
            ? Text(
                _videoError!,
                style: const TextStyle(color: AppColors.slate400),
              )
            : const CircularProgressIndicator(),
      );
    }
    final size = c.value.size;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Inverse of the FittedBox scale, so borders/labels keep a constant
        // on-screen size for both landscape and portrait videos.
        final fit = [
          constraints.maxWidth / size.width,
          constraints.maxHeight / size.height,
        ].reduce((a, b) => a < b ? a : b);
        final scale = fit > 0 ? 1 / fit : 1.0;
        return FittedBox(
          fit: BoxFit.contain,
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: Stack(
              fit: StackFit.expand,
              children: [
                VideoPlayer(c),
                ValueListenableBuilder<List<Detection>>(
                  valueListenable: _videoBoxes,
                  builder: (context, boxes, _) {
                    return Stack(
                      clipBehavior: Clip.none,
                      children: [
                        for (final det in boxes) _videoBox(det, size, scale),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _videoBox(Detection det, Size size, double scale) {
    final b = det.boundingBox;
    const color = Color(0xFFFF3B30); // red, as in the reference output
    return Positioned(
      left: b.left * size.width,
      top: b.top * size.height,
      width: b.width * size.width,
      height: b.height * size.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: color, width: 1.5 * scale),
            ),
          ),
          Positioned(
            top: -15 * scale,
            left: 0,
            child: Container(
              padding: EdgeInsets.symmetric(
                horizontal: 3 * scale,
                vertical: 1 * scale,
              ),
              color: color,
              child: Text(
                "${det.label.toLowerCase()} ${det.confidence.toStringAsFixed(2)}",
                style: TextStyle(
                  fontSize: 9 * scale,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  String _defectCountText() =>
      _defects.count == 1 ? "1 defect" : "${_defects.count} defects";

  Widget _buildVideoStatus() {
    final c = _video;
    if (c == null || !c.value.isInitialized) return const SizedBox.shrink();

    final dur = _durationMs;
    final analysed = _track.analyzedUntilMs;
    final progress = _track.complete
        ? 1.0
        : (dur > 0 && analysed > 0 ? (analysed / dur).clamp(0.0, 1.0) : 0.0);

    String status;
    if (_videoError != null) {
      status = _videoError!;
    } else if (_analyzing) {
      status = "Scanning video… ${(progress * 100).toStringAsFixed(0)}%";
    } else if (_track.complete) {
      status = "Scan complete · ${_defectCountText()} found";
    } else if (_track.sampleCount > 0) {
      status =
          "Scan stopped at ${(progress * 100).toStringAsFixed(0)}% · ${_defectCountText()} found so far";
    } else {
      status = "Press START DETECTION to detect defects";
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          VideoProgressIndicator(
            c,
            allowScrubbing: !_analyzing || _track.complete,
            colors: const VideoProgressColors(
              playedColor: AppColors.primary,
              bufferedColor: AppColors.borderDark,
              backgroundColor: AppColors.borderDark,
            ),
          ),
          if (_analyzing || (_track.sampleCount > 0 && !_track.complete)) ...[
            const SizedBox(height: 6),
            LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              color: Colors.green,
              backgroundColor: AppColors.borderDark,
            ),
          ],
          const SizedBox(height: 8),
          Row(
            children: [
              IconButton(
                onPressed: _togglePlay,
                icon: Icon(
                  _wantsPlay
                      ? Icons.pause_circle_filled
                      : Icons.play_circle_fill,
                  color: AppColors.slateText,
                  size: 32,
                ),
              ),
              Expanded(
                child: Text(
                  status,
                  style: const TextStyle(
                    color: AppColors.slate400,
                    fontSize: 12,
                  ),
                ),
              ),
              if (_analyzing)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
        ],
      ),
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
          style: TextStyle(
            color: AppColors.slateText,
            fontSize: 14,
            fontWeight: FontWeight.w700,
            letterSpacing: 2,
          ),
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 32, 16, 0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  vertical: 40,
                  horizontal: 24,
                ),
                decoration: BoxDecoration(
                  color: AppColors.surfaceDark.withOpacity(0.30),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.borderDark, width: 2),
                ),
                child: Column(
                  children: [
                    const Icon(
                      Icons.cloud_upload_outlined,
                      color: AppColors.primary,
                      size: 40,
                    ),
                    const SizedBox(height: 20),
                    Text(
                      _hasFile ? "File Ready" : "No Media Uploaded",
                      style: const TextStyle(
                        color: AppColors.slateText,
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
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
                        child: _isVideo
                            ? _buildVideoView()
                            : LayoutBuilder(
                                builder: (context, constraints) {
                                  final size = Size(
                                    constraints.maxWidth,
                                    constraints.maxHeight,
                                  );

                                  return Stack(
                                    fit: StackFit.expand,
                                    children: [
                                      if (_selectedFile != null)
                                        Image.file(
                                          _selectedFile!,
                                          fit: BoxFit.contain,
                                        ),

                                      ..._detections
                                          .where(
                                            (det) => det.confidence >= 0.25,
                                          )
                                          .map(
                                            (det) => _boxWidget(
                                              det,
                                              _scaleBox(det.boundingBox, size),
                                            ),
                                          ),
                                    ],
                                  );
                                },
                              ),
                      ),
                      if (_isVideo) _buildVideoStatus(),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _detect,
                              icon: const Icon(Icons.visibility_outlined),
                              label: Text(
                                _isVideo
                                    ? (_analyzing
                                          ? "STOP DETECTION"
                                          : "START DETECTION")
                                    : (_detectingImage
                                          ? "DETECTING..."
                                          : "DETECT"),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          GestureDetector(
                            onTap: () {
                              _resetVideo();
                              setState(() {
                                _hasFile = false;
                                _selectedFile = null;
                                _detections.clear();
                                _imageSize = null;
                                _detectingImage = false;
                              });
                            },
                            child: Container(
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                color: AppColors.borderDark,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.delete_outline,
                                color: AppColors.slate300,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
