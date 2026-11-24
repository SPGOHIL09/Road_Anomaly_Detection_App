import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../models/detection.dart';
import '../../utils/preprocessing.dart';
import '../detector/detector_client.dart';
import 'hw_video_decoder.dart';

/// Events emitted while a video is processed.
sealed class VideoAnalysisEvent {
  const VideoAnalysisEvent();
}

class VideoAnalysisInfo extends VideoAnalysisEvent {
  final int frameWidth;
  final int frameHeight;
  final double fps;
  final int durationMs;
  const VideoAnalysisInfo(
    this.frameWidth,
    this.frameHeight,
    this.fps,
    this.durationMs,
  );
}

/// Detections for the frame at [timestampMs], boxes normalized (0..1) to the
/// frame. An empty list means "analysed, nothing found" (not "unknown").
class VideoFrameDetections extends VideoAnalysisEvent {
  final int timestampMs;
  final List<Detection> detections;
  const VideoFrameDetections(this.timestampMs, this.detections);
}

class VideoAnalysisDone extends VideoAnalysisEvent {
  final int lastTimestampMs;
  const VideoAnalysisDone(this.lastTimestampMs);
}

class VideoAnalysisError extends VideoAnalysisEvent {
  final String message;
  const VideoAnalysisError(this.message);
}

/// Real-time video detection for the upload pipeline, Python/OpenCV style:
/// a background loop reads the video frame by frame and detects on frames
/// as fast as the phone allows, while the screen plays the video.
///
/// Two isolates run in parallel:
/// * **decoder** – decodes every frame and hands the frames picked for
///   detection, downscaled to the model size, to the detector. On Android it
///   uses [HwVideoDecoder] (MediaCodec into the GPU, which downscales there,
///   so 4K frames never reach the CPU); elsewhere, or if that fails to open,
///   OpenCV/FFmpeg `cap.grab()`s every frame and `cap.read()`s the sampled
///   ones. It never runs more than one sample ahead of the detector, so
///   detection keeps pace with decoding.
/// * **detector** – runs the model and emits timestamped boxes.
///
/// The spacing between detected frames adapts to the measured inference
/// time (between [minIntervalMs] and [maxIntervalMs] of video time) so
/// detection keeps up with real-time playback on the phone it runs on.
class VideoAnalysisService {
  final int minIntervalMs;
  final int maxIntervalMs;

  VideoAnalysisService({this.minIntervalMs = 100, this.maxIntervalMs = 500});

  Isolate? _decoder;
  Isolate? _detector;
  SendPort? _decoderPort;
  SendPort? _detectorPort;
  ReceivePort? _events;
  StreamController<VideoAnalysisEvent>? _controller;

  bool get isRunning => _events != null;

  /// [expectPortrait] is the orientation the player shows (from
  /// `VideoPlayerController.value.size`); decoded frames are rotated to
  /// match it so boxes line up. [gpuDecode] decodes with [HwVideoDecoder]
  /// on Android (FFmpeg is the fallback); [preferHardware] picks OpenCV's
  /// MediaCodec backend for the FFmpeg-path fallback.
  Stream<VideoAnalysisEvent> start(
    String videoPath,
    Uint8List modelBytes, {
    bool? expectPortrait,
    bool gpuDecode = true,
    bool preferHardware = false,
    SendPort? gpu,
  }) {
    stop();
    // Lets the decoder isolate use platform channels (hardware decoder).
    final rootToken = gpuDecode && Platform.isAndroid
        ? RootIsolateToken.instance
        : null;
    final controller = StreamController<VideoAnalysisEvent>();
    final events = ReceivePort();
    _controller = controller;
    _events = events;

    void fail(Object e) {
      if (_events != events) return;
      if (!controller.isClosed) controller.add(VideoAnalysisError('$e'));
      stop();
    }

    events.listen((msg) {
      if (_events != events) return;
      if (msg is List && msg.isNotEmpty) {
        switch (msg[0]) {
          case 'detector':
            _detectorPort = msg[1] as SendPort;
          case 'detector-ready':
            Isolate.spawn(_decoderEntry, [
                  events.sendPort,
                  videoPath,
                  _detectorPort,
                  minIntervalMs,
                  maxIntervalMs,
                  expectPortrait,
                  preferHardware,
                  rootToken,
                ])
                .then((iso) {
                  if (_events == events) {
                    _decoder = iso;
                  } else {
                    iso.kill(priority: Isolate.immediate);
                  }
                })
                .catchError((Object e) {
                  fail(e);
                });
          case 'decoder':
            _decoderPort = msg[1] as SendPort;
        }
        return;
      }
      if (msg is VideoAnalysisEvent && !controller.isClosed) {
        controller.add(msg);
        if (msg is VideoAnalysisDone || msg is VideoAnalysisError) stop();
      }
    });

    Isolate.spawn(_detectorEntry, [events.sendPort, modelBytes, gpu])
        .then((iso) {
          if (_events == events) {
            _detector = iso;
          } else {
            iso.kill(priority: Isolate.immediate);
          }
        })
        .catchError((Object e) {
          fail(e);
        });

    return controller.stream;
  }

