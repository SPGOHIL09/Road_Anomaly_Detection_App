import 'dart:typed_data';
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import '../models/detection.dart';
import '../utils/preprocessing.dart';
import '../utils/yolo_decoder.dart';
import '../utils/nms.dart';

class ModelService {

  OrtSession? _session;

  ModelService();

  ModelService.withSession(this._session);

  // ───────── Load Model Bytes ─────────

  static Future<Uint8List> loadModelBytes() async {
    final data = await rootBundle.load('assets/models/best.onnx');
    return data.buffer.asUint8List();
  }

  // ───────── Flatten Tensor ─────────

  List<double> _flattenTensor(dynamic tensor) {
    if (tensor is double) return [tensor];
    if (tensor is List) {
      return tensor.expand((e) => _flattenTensor(e)).toList();
    }
    return [];
  }

  // ───────── Run Inference ─────────

  Future<List<dynamic>> _runInference(List<double> input) async {

    if (_session == null) {
      throw Exception("ONNX session not initialized");
    }

    final inputTensor = OrtValueTensor.createTensorWithDataList(
      Float32List.fromList(input),
      [1, 3, 640, 640],
    );

    final runOptions = OrtRunOptions();

    final outputs = await _session!.run(
      runOptions,
      {'images': inputTensor},
    );

    inputTensor.release();
    runOptions.release();

    return outputs;
  }

  // ───────── Detection ─────────

  Future<List<Detection>> detectImage(
      img.Image image, {
        double confidenceThreshold = 0.3,  // Lowered from 0.1 to catch more defects
        double iouThreshold = 0.3,  // Lowered from 0.5 to be less aggressive with NMS
      }) async {

    try {

      // 🔥 Preprocess with metadata
      final result = preprocess(image);
      final input = result.input;

      final outputs = await _runInference(input);

      final rawTensor = (outputs.first as OrtValueTensor).value;
      final rawOutput = _flattenTensor(rawTensor);

      final decoded = decodeYOLO(rawOutput, confidenceThreshold);
      debugPrint("🔍 YOLO decoded ${decoded.length} raw detections");

      final filtered = nonMaxSupression(decoded, iouThreshold);
      debugPrint("🔍 After NMS: ${filtered.length} detections (IOU threshold: $iouThreshold)");

      // 🔥 FIX: Reverse letterbox mapping
      final corrected = filtered.map((det) {

        final box = det.boundingBox;

        final x = (box.left - result.xOffset) / result.scale;
        final y = (box.top - result.yOffset) / result.scale;
        final w = box.width / result.scale;
        final h = box.height / result.scale;

        return Detection(
          label: det.label,
          confidence: det.confidence,
          boundingBox: Rect.fromLTWH(x, y, w, h),
        );
      }).toList();

      return corrected;

    } catch (e) {
      print("Detection error: $e");
      return [];
    }
  }
}