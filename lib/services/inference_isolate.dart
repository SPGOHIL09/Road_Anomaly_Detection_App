import 'dart:isolate';
import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:onnxruntime_v2/onnxruntime_v2.dart';


import '../models/detection.dart';
import 'model_service.dart';

class InferenceIsolate {
  late Isolate _isolate;
  late SendPort _sendPort;

  Future<void> start(Uint8List modelBytes) async {
    final receivePort = ReceivePort();

    _isolate = await Isolate.spawn(
      _isolateEntry,
      [receivePort.sendPort, modelBytes],
    );

    _sendPort = await receivePort.first as SendPort;
  }

  // ───────── KEEPS UPLOAD SCREEN WORKING PERFECTLY ─────────
  Future<List<Detection>> run(img.Image image) async {
    final responsePort = ReceivePort();
    // Added 'image' tag so the isolate knows how to handle it
    _sendPort.send(['image', image, responsePort.sendPort]);
    final result = await responsePort.first;
    return List<Detection>.from(result);
  }

  // ───────── NEW: FOR LIVE CAMERA DETECTION ONLY ─────────
  Future<List<Detection>> runFromCamera(
      int width,
      int height,
      Uint8List y,
      Uint8List u,
      Uint8List v,
      int uvRowStride,
      int uvPixelStride,
      ) async {
    final responsePort = ReceivePort();
    _sendPort.send([
      'camera',
      width,
      height,
      y,
      u,
      v,
      uvRowStride,
      uvPixelStride,
      responsePort.sendPort
    ]);
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

    final sessionOptions = OrtSessionOptions();

    // Attempt to enable Mobile GPU/NPU if available
    try {
      sessionOptions.appendDefaultProviders();
    } catch (_) {}

    final session = await OrtSession.fromBuffer(
      modelBytes,
      sessionOptions,
    );
    sessionOptions.release();

    final modelService = ModelService.withSession(session);

    await for (final message in port) {
      if (message is! List || message.isEmpty) continue;

      final String type = message[0];

      // 1. Handles Image/Video Uploads (No changes to logic)
      if (type == 'image') {
        final img.Image image = message[1];
        final SendPort replyPort = message[2];
        final detections = await modelService.detectImage(image);
        replyPort.send(detections);
      }
      // 2. Handles Live Camera Stream (Math done in background!)
      else if (type == 'camera') {
        final int width = message[1];
        final int height = message[2];
        final Uint8List yp = message[3];
        final Uint8List up = message[4];
        final Uint8List vp = message[5];
        final int uvRowStride = message[6];
        final int uvPixelStride = message[7];
        final SendPort replyPort = message[8];

        final img.Image imgBuffer = img.Image(width: width, height: height);

        for (int yPos = 0; yPos < height; yPos++) {
          for (int xPos = 0; xPos < width; xPos++) {
            final uvIndex = uvPixelStride * (xPos ~/ 2) + uvRowStride * (yPos ~/ 2);
            final index = yPos * width + xPos;

            final yVal = yp[index];
            final uVal = up[uvIndex];
            final vVal = vp[uvIndex];

            int r = (yVal + vVal * 1436 / 1024 - 179).round();
            int g = (yVal - uVal * 46549 / 131072 + 44 - vVal * 93604 / 131072 + 91).round();
            int b = (yVal + uVal * 1814 / 1024 - 227).round();

            r = r.clamp(0, 255);
            g = g.clamp(0, 255);
            b = b.clamp(0, 255);

            imgBuffer.setPixelRgb(xPos, yPos, r, g, b);
          }
        }

        final detections = await modelService.detectImage(imgBuffer);
        replyPort.send(detections);
      }
    }
  }
}