import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:road_anomaly_detector/services/model_service.dart';
import 'package:road_anomaly_detector/utils/preprocessing.dart';

/// Verbatim copy of the prototype's original per-pixel preprocess, used as the
/// reference so the optimised version is proven to be bit-identical.
List<double> referencePreprocess(img.Image image) {
  const int size = 640;
  final double scale =
      size / (image.width > image.height ? image.width : image.height);
  final int newWidth = (image.width * scale).round();
  final int newHeight = (image.height * scale).round();
  final resized = img.copyResize(image, width: newWidth, height: newHeight);
  final padded = img.Image(width: size, height: size);
  img.fill(padded, color: img.ColorRgb8(114, 114, 114));
  final int xOffset = (size - newWidth) ~/ 2;
  final int yOffset = (size - newHeight) ~/ 2;
  img.compositeImage(padded, resized, dstX: xOffset, dstY: yOffset);
  final List<double> input = List.filled(3 * size * size, 0);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final pixel = padded.getPixel(x, y);
      final index = y * size + x;
      input[index] = pixel.r / 255.0;
      input[index + size * size] = pixel.g / 255.0;
      input[index + 2 * size * size] = pixel.b / 255.0;
    }
  }
  return input;
}

img.Image randomImage(int w, int h, int seed) {
  final rnd = Random(seed);
  final image = img.Image(width: w, height: h);
  for (final p in image) {
    p.setRgb(rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256));
  }
  return image;
}

void main() {
  group('preprocess', () {
    for (final dims in [
      [1280, 720],
      [480, 853],
      [333, 333],
      [1001, 57],
    ]) {
      test('matches original implementation for ${dims[0]}x${dims[1]}', () {
        final image = randomImage(dims[0], dims[1], dims[0] * 31 + dims[1]);
        final expected = Float32List.fromList(referencePreprocess(image));
        final actual = preprocess(image);
        expect(actual.input.length, expected.length);
        // Compare as float32: that is what reaches the model in both cases.
        expect(Float32List.fromList(actual.input), orderedEquals(expected));
      });
    }

    test('letterbox metadata unchanged', () {
      final r = preprocess(randomImage(1280, 720, 1));
      expect(r.scale, 0.5);
      expect(r.xOffset, 0);
      expect(r.yOffset, 140);
    });
  });

  group('tensorFromPacked', () {
    test('matches preprocess for an already-resized RGB buffer', () {
      final image = randomImage(640, 360, 7);
      final lb = LetterboxInfo.forSize(640, 360);
      final packed = image.getBytes(order: img.ChannelOrder.rgb);
      final fromPacked = tensorFromPacked(packed, 640, 360, lb);
      final reference = Float32List.fromList(referencePreprocess(image));
      expect(fromPacked, orderedEquals(reference));
    });

    test('BGR order swaps red and blue', () {
      final lb = LetterboxInfo.forSize(1, 1);
      final t = tensorFromPacked(Uint8List.fromList([10, 20, 30]), 1, 1, lb,
          bgr: true);
      const plane = 640 * 640;
      final i = lb.yOffset * 640 + lb.xOffset;
      expect(t[i], closeTo(30 / 255, 1e-6));
      expect(t[i + plane], closeTo(20 / 255, 1e-6));
      expect(t[i + 2 * plane], closeTo(10 / 255, 1e-6));
    });
  });

  group('LetterboxInfo', () {
    test('toSource inverts the forward mapping', () {
      final lb = LetterboxInfo.forSize(1920, 1080);
      final src = Rect.fromLTWH(100, 200, 300, 150);
      final model = Rect.fromLTWH(
        src.left * lb.scale + lb.xOffset,
        src.top * lb.scale + lb.yOffset,
        src.width * lb.scale,
        src.height * lb.scale,
      );
      final back = lb.toSource(model);
      expect(back.left, closeTo(src.left, 1e-6));
      expect(back.top, closeTo(src.top, 1e-6));
      expect(back.width, closeTo(src.width, 1e-6));
      expect(back.height, closeTo(src.height, 1e-6));
    });
  });

  group('flattenTensor', () {
    test('flattens [1][3][4] nested list in row-major order', () {
      final nested = [
        [
          [0.0, 1.0, 2.0, 3.0],
          [4.0, 5.0, 6.0, 7.0],
          [8.0, 9.0, 10.0, 11.0],
        ],
      ];
      final flat = ModelService.flattenTensor(nested);
      expect(flat, orderedEquals(List.generate(12, (i) => i.toDouble())));
    });
  });
}
