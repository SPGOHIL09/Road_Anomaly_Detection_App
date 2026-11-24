import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../models/detection.dart';
import '../detector/detector_client.dart';
import 'live_frame.dart';
import 'live_preprocess.dart';

/// Result of one live inference. Boxes are **normalized** (0..1) to the
/// upright camera frame, so the UI can map them onto any preview size.
class LiveResult {
  final List<Detection> detections;
  final int inferenceMs;

  /// 'GPU' or 'CPU': which engine produced this result.
  final String engine;

  const LiveResult(this.detections, this.inferenceMs, this.engine);
}

/// Background inference for the **live camera** pipeline only.
///
/// Owns its own isolate and model session; all colour conversion, rotation
/// and resizing happens here so the UI thread only copies plane references.
class LiveInferenceIsolate {
  Isolate? _isolate;
  SendPort? _sendPort;

  bool get isReady => _sendPort != null;

  /// [gpu] is the shared GPU engine's port, if it is ready.
  Future<void> start(Uint8List modelBytes, {SendPort? gpu}) async {
    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(_entry, [
      receivePort.sendPort,
      modelBytes,
      gpu,
    ]);

    final completer = Completer<void>();
    SendPort? workerPort;
    late final StreamSubscription sub;
    sub = receivePort.listen((msg) {
      if (msg is SendPort) {
        workerPort = msg;
      } else if (msg == 'ready') {
        _sendPort = workerPort;
        sub.cancel();
        receivePort.close();
        completer.complete();
      } else if (msg is String) {
        sub.cancel();
        receivePort.close();
        completer.completeError(Exception(msg));
      }
    });
    return completer.future;
  }

  Future<LiveResult> process(LiveFrame frame) async {
    final port = _sendPort;
    if (port == null) throw StateError('Live inference isolate not ready');
    final responsePort = ReceivePort();
    port.send([frame, responsePort.sendPort]);
    final result = await responsePort.first;
    responsePort.close();
    if (result is String) throw Exception(result);
    return result as LiveResult;
  }

  /// Switches live detection to the GPU engine once it becomes ready.
  void useGpu(SendPort gpu) => _sendPort?.send(['gpu', gpu]);

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
  }

  static Future<void> _entry(List<dynamic> args) async {
    final SendPort main = args[0];
    final Uint8List modelBytes = args[1];
    final SendPort? gpu = args[2];

    final port = ReceivePort();
    main.send(port.sendPort);

    // GPU engine when available; CPU session (in this isolate) otherwise.
    final client = DetectorClient(modelBytes, gpu: gpu);
    if (gpu == null) {
      try {
        await client.ensureCpu();
      } catch (e) {
        main.send('Live model init failed: $e');
        return;
      }
    }
    main.send('ready');

    await for (final message in port) {
      if (message is List && message[0] == 'gpu') {
        client.gpu = message[1] as SendPort;
        continue;
      }
      final LiveFrame frame = message[0];
      final SendPort reply = message[1];
      final sw = Stopwatch()..start();
      try {
        final pre = packLiveFrame(frame);
        final preMs = sw.elapsedMilliseconds;
        final raw = await client.detectPacked(
          pre.rgb,
          pre.letterbox,
          bgr: false,
        );
        if (!kReleaseMode) {
          debugPrint(
            '📷 live worker: preprocess ${preMs}ms, '
            'model ${sw.elapsedMilliseconds - preMs}ms (${client.engine})',
          );
        }
        final w = pre.uprightWidth.toDouble();
        final h = pre.uprightHeight.toDouble();

        final normalized = <Detection>[];
        for (final det in raw) {
          final src = pre.letterbox.toSource(det.boundingBox);
          final box = Rect.fromLTRB(
            (src.left / w).clamp(0.0, 1.0),
            (src.top / h).clamp(0.0, 1.0),
            (src.right / w).clamp(0.0, 1.0),
            (src.bottom / h).clamp(0.0, 1.0),
          );
          if (box.width <= 0 || box.height <= 0) continue;
          normalized.add(
            Detection(
              label: det.label,
              confidence: det.confidence,
              boundingBox: box,
            ),
          );
        }
        reply.send(
          LiveResult(normalized, sw.elapsedMilliseconds, client.engine),
        );
      } catch (e) {
        reply.send('Live inference error: $e');
      }
    }
  }
}
