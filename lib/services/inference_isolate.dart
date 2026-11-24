import 'dart:isolate';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

import '../models/detection.dart';
import 'detector/detector_client.dart';
import 'upload/image_file_detector.dart';
import 'model_service.dart';

/// Background inference for the **upload** pipeline (still images).
///
/// Video uploads use [VideoAnalysisService] and the live camera uses
/// [LiveInferenceIsolate]; each pipeline owns its own isolate.
class InferenceIsolate {
  late Isolate _isolate;
  late SendPort _sendPort;

  /// [gpu] is the shared GPU engine's port, if it is ready.
  Future<void> start(Uint8List modelBytes, {SendPort? gpu}) async {
    final receivePort = ReceivePort();

    _isolate = await Isolate.spawn(_isolateEntry, [
      receivePort.sendPort,
      modelBytes,
      gpu,
    ]);

    _sendPort = await receivePort.first as SendPort;
  }

  /// Switches photo detection to the GPU engine once it becomes ready.
  void useGpu(SendPort gpu) => _sendPort.send(['gpu', gpu]);

  // ───────── KEEPS UPLOAD SCREEN WORKING PERFECTLY ─────────
  Future<List<Detection>> run(img.Image image) async {
    final responsePort = ReceivePort();
    _sendPort.send(['image', image, responsePort.sendPort]);
    final result = await responsePort.first;
    return List<Detection>.from(result);
  }

  /// Decodes and detects [path] entirely inside the isolate (fast path for
  /// high-resolution photos; nothing large crosses the isolate boundary).
  Future<ImageDetectionResult> runFile(String path) async {
    final responsePort = ReceivePort();
    _sendPort.send(['file', path, responsePort.sendPort]);
    final result = await responsePort.first;
    responsePort.close();
    return result as ImageDetectionResult;
  }

  void dispose() {
    _isolate.kill(priority: Isolate.immediate);
  }

  // 🔥 ENTRY POINT (Background Thread)
  static void _isolateEntry(List<dynamic> args) async {
    final SendPort mainSendPort = args[0];
    final Uint8List modelBytes = args[1];
    final SendPort? gpu = args[2];

    final port = ReceivePort();
    mainSendPort.send(port.sendPort);

    final session = await ModelService.createSession(modelBytes);
    final modelService = ModelService.withSession(session);
    final client = DetectorClient.withCpu(modelService, modelBytes, gpu: gpu);

    await for (final message in port) {
      if (message is! List || message.isEmpty) continue;

      final String type = message[0];

      if (type == 'gpu') {
        client.gpu = message[1] as SendPort;
      } else if (type == 'image') {
        final img.Image image = message[1];
        final SendPort replyPort = message[2];
        final detections = await modelService.detectImage(image);
        replyPort.send(detections);
      } else if (type == 'file') {
        final String path = message[1];
        final SendPort replyPort = message[2];
        try {
          replyPort.send(await detectImagePath(modelService, client, path));
        } catch (e) {
          replyPort.send(const ImageDetectionResult(1, 1, []));
        }
      }
    }
  }
}
