import 'dart:isolate';
import 'package:image/image.dart' as img;

import 'package:road_anomaly_detector/models/detection.dart';
import 'model_service.dart';


class InferenceIsolate {

  late Isolate _isolate;
  late SendPort _sendPort;

  Future<void> start() async {
    final receivePort = ReceivePort();

    _isolate = await Isolate.spawn(_isolateEntry, receivePort.sendPort);

    _sendPort = await receivePort.first;
  }

  Future<List<Detection>> run(img.Image image) async {
    final responsePort = ReceivePort();
    _sendPort.send([image, responsePort.sendPort]);
    final result = await responsePort.first;

    return List<Detection>.from(result);
  }

  void dispose() {
    _isolate.kill(priority: Isolate.immediate);
  }

  static void _isolateEntry(SendPort mainSendPort) async {
    final port = ReceivePort();
    mainSendPort.send(port.sendPort);

    final modelService = ModelService();
    await modelService.loadModel();

    await for (final message in port) {
      final img.Image image = message[0];
      final SendPort replyPort = message[1];

      final detections = await modelService.detectImage(image);
      replyPort.send(detections);
    }

  }

}