  /// Stops processing. Workers release the decoder and model themselves and
  /// are force-killed if they do not exit promptly.
  /// Switches a running detection to the GPU engine once it is ready.
  void useGpu(SendPort gpu) => _detectorPort?.send(['gpu', gpu]);

  void stop() {
    _decoderPort?.send('cancel');
    _detectorPort?.send('exit');
    for (final iso in [_decoder, _detector]) {
      if (iso != null) {
        Timer(
          const Duration(seconds: 2),
          () => iso.kill(priority: Isolate.immediate),
        );
      }
    }
    _decoder = null;
    _detector = null;
    _decoderPort = null;
    _detectorPort = null;
    _events?.close();
    _events = null;
    final c = _controller;
    _controller = null;
    if (c != null && !c.isClosed) c.close();
  }

  /// Opens [path] for frame-by-frame decoding.
  ///
  /// With [preferHardware] on Android, frames are decoded by MediaCodec
  /// (OpenCV's Android backend). On a Pixel 9 it was not reliably faster
  /// than FFmpeg for 4K HEVC (18.8-26.3 fps vs 22-24 fps across runs), so
  /// it is off by default. That backend reports neither the rotation tag
  /// nor the frame count, so both (and fps) come from a quick FFmpeg probe
  /// and frames are rotated exactly as FFmpeg's auto-rotation would.
  static OpenedVideo? openForDecoding(
    String path, {
    bool preferHardware = false,
  }) {
    final probe = cv.VideoCapture.fromFile(path, apiPreference: cv.CAP_FFMPEG);
    if (!probe.isOpened) {
      probe.release();
      final any = cv.VideoCapture.fromFile(path);
      if (!any.isOpened) {
        any.release();
        return null;
      }
      return OpenedVideo(
        any,
        false,
        any.get(cv.CAP_PROP_FPS),
        any.get(cv.CAP_PROP_FRAME_COUNT),
        0,
        null,
      );
    }
    final fps = probe.get(cv.CAP_PROP_FPS);
    final count = probe.get(cv.CAP_PROP_FRAME_COUNT);
    final meta = probe.get(cv.CAP_PROP_ORIENTATION_META).round() % 360;
    final ffmpegAutoRotates = probe.get(cv.CAP_PROP_ORIENTATION_AUTO) != 0;

    if (preferHardware && Platform.isAndroid) {
      final hw = cv.VideoCapture.fromFile(path, apiPreference: cv.CAP_ANDROID);
      if (hw.isOpened) {
        probe.release();
        return OpenedVideo(hw, true, fps, count, meta, rotationFor(meta));
      }
      hw.release();
    }
    return OpenedVideo(
      probe,
      false,
      fps,
      count,
      meta,
      ffmpegAutoRotates ? null : rotationFor(meta),
    );
  }

  /// OpenCV rotate code for a container rotation tag (same mapping as
  /// OpenCV's FFmpeg auto-rotation).
  static int? rotationFor(int meta) => switch (meta) {
    90 => cv.ROTATE_90_CLOCKWISE,
    180 => cv.ROTATE_180,
    270 => cv.ROTATE_90_COUNTERCLOCKWISE,
    _ => null,
  };

  // ─────────────────────── Detector isolate ───────────────────────

