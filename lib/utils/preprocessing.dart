import 'dart:typed_data';
import 'dart:ui';

import 'package:image/image.dart' as img;

/// Side length of the square YOLO input tensor.
const int kModelInputSize = 640;

/// Grey value YOLO uses for letterbox padding.
const int kLetterboxPadValue = 114;

/// Geometry of a letterbox transform from a source frame into the
/// [kModelInputSize] x [kModelInputSize] model input.
///
/// Shared by every pipeline (image upload, video upload, live camera) so all
/// of them map boxes back with exactly the same math.
class LetterboxInfo {
  final double scale;
  final int xOffset;
  final int yOffset;
  final int newWidth;
  final int newHeight;

  const LetterboxInfo({
    required this.scale,
    required this.xOffset,
    required this.yOffset,
    required this.newWidth,
    required this.newHeight,
  });

  factory LetterboxInfo.forSize(int width, int height) {
    const int size = kModelInputSize;
    final double scale = size / (width > height ? width : height);
    final int newWidth = (width * scale).round();
    final int newHeight = (height * scale).round();
    return LetterboxInfo(
      scale: scale,
      xOffset: (size - newWidth) ~/ 2,
      yOffset: (size - newHeight) ~/ 2,
      newWidth: newWidth,
      newHeight: newHeight,
    );
  }

  /// Maps a box from model-input (640x640) space back to source-frame pixels.
  Rect toSource(Rect box) {
    return Rect.fromLTWH(
      (box.left - xOffset) / scale,
      (box.top - yOffset) / scale,
      box.width / scale,
      box.height / scale,
    );
  }
}

class PreprocessResult {
  final List<double> input;
  final double scale;
  final int xOffset;
  final int yOffset;

  PreprocessResult({
    required this.input,
    required this.scale,
    required this.xOffset,
    required this.yOffset,
  });
}

/// Letterboxes [image] into a 640x640 CHW float tensor (RGB, 0..1).
///
/// Output is identical to the original per-pixel implementation; it just
/// writes into a [Float32List] from the raw byte buffer instead of
/// allocating a pixel object per sample.
PreprocessResult preprocess(img.Image image) {
  const int size = kModelInputSize;
  final lb = LetterboxInfo.forSize(image.width, image.height);

  final resized = img.copyResize(
    image,
    width: lb.newWidth,
    height: lb.newHeight,
  );

  final padded = img.Image(width: size, height: size);
  img.fill(
    padded,
    color: img.ColorRgb8(
      kLetterboxPadValue,
      kLetterboxPadValue,
      kLetterboxPadValue,
    ),
  );

  img.compositeImage(padded, resized, dstX: lb.xOffset, dstY: lb.yOffset);

  final Uint8List rgb = padded.getBytes(order: img.ChannelOrder.rgb);
  const int plane = size * size;
  final Float32List input = Float32List(3 * plane);

  for (int i = 0, p = 0; i < plane; i++, p += 3) {
    input[i] = rgb[p] / 255.0;
    input[i + plane] = rgb[p + 1] / 255.0;
    input[i + 2 * plane] = rgb[p + 2] / 255.0;
  }

  return PreprocessResult(
    input: input,
    scale: lb.scale,
    xOffset: lb.xOffset,
    yOffset: lb.yOffset,
  );
}

/// Fills a 640x640 CHW tensor from an already letterbox-resized, tightly
/// packed 3-channel buffer of [width] x [height] pixels.
///
/// [bgr] selects the channel order of [pixels]: OpenCV frames are BGR.
Float32List tensorFromPacked(
  Uint8List pixels,
  int width,
  int height,
  LetterboxInfo lb, {
  bool bgr = false,
}) {
  const int size = kModelInputSize;
  const int plane = size * size;
  const double pad = kLetterboxPadValue / 255.0;
  final Float32List input = Float32List(3 * plane)
    ..fillRange(0, 3 * plane, pad);

  final int rOff = bgr ? 2 : 0;
  final int bOff = bgr ? 0 : 2;

  for (int y = 0; y < height; y++) {
    final int dstRow = (y + lb.yOffset) * size + lb.xOffset;
    int src = y * width * 3;
    for (int x = 0; x < width; x++, src += 3) {
      final int i = dstRow + x;
      input[i] = pixels[src + rOff] / 255.0;
      input[i + plane] = pixels[src + 1] / 255.0;
      input[i + 2 * plane] = pixels[src + bOff] / 255.0;
    }
  }
  return input;
}
