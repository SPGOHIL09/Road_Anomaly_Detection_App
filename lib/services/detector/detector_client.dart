import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../../models/detection.dart';
import '../../utils/preprocessing.dart';
import '../model_service.dart';
import 'gpu_detector_service.dart';

/// Inference as seen from inside a pipeline's worker isolate.
///
/// Uses the shared GPU engine when it is available ([gpu]); otherwise, or
/// if a GPU request fails, ONNX Runtime on the CPU in this isolate. The CPU
/// session is only created when it is actually needed.
class DetectorClient {
  final Uint8List _onnxBytes;
  SendPort? gpu;
  ModelService? _cpu;

  DetectorClient(this._onnxBytes, {this.gpu});

  /// Uses an already-created CPU session (e.g. the photo isolate's).
  DetectorClient.withCpu(ModelService cpu, this._onnxBytes, {this.gpu})
    : _cpu = cpu;

  bool get usesGpu => gpu != null;

  String get engine => usesGpu ? 'GPU' : 'CPU';

  /// Detects on a letterboxed, tightly packed newW x newH x 3 buffer.
  /// Returned boxes are in 640x640 model space.
  Future<List<Detection>> detectPacked(
    Uint8List packed,
    LetterboxInfo lb, {
    required bool bgr,
  }) async {
    final engine = gpu;
    if (engine != null) {
      try {
        return await requestGpuDetection(engine, packed, lb, bgr: bgr);
      } catch (e) {
        debugPrint('GPU detection failed, switching to CPU: $e');
        gpu = null;
      }
    }
    final cpu = await ensureCpu();
    return cpu.detectTensor(
      tensorFromPacked(packed, lb.newWidth, lb.newHeight, lb, bgr: bgr),
    );
  }

  /// Creates the CPU session now (to surface load errors early).
  Future<ModelService> ensureCpu() async => _cpu ??= ModelService.withSession(
    await ModelService.createSession(_onnxBytes),
  );

  void release() {
    _cpu?.release();
    _cpu = null;
  }
}
