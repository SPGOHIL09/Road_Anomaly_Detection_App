import 'dart:typed_data';
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'package:flutter/services.dart';

import 'package:road_anomaly_detector/utils/nms.dart';
import 'package:road_anomaly_detector/utils/yolo_decoder.dart';

import '../models/detection.dart';
import '../utils/preprocessing.dart';

class ModelService {

  // ───────── Singleton Instance ─────────

  static final ModelService _instance = ModelService._internal();

  factory ModelService() {
    return _instance;
  }

  ModelService._internal();

  // ───────── Model Variables ─────────

  OrtSession? _session;

  bool _isLoaded = false;

  bool get isLoaded => _isLoaded;

  // ───────── Load Model ─────────

  Future<void> loadModel() async {

    if (_isLoaded) return;

    try {

      final modelBytes =
      await rootBundle.load('assets/models/best.onnx');

      final Uint8List bytes =
      modelBytes.buffer.asUint8List();

      final sessionOptions = OrtSessionOptions();

      _session =
      await OrtSession.fromBuffer(bytes, sessionOptions);

      sessionOptions.release();

      _isLoaded = true;

      print("ONNX Model Loaded Successfully");

    } catch (e) {

      print("Model loading failed: $e");

      rethrow;
    }
  }

  // ───────── Flatten ONNX Tensor Safely ─────────

  List<double> _flattenTensor(dynamic tensor) {

    if (tensor is double) {
      return [tensor];
    }

    if (tensor is List) {
      return tensor.expand((e) => _flattenTensor(e)).toList();
    }

    return [];
  }

  // ───────── Run Inference ─────────

  Future<List<dynamic>> _runInference(List<double> input) async {

    if (_session == null) {
      throw Exception("Model session not initialized");
    }

    final Float32List floatInput =
    Float32List.fromList(input);

    final inputTensor = OrtValueTensor.createTensorWithDataList(
      floatInput,
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

  // ───────── Image Detection ─────────

  Future<List<Detection>> detectImage(
      img.Image image, {
        double confidenceThreshold = 0.3,
        double iouThreshold = 0.55,
      }) async {

    if (!_isLoaded) {
      throw Exception("Model not loaded");
    }

    try {


      // Preprocess image
      final input = preprocess(image);

      print("Running inference...");
      // Run inference
      final outputs = await _runInference(input);

      // Extract ONNX tensor
      final rawTensor =
          (outputs.first as OrtValueTensor).value;

      // Flatten tensor
      final List<double> rawOutput =
      _flattenTensor(rawTensor);
      print("Output length: ${rawOutput.length}");

      // Decode YOLO predictions
      final decoded =
      decodeYOLO(rawOutput, confidenceThreshold);

      // Apply Non-Max Suppression
      final filtered =
      nonMaxSupression(decoded, iouThreshold);
      print("Detections found: ${filtered.length}");

      return filtered;

    } catch (e) {

      print("Detection error: $e");

      return [];
    }
  }
}