  static Future<void> _detectorEntry(List<dynamic> args) async {
    final SendPort main = args[0];
    final Uint8List modelBytes = args[1];
    final SendPort? gpu = args[2];
    final port = ReceivePort();
    main.send(['detector', port.sendPort]);

    // GPU engine when available; CPU session (in this isolate) otherwise.
    final client = DetectorClient(modelBytes, gpu: gpu);
    if (gpu == null) {
      try {
        await client.ensureCpu();
      } catch (e) {
        main.send(VideoAnalysisError('Model failed to load: $e'));
        port.close();
        return;
      }
    }
    if (!kReleaseMode) debugPrint('🎞️ video detector on ${client.engine}');
    main.send(['detector-ready']);

    SendPort? decoder;
    try {
      await for (final msg in port) {
        if (msg == 'exit') break;
        if (msg is! List) continue;
        if (msg[0] == 'hello') {
          decoder = msg[1] as SendPort;
          continue;
        }
        if (msg[0] == 'gpu') {
          client.gpu = msg[1] as SendPort;
          if (!kReleaseMode) debugPrint('🎞️ video detector switched to GPU');
          continue;
        }
        // ['job', ts, frameW, frameH, pixels, bgr]
        final int ts = msg[1];
        final int w = msg[2];
        final int h = msg[3];
        final Uint8List pixels = (msg[4] as TransferableTypedData)
            .materialize()
            .asUint8List();
        final bool bgr = msg.length > 5 ? msg[5] as bool : true;
        final sw = Stopwatch()..start();
        List<Detection> dets = const [];
        try {
          final lb = LetterboxInfo.forSize(w, h);
          dets = _normalize(
            await client.detectPacked(pixels, lb, bgr: bgr),
            lb,
            w,
            h,
          );
        } catch (e) {
          main.send(VideoAnalysisError('Detection failed: $e'));
        }
        final ms = sw.elapsedMilliseconds;
        if (!kReleaseMode) {
          debugPrint(
            '🎞️ video ${ts}ms: ${dets.length} detections '
            '(${ms}ms, ${client.engine})',
          );
        }
        main.send(VideoFrameDetections(ts, dets));
        decoder?.send(['free', ms]);
      }
    } finally {
      client.release();
      port.close();
    }
  }

  static List<Detection> _normalize(
    List<Detection> dets,
    LetterboxInfo lb,
    int w,
    int h,
  ) {
    final result = <Detection>[];
    for (final d in dets) {
      final src = lb.toSource(d.boundingBox);
      final box = Rect.fromLTRB(
        (src.left / w).clamp(0.0, 1.0),
        (src.top / h).clamp(0.0, 1.0),
        (src.right / w).clamp(0.0, 1.0),
        (src.bottom / h).clamp(0.0, 1.0),
      );
      if (box.width <= 0 || box.height <= 0) continue;
      result.add(
        Detection(label: d.label, confidence: d.confidence, boundingBox: box),
      );
    }
    return result;
  }

  // ─────────────────────── Decoder isolate ───────────────────────

