import 'dart:math';
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:road_anomaly_detector/models/detection.dart';
import 'package:road_anomaly_detector/services/live/detection_tracker.dart';
import 'package:road_anomaly_detector/services/live/live_frame.dart';
import 'package:road_anomaly_detector/services/live/live_preprocess.dart';
import 'package:road_anomaly_detector/utils/preprocessing.dart';

img.Image randomImage(int w, int h, int seed) {
  final rnd = Random(seed);
  final image = img.Image(width: w, height: h);
  for (final p in image) {
    p.setRgb(rnd.nextInt(256), rnd.nextInt(256), rnd.nextInt(256));
  }
  return image;
}

/// BGRA buffer with [pad] extra bytes per row, like real camera strides.
Uint8List toBgra(img.Image s, int pad) {
  final stride = s.width * 4 + pad;
  final out = Uint8List(stride * s.height);
  for (int y = 0; y < s.height; y++) {
    for (int x = 0; x < s.width; x++) {
      final p = s.getPixel(x, y);
      final i = y * stride + x * 4;
      out[i] = p.b.toInt();
      out[i + 1] = p.g.toInt();
      out[i + 2] = p.r.toInt();
      out[i + 3] = 255;
    }
  }
  return out;
}

Detection det(String label, double l, double t, double r, double b,
        [double c = 0.9]) =>
    Detection(label: label, confidence: c, boundingBox: Rect.fromLTRB(l, t, r, b));

void main() {
  // Upright 480x640 (portrait) -> letterbox scale is exactly 1, so the live
  // tensor must equal the packed upright pixels for every rotation.
  final upright = randomImage(480, 640, 42);
  final lb = LetterboxInfo.forSize(480, 640);
  final expected = tensorFromPacked(
      upright.getBytes(order: img.ChannelOrder.rgb), 480, 640, lb);

  for (final rotation in [0, 90, 180, 270]) {
    test('BGRA sensor buffer rotated $rotation° becomes upright', () {
      // Sensor buffer = upright rotated counter-clockwise by `rotation`,
      // i.e. rotating it clockwise by `rotation` restores the upright image.
      final sensor = rotation == 0
          ? upright
          : img.copyRotate(upright, angle: 360 - rotation);
      const pad = 16;
      final frame = LiveFrame(
        format: LiveFrameFormat.bgra8888,
        width: sensor.width,
        height: sensor.height,
        plane0: toBgra(sensor, pad),
        plane0RowStride: sensor.width * 4 + pad,
        rotation: rotation,
      );
      expect(frame.uprightWidth, 480);
      expect(frame.uprightHeight, 640);
      final result = preprocessLiveFrame(frame);
      expect(result.input, orderedEquals(expected));
    });
  }

  test('YUV420 honours Y row stride padding', () {
    const w = 64, h = 48, yStride = 80;
    final y = Uint8List(yStride * h);
    for (int r = 0; r < h; r++) {
      for (int c = 0; c < w; c++) {
        y[r * yStride + c] = (r * 5 + c * 3) % 256;
      }
      // Garbage in the padding must never be sampled.
      for (int c = w; c < yStride; c++) {
        y[r * yStride + c] = 255;
      }
    }
    final uv = Uint8List(32 * 24)..fillRange(0, 32 * 24, 128);
    final frame = LiveFrame(
      format: LiveFrameFormat.yuv420,
      width: w,
      height: h,
      plane0: y,
      plane0RowStride: yStride,
      planeU: uv,
      planeV: uv,
      uvRowStride: 32,
      uvPixelStride: 1,
    );
    final res = preprocessLiveFrame(frame);
    final lbx = res.letterbox;
    // Grey chroma -> red channel equals luma (+0.5 rounding bias of the prototype coefficients).
    for (final (dx, dy) in [(0, 0), (639, 0), (320, 200), (639, 479)]) {
      final sx = ((dx + 0.5) / lbx.scale).floor().clamp(0, w - 1);
      final sy = ((dy + 0.5) / lbx.scale).floor().clamp(0, h - 1);
      final i = (dy + lbx.yOffset) * 640 + dx + lbx.xOffset;
      expect(res.input[i] * 255, closeTo(y[sy * yStride + sx], 1.01),
          reason: 'pixel ($dx,$dy)');
    }
  });

  test('LiveFrame rotates landscape buffers only', () {
    final f = LiveFrame(
      format: LiveFrameFormat.bgra8888,
      width: 720,
      height: 480,
      plane0: Uint8List.fromList([]),
      plane0RowStride: 2880,
      rotation: 90,
    );
    expect(f.uprightWidth, 480);
    expect(f.uprightHeight, 720);
  });

  group('DetectionTracker', () {
    test('matches by overlap, not by list index', () {
      final t = DetectionTracker(newWeight: 1.0);
      t.update([
        det('Pothole', 0.0, 0.0, 0.2, 0.2),
        det('Pothole', 0.6, 0.6, 0.8, 0.8),
      ]);
      // Same two defects, reported in the opposite order and slightly moved.
      final out = t.update([
        det('Pothole', 0.61, 0.61, 0.81, 0.81),
        det('Pothole', 0.01, 0.01, 0.21, 0.21),
      ]);
      expect(out.length, 2);
      final lefts = out.map((d) => d.boundingBox.left).toList()..sort();
      expect(lefts[0], closeTo(0.01, 1e-9));
      expect(lefts[1], closeTo(0.61, 1e-9));
    });

    test('smooths matched boxes toward the new position', () {
      final t = DetectionTracker(newWeight: 0.5);
      t.update([det('Pothole', 0.0, 0.0, 0.4, 0.4)]);
      final out = t.update([det('Pothole', 0.1, 0.1, 0.5, 0.5)]);
      expect(out.single.boundingBox.left, closeTo(0.05, 1e-9));
    });

    test('drops a defect that left the frame after maxMisses', () {
      final t = DetectionTracker(maxMisses: 1);
      t.update([det('Pothole', 0.1, 0.1, 0.3, 0.3)]);
      t.update([det('Pothole', 0.1, 0.1, 0.3, 0.3)]);
      expect(t.update([]).length, 1, reason: 'one grace inference');
      expect(t.update([]), isEmpty, reason: 'gone after grace period');
    });

    test('a single unconfirmed detection is not kept after a miss', () {
      final t = DetectionTracker(maxMisses: 1);
      t.update([det('Pothole', 0.1, 0.1, 0.3, 0.3)]);
      expect(t.update([]), isEmpty);
    });

    test('different labels are never merged', () {
      final t = DetectionTracker();
      t.update([det('Pothole', 0.1, 0.1, 0.3, 0.3)]);
      final out = t.update([det('Alligator Crack', 0.1, 0.1, 0.3, 0.3)]);
      expect(out.map((d) => d.label), contains('Alligator Crack'));
    });
  });
}
