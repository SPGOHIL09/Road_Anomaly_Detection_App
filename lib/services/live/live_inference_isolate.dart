import 'dart:async';
import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';

import '../../models/detection.dart';
import '../model_service.dart';
import 'live_frame.dart';
import 'live_preprocess.dart';

/// Result of one live inference. Boxes are **normalized** (0..1) to the
/// upright camera frame, so the UI can map them onto any preview size.
class LiveResult {
  final List<Detection> detections;
  final int inferenceMs;

  const LiveResult(this.detections, this.inferenceMs);
}

/// Background inference for the **live camera** pipeline only.
///
/// Owns its own isolate and model session; all colour conversion, rotation
/// and resizing happens here so the UI thread only copies plane references.
class LiveInferenceIsolate {
  Isolate? _isolate;
  SendPort? _sendPort;

  bool get isReady => _sendPort != null;

  Future<void> start(Uint8List modelBytes) async {
    final receivePort = ReceivePort();
    _isolate = await Isolate.spawn(_entry, [receivePort.sendPort, modelBytes]);

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

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _sendPort = null;
  }

  static Future<void> _entry(List<dynamic> args) async {
    final SendPort main = args[0];
    final Uint8List modelBytes = args[1];

    final port = ReceivePort();
    main.send(port.sendPort);

    final ModelService model;
    try {
      model = ModelService.withSession(
        await ModelService.createSession(modelBytes),
      );
    } catch (e) {
      main.send('Live model init failed: $e');
      return;
    }
    main.send('ready');

    await for (final message in port) {
      final LiveFrame frame = message[0];
      final SendPort reply = message[1];
      final sw = Stopwatch()..start();
      try {
        final pre = preprocessLiveFrame(frame);
        final preMs = sw.elapsedMilliseconds;
        final raw = model.detectTensor(pre.input);
        if (!kReleaseMode) {
          debugPrint(
            '📷 live worker: preprocess ${preMs}ms, '
            'model ${sw.elapsedMilliseconds - preMs}ms',
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
        reply.send(LiveResult(normalized, sw.elapsedMilliseconds));
      } catch (e) {
        reply.send('Live inference error: $e');
      }
    }
  }
}