  static Future<void> _decoderEntry(List<dynamic> args) async {
    final SendPort main = args[0];
    final String path = args[1];
    final SendPort detector = args[2];
    final int minInterval = args[3];
    final int maxInterval = args[4];
    final bool? expectPortrait = args[5];
    final bool preferHardware = args[6];
    final RootIsolateToken? rootToken = args[7];

    final control = ReceivePort();
    main.send(['decoder', control.sendPort]);
    detector.send(['hello', control.sendPort]);

    var cancelled = false;
    var detectorFree = Completer<void>()..complete();
    double inferMsEma = minInterval.toDouble();
    control.listen((msg) {
      if (msg == 'cancel') {
        cancelled = true;
        if (!detectorFree.isCompleted) detectorFree.complete();
      } else if (msg is List && msg[0] == 'free') {
        inferMsEma = inferMsEma * 0.7 + (msg[1] as int) * 0.3;
        if (!detectorFree.isCompleted) detectorFree.complete();
      }
    });

    int nextInterval() => (inferMsEma * 1.15)
        .clamp(minInterval.toDouble(), maxInterval.toDouble())
        .round();

    /// Decodes with [HwVideoDecoder]. Returns false (nothing sent yet) when
    /// it is unavailable, so the FFmpeg path can take over.
    Future<bool> decodeOnGpu() async {
      if (rootToken == null) return false;
      BackgroundIsolateBinaryMessenger.ensureInitialized(rootToken);
      final hw = await HwVideoDecoder.open(
        path,
        expectPortrait: expectPortrait,
      );
      if (hw == null) return false;
      try {
        final int w = hw.width;
        final int h = hw.height;
        final double fps = hw.frameRate > 0 ? hw.frameRate : 30.0;
        final double frameMs = 1000.0 / fps;
        final lb = LetterboxInfo.forSize(w, h);
        final wall = Stopwatch()..start();

        HwVideoFrame? frame;
        try {
          frame = await hw.next(0, lb.newWidth, lb.newHeight);
        } on PlatformException catch (e) {
          if (!kReleaseMode) debugPrint('🎞️ hardware decode failed: $e');
          return false; // nothing sent yet: fall back to FFmpeg
        }
        main.send(VideoAnalysisInfo(w, h, fps, hw.durationMs));
        if (!kReleaseMode) {
          debugPrint(
            '🎞️ video opened ${w}x$h @ ${fps.toStringAsFixed(1)} fps, '
            'hardware ${hw.codec}, rotate ${hw.rotation} (tag ${hw.meta}), '
            'BT.601 ${hw.yuv601}',
          );
        }

        int lastTs = -1;
        int samples = 0;
        while (frame != null && !cancelled) {
          // Hand over at most one frame at a time: wait for the detector.
          await detectorFree.future;
          if (cancelled) break;
          int ts = (frame.timestampUs / 1000).round();
          if (ts <= lastTs) ts = lastTs + 1;
          lastTs = ts;
          samples++;
          detectorFree = Completer<void>();
          detector.send([
            'job',
            ts,
            w,
            h,
            TransferableTypedData.fromList([frame.rgb]),
            false,
          ]);
          // Space detections by what the phone can sustain in real time,
          // and decode up to the next sample while the detector works.
          final nextSampleMs = lastTs + nextInterval();
          frame = await hw.next(
            ((nextSampleMs - frameMs / 2) * 1000).round(),
            lb.newWidth,
            lb.newHeight,
          );
          if (!kReleaseMode && samples % 50 == 0) {
            final secs = wall.elapsedMilliseconds / 1000;
            debugPrint(
              '🎞️ hw decoder: video ${(lastTs / 1000).toStringAsFixed(1)}s '
              'in ${secs.toStringAsFixed(1)}s, $samples samples, '
              'inference ~${inferMsEma.round()}ms',
            );
          }
        }
        // Wait for the last frame's detections before reporting completion.
        await detectorFree.future;
        if (!cancelled) main.send(VideoAnalysisDone(lastTs));
        return true;
      } finally {
        await hw.close();
      }
    }

    cv.VideoCapture? cap;
    try {
      if (await decodeOnGpu()) return;
      if (cancelled) return;
      final opened = openForDecoding(path, preferHardware: preferHardware);
      if (opened == null) {
        main.send(const VideoAnalysisError('Could not open video'));
        return;
      }
      cap = opened.cap;
      final bool ffmpeg = !opened.hardware;
      final double fps = opened.fps;
      final double frameMs = fps > 0 ? 1000.0 / fps : 1000.0 / 30.0;
      final double frameCount = opened.frameCount;
      final int meta = opened.meta;
      int? rotateCode = opened.rotateCode;

      int lastTs = -1;
      int frameIndex = 0;
      int nextSampleMs = 0;
      bool infoSent = false;
      final wall = Stopwatch()..start();
      int lastLogFrames = 0;

      int timestampAfterDecode() {
        // The hardware backend's POS_MSEC is not monotonic, so use the frame
        // index there (phone recordings are constant frame rate).
        int ts = ffmpeg
            ? cap!.get(cv.CAP_PROP_POS_MSEC).round()
            : (frameIndex * frameMs).round();
        if (ts <= lastTs) ts = (frameIndex * frameMs).round();
        if (ts <= lastTs) ts = lastTs + 1;
        return ts;
      }

      while (!cancelled) {
        final double predictedTs = lastTs < 0 ? 0 : lastTs + frameMs;
        final bool isSample = predictedTs + frameMs / 2 >= nextSampleMs;

        if (!isSample) {
          // Decode only (no colour conversion) for frames we do not detect.
          if (ffmpeg) {
            final before = cap.get(cv.CAP_PROP_POS_FRAMES);
            cap.grab();
            if (cap.get(cv.CAP_PROP_POS_FRAMES) <= before) break; // end
          } else {
            if (frameCount > 0 && frameIndex >= frameCount) break; // end
            cap.grab();
          }
          lastTs = timestampAfterDecode();
          frameIndex++;
        } else {
          // Hand over at most one frame at a time: wait for the detector.
          await detectorFree.future;
          if (cancelled) break;

          final (ok, raw) = cap.read();
          if (!ok || raw.isEmpty) {
            raw.dispose();
            break;
          }
          lastTs = timestampAfterDecode();
          frameIndex++;

          if (!infoSent && expectPortrait != null) {
            // Match what the player shows, whatever the backend did with
            // the container's rotation tag.
            final rawPortrait = raw.rows > raw.cols;
            rotateCode = rawPortrait == expectPortrait
                ? (rotateCode == cv.ROTATE_180 ? cv.ROTATE_180 : null)
                : (meta == 270
                      ? cv.ROTATE_90_COUNTERCLOCKWISE
                      : cv.ROTATE_90_CLOCKWISE);
          }
          cv.Mat frame = raw;
          if (rotateCode != null) {
            frame = cv.rotate(raw, rotateCode);
            raw.dispose();
          }
          final int w = frame.cols;
          final int h = frame.rows;

          if (!infoSent) {
            infoSent = true;
            final durationMs = frameCount > 0
                ? (frameCount * frameMs).round()
                : 0;
            main.send(VideoAnalysisInfo(w, h, fps, durationMs));
            if (!kReleaseMode) {
              debugPrint(
                '🎞️ video opened ${w}x$h @ ${fps.toStringAsFixed(1)} '
                'fps, ${frameCount.round()} frames, '
                'backend ${cap.getBackendName()}, rotate $rotateCode',
              );
            }
          }

          final lb = LetterboxInfo.forSize(w, h);
          final resized = cv.resize(frame, (
            lb.newWidth,
            lb.newHeight,
          ), interpolation: cv.INTER_AREA);
          frame.dispose();
          final pixels = TransferableTypedData.fromList([resized.data]);
          resized.dispose();

          detectorFree = Completer<void>();
          detector.send(['job', lastTs, w, h, pixels]);

          // Space detections by what the phone can sustain in real time.
          nextSampleMs = lastTs + nextInterval();
        }

        if (frameIndex % 8 == 0) {
          // Let 'cancel' / 'free' messages through.
          await Future<void>.delayed(Duration.zero);
        }
        if (!kReleaseMode && frameIndex - lastLogFrames >= 150) {
          final secs = wall.elapsedMilliseconds / 1000;
          debugPrint(
            '🎞️ decoder: $frameIndex frames, '
            '${(frameIndex / secs).toStringAsFixed(1)} fps '
            '(video ${(lastTs / 1000).toStringAsFixed(1)}s in '
            '${secs.toStringAsFixed(1)}s), '
            'inference ~${inferMsEma.round()}ms',
          );
          lastLogFrames = frameIndex;
        }
      }

      // Wait for the last frame's detections before reporting completion.
      await detectorFree.future;
      if (!cancelled) main.send(VideoAnalysisDone(lastTs));
    } catch (e) {
      main.send(VideoAnalysisError('Video processing failed: $e'));
    } finally {
      cap?.release();
      control.close();
    }
  }
}

/// A video opened for decoding by [VideoAnalysisService.openForDecoding].
class OpenedVideo {
  final cv.VideoCapture cap;
  final bool hardware;
  final double fps;
  final double frameCount;

  /// Container rotation tag in degrees (0/90/180/270).
  final int meta;

  /// Rotation to apply to decoded frames (null: already upright).
  final int? rotateCode;

  const OpenedVideo(
    this.cap,
    this.hardware,
    this.fps,
    this.frameCount,
    this.meta,
    this.rotateCode,
  );
}
