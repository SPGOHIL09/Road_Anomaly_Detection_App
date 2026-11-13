import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../models/detection.dart';
import '../../utils/preprocessing.dart';
import '../model_service.dart';

/// Events emitted while a video is analysed.
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

/// Analyses an uploaded video in a background isolate (upload pipeline only).
///
/// Decoding, resizing and inference all run in the worker, so the UI thread
/// does nothing but play the video. Every result carries the timestamp of the
/// frame it was computed from; the screen looks boxes up by playback
/// position, so a box can never be drawn on a later frame than its own.
class VideoAnalysisService {
  /// Analyse one frame every [sampleIntervalMs] of video time.
  final int sampleIntervalMs;

  VideoAnalysisService({this.sampleIntervalMs = 200});

  Isolate? _isolate;
  SendPort? _control;
  ReceivePort? _events;
  StreamController<VideoAnalysisEvent>? _controller;

  bool get isRunning => _isolate != null;

  Stream<VideoAnalysisEvent> start(String videoPath, Uint8List modelBytes) {
    stop();
    final controller = StreamController<VideoAnalysisEvent>();
    final events = ReceivePort();
    _controller = controller;
    _events = events;

    events.listen((msg) {
      if (msg is SendPort) {
        _control = msg;
        return;
      }
      if (msg is VideoAnalysisEvent && !controller.isClosed) {
        controller.add(msg);
        if (msg is VideoAnalysisDone || msg is VideoAnalysisError) {
          _cleanup();
        }
      }
    });

    Isolate.spawn(_entry, [
          events.sendPort,
          videoPath,
          modelBytes,
          sampleIntervalMs,
        ])
        .then((iso) {
          if (_events != events) {
            iso.kill(priority: Isolate.immediate); // stopped while spawning
          } else {
            _isolate = iso;
          }
        })
        .catchError((Object e) {
          if (!controller.isClosed) controller.add(VideoAnalysisError('$e'));
          _cleanup();
        });

    return controller.stream;
  }

  /// Stops analysis. The worker releases the decoder and model on its own;
  /// it is force-killed if it does not exit promptly.
  void stop() {
    final iso = _isolate;
    _control?.send('cancel');
    if (iso != null) {
      Timer(
        const Duration(seconds: 2),
        () => iso.kill(priority: Isolate.immediate),
      );
    }
    _cleanup();
  }

  void _cleanup() {
    _isolate = null;
    _control = null;
    _events?.close();
    _events = null;
    final c = _controller;
    _controller = null;
    if (c != null && !c.isClosed) c.close();
  }

  // ─────────────────────── Worker isolate ───────────────────────

  static Future<void> _entry(List<dynamic> args) async {
    final SendPort out = args[0];
    final String path = args[1];
    final Uint8List modelBytes = args[2];
    final int interval = args[3];

    final control = ReceivePort();
    out.send(control.sendPort);
    var cancelled = false;
    control.listen((msg) {
      if (msg == 'cancel') cancelled = true;
    });

    cv.VideoCapture? cap;
    ModelService? model;
    try {
      final session = await ModelService.createSession(modelBytes);
      model = ModelService.withSession(session);

      cap = cv.VideoCapture.fromFile(path);
      if (!cap.isOpened) {
        out.send(const VideoAnalysisError('Could not open video'));
        return;
      }

      final double fps = cap.get(cv.CAP_PROP_FPS);
      final double frameMs = fps > 0 ? 1000.0 / fps : 1000.0 / 30.0;
      final double frameCount = cap.get(cv.CAP_PROP_FRAME_COUNT);

      // FFmpeg auto-rotates by the container's rotation tag. If the backend
      // did not, rotate ourselves so frames match what the player shows.
      final int meta = cap.get(cv.CAP_PROP_ORIENTATION_META).round() % 360;
      final bool auto = cap.get(cv.CAP_PROP_ORIENTATION_AUTO) != 0;
      final int? rotateCode = auto
          ? null
          : switch (meta) {
              90 => cv.ROTATE_90_CLOCKWISE,
              180 => cv.ROTATE_180,
              270 => cv.ROTATE_90_COUNTERCLOCKWISE,
              _ => null,
            };

      int frameIndex = 0;
      int lastTs = -1;
      int nextSampleMs = 0;
      bool infoSent = false;

      while (!cancelled) {
        final (ok, raw) = cap.read();
        if (!ok || raw.isEmpty) {
          raw.dispose();
          break;
        }

        // Presentation timestamp of this frame; fall back to index/fps if
        // the backend does not report a usable one.
        int ts = cap.get(cv.CAP_PROP_POS_MSEC).round();
        if (ts <= lastTs) ts = (frameIndex * frameMs).round();
        if (ts <= lastTs) ts = lastTs + 1;
        lastTs = ts;
        frameIndex++;

        cv.Mat frame = raw;
        if (rotateCode != null) {
          frame = cv.rotate(raw, rotateCode);
          raw.dispose();
        }

        if (!infoSent) {
          infoSent = true;
          final durationMs = frameCount > 0
              ? (frameCount * frameMs).round()
              : 0;
          out.send(VideoAnalysisInfo(frame.cols, frame.rows, fps, durationMs));
        }

        if (ts >= nextSampleMs) {
          nextSampleMs = ts + interval;
          final sw = Stopwatch()..start();
          final dets = _detect(model, frame);
          if (kDebugMode) {
            debugPrint(
              '🎞️ video ${ts}ms: ${dets.length} detections '
              '(${sw.elapsedMilliseconds}ms)',
            );
          }
          out.send(VideoFrameDetections(ts, dets));
        }
        frame.dispose();

        // Yield so a 'cancel' message can be received between frames.
        await Future<void>.delayed(Duration.zero);
      }

      if (!cancelled) out.send(VideoAnalysisDone(lastTs));
    } catch (e) {
      out.send(VideoAnalysisError('Video analysis failed: $e'));
    } finally {
      cap?.release();
      model?.release();
      control.close();
    }
  }

  static List<Detection> _detect(ModelService model, cv.Mat frame) {
    final int w = frame.cols;
    final int h = frame.rows;
    final lb = LetterboxInfo.forSize(w, h);
    final resized = cv.resize(frame, (
      lb.newWidth,
      lb.newHeight,
    ), interpolation: cv.INTER_LINEAR);
    final input = tensorFromPacked(
      resized.data,
      lb.newWidth,
      lb.newHeight,
      lb,
      bgr: true,
    );
    resized.dispose();

    final dets = model.detectTensor(input);
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
}
