import 'dart:isolate';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

import '../models/detection.dart';
import 'model_service.dart';

/// Background inference for the **upload** pipeline (still images).
///
/// Video uploads use [VideoAnalysisService] and the live camera uses
/// [LiveInferenceIsolate]; each pipeline owns its own isolate.
class InferenceIsolate {
  late Isolate _isolate;
  late SendPort _sendPort;

  Future<void> start(Uint8List modelBytes) async {
    final receivePort = ReceivePort();

    _isolate = await Isolate.spawn(_isolateEntry, [
      receivePort.sendPort,
      modelBytes,
    ]);

    _sendPort = await receivePort.first as SendPort;
  }

  // ───────── KEEPS UPLOAD SCREEN WORKING PERFECTLY ─────────
  Future<List<Detection>> run(img.Image image) async {
    final responsePort = ReceivePort();
    _sendPort.send(['image', image, responsePort.sendPort]);
    final result = await responsePort.first;
    return List<Detection>.from(result);
  }

  void dispose() {
    _isolate.kill(priority: Isolate.immediate);
  }

  // 🔥 ENTRY POINT (Background Thread)
  static void _isolateEntry(List<dynamic> args) async {
    final SendPort mainSendPort = args[0];
    final Uint8List modelBytes = args[1];

    final port = ReceivePort();
    mainSendPort.send(port.sendPort);

    final session = await ModelService.createSession(modelBytes);
    final modelService = ModelService.withSession(session);

    await for (final message in port) {
      if (message is! List || message.isEmpty) continue;

      final String type = message[0];

      if (type == 'image') {
        final img.Image image = message[1];
        final SendPort replyPort = message[2];
        final detections = await modelService.detectImage(image);
        replyPort.send(detections);
      }
    }
  }
}
