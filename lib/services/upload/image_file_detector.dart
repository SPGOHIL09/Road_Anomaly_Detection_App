import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:opencv_dart/opencv_dart.dart' as cv;

import '../../models/detection.dart';
import '../../utils/preprocessing.dart';
import '../model_service.dart';

/// Detections for a photo. Boxes are in the pixel space of [width] x
/// [height] (the decoded, EXIF-rotated image, possibly decoded at reduced
/// size); the UI scales that space onto the displayed photo.
class ImageDetectionResult {
  final int width;
  final int height;
  final List<Detection> detections;

  const ImageDetectionResult(this.width, this.height, this.detections);
}

/// Detects defects in [path]. Runs inside the upload isolate.
///
/// High-resolution photos (12 MP, 2-3 MB) were slow because the prototype
/// decoded them with the pure-Dart `image` package on the UI thread
/// (~1.3 s on a Pixel 9) and then copied the full-size bitmap to the
/// isolate. OpenCV decodes natively (~0.1 s), applies EXIF orientation like
/// `Image.file` does, and downsizes to the model size with area averaging.
/// Formats OpenCV cannot read fall back to the prototype's Dart decoder.
Future<ImageDetectionResult> detectImagePath(
  ModelService model,
  String path,
) async {
  return _detectWithOpenCV(model, path) ?? await _detectWithDart(model, path);
}

ImageDetectionResult? _detectWithOpenCV(ModelService model, String path) {
  // JPEG can decode straight to 1/4 size (12 MP -> ~1020x768 in ~40 ms
  // instead of ~115 ms); that is still larger than the 640 model input.
  cv.Mat mat = cv.imread(path, flags: cv.IMREAD_REDUCED_COLOR_4);
  if (mat.isEmpty ||
      (mat.cols > mat.rows ? mat.cols : mat.rows) < kModelInputSize) {
    mat.dispose();
    mat = cv.imread(path);
  }
  try {
    if (mat.isEmpty) return null;
    final int w = mat.cols;
    final int h = mat.rows;
    final lb = LetterboxInfo.forSize(w, h);
    final resized = cv.resize(mat, (
      lb.newWidth,
      lb.newHeight,
    ), interpolation: cv.INTER_AREA);
    final input = tensorFromPacked(
      resized.data,
      lb.newWidth,
      lb.newHeight,
      lb,
      bgr: true,
    );
    resized.dispose();

    final detections = [
      for (final d in model.detectTensor(input))
        Detection(
          label: d.label,
          confidence: d.confidence,
          boundingBox: lb.toSource(d.boundingBox),
        ),
    ];
    return ImageDetectionResult(w, h, detections);
  } finally {
    mat.dispose();
  }
}

Future<ImageDetectionResult> _detectWithDart(
  ModelService model,
  String path,
) async {
  final image = img.decodeImage(File(path).readAsBytesSync());
  if (image == null) return const ImageDetectionResult(1, 1, []);
  final dets = await model.detectImage(image);
  return ImageDetectionResult(image.width, image.height, dets);
}
