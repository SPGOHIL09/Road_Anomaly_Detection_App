import 'dart:typed_data';
import 'dart:ui';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:onnxruntime_v2/onnxruntime_v2.dart';

import '../models/detection.dart';
import '../utils/preprocessing.dart';
import '../utils/yolo_decoder.dart';
import '../utils/nms.dart';

/// Shared detector core: runs the ONNX model and decodes YOLO output.
///
/// Pipelines (image upload, video upload, live camera) each own their own
/// isolate and preprocessing; they all call into this class for inference.
class ModelService {

  OrtSession? _session;

  ModelService();

  ModelService.withSession(this._session);

  // ───────── Load Model Bytes ─────────

  static Future<Uint8List> loadModelBytes() async {
    final data = await rootBundle.load('assets/models/best.onnx');
    return data.buffer.asUint8List();
  }

  /// Creates a session inside the calling isolate (same options everywhere).
  static Future<OrtSession> createSession(Uint8List modelBytes) async {
    final sessionOptions = OrtSessionOptions();
    // Attempt to enable Mobile GPU/NPU if available
    try {
      await sessionOptions.appendDefaultProviders();
    } catch (_) {}
    final session = OrtSession.fromBuffer(modelBytes, sessionOptions);
    sessionOptions.release();
    return session;
  }

  // ───────── Flatten Tensor ─────────

  /// Flattens the nested-list tensor value into a contiguous [Float32List].
  static Float32List flattenTensor(dynamic tensor) {
    if (tensor is double) return Float32List.fromList([tensor]);

    // Walk the first elements to find the total element count.
    int total = 1;
    dynamic probe = tensor;
    while (probe is List) {
      total *= probe.length;
      if (probe.isEmpty) break;
      probe = probe[0];
    }

    final out = Float32List(total);
    int index = 0;
    void fill(dynamic node) {
      if (node is Float32List) {
        out.setRange(index, index + node.length, node);
        index += node.length;
      } else if (node is List) {
        if (node.isNotEmpty && node[0] is! List) {
          for (final v in node) {
            out[index++] = (v as num).toDouble();
          }
        } else {
          for (final child in node) {
            fill(child);
          }
        }
      }
    }

    fill(tensor);
    return out;
  }

  // ───────── Run Inference ─────────

  Float32List _runInference(List<double> input) {

    if (_session == null) {
      throw Exception("ONNX session not initialized");
    }

    final inputTensor = OrtValueTensor.createTensorWithDataList(
      input is Float32List ? input : Float32List.fromList(input),
      [1, 3, kModelInputSize, kModelInputSize],
    );

    final runOptions = OrtRunOptions();

    final outputs = _session!.run(
      runOptions,
      {'images': inputTensor},
    );

    inputTensor.release();
    runOptions.release();

    try {
      final rawTensor = (outputs.first as OrtValueTensor).value;
      return flattenTensor(rawTensor);
    } finally {
      // Native output buffers are not garbage collected; release them so
      // continuous video / camera inference does not leak memory.
      for (final o in outputs) {
        o?.release();
      }
    }
  }

  // ───────── Detection (model space) ─────────

  /// Runs the model on a prepared 640x640 CHW tensor.
  ///
  /// Returned boxes are in model-input (letterboxed 640x640) coordinates.
  List<Detection> detectTensor(
      List<double> input, {
        double confidenceThreshold = 0.3,
        double iouThreshold = 0.3,
      }) {
    final rawOutput = _runInference(input);
    final decoded = decodeYOLO(rawOutput, confidenceThreshold);
    return nonMaxSupression(decoded, iouThreshold);
  }

  // ───────── Detection (image upload) ─────────

  Future<List<Detection>> detectImage(
      img.Image image, {
        double confidenceThreshold = 0.3,  // Lowered from 0.1 to catch more defects
        double iouThreshold = 0.3,  // Lowered from 0.5 to be less aggressive with NMS
      }) async {

    try {

      // 🔥 Preprocess with metadata
      final result = preprocess(image);

      final filtered = detectTensor(
        result.input,
        confidenceThreshold: confidenceThreshold,
        iouThreshold: iouThreshold,
      );
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
      debugPrint("Detection error: $e");
      return [];
    }
  }
}
