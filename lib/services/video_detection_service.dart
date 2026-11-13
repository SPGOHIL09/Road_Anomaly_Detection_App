import 'dart:async';
import 'dart:io';
import 'package:image/image.dart' as img;

import '../models/detection.dart';
import 'video_processor.dart';
import 'inference_isolate.dart';

class VideoDetectionService {

  final InferenceIsolate isolate;

  bool _running = false;

  VideoDetectionService(this.isolate);

  Future<void> startDetection({
    required File videoFile,
    required Function(img.Image frame, List<Detection> detections) onFrame,
  }) async {

    _running = true;

    int timeMs = 0;
    const step = 120; // ~8 FPS

    while (_running) {

      final frameFile = await VideoProcessor.extractFrameAt(
        videoFile,
        timeMs,
      );

      if (frameFile == null) {
        timeMs += step;
        continue;
      }

      final bytes = await frameFile.readAsBytes();
      final image = img.decodeImage(bytes);

      if (image == null) {
        timeMs += step;
        continue;
      }

      final detections = await isolate.run(image);

      onFrame(image, detections);

      timeMs += step;

      await Future.delayed(const Duration(milliseconds: 20));
    }
  }

  void stop() {
    _running = false;
  }
}