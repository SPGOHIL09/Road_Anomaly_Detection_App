import 'dart:typed_data';

import '../../utils/preprocessing.dart';
import 'live_frame.dart';

/// A camera frame converted to upright, letterbox-resized RGB pixels
/// (tightly packed newWidth x newHeight x 3), ready for either engine.
class LivePackedFrame {
  final Uint8List rgb;
  final LetterboxInfo letterbox;
  final int uprightWidth;
  final int uprightHeight;

  const LivePackedFrame(
    this.rgb,
    this.letterbox,
    this.uprightWidth,
    this.uprightHeight,
  );
}

class LivePreprocessResult {
  final Float32List input;
  final LetterboxInfo letterbox;
  final int uprightWidth;
  final int uprightHeight;

  const LivePreprocessResult(
    this.input,
    this.letterbox,
    this.uprightWidth,
    this.uprightHeight,
  );
}

/// Converts a raw camera buffer straight into the letterboxed 640x640 CHW
/// model tensor (ONNX / CPU layout). See [packLiveFrame].
LivePreprocessResult preprocessLiveFrame(LiveFrame f) {
  final p = packLiveFrame(f);
  final lb = p.letterbox;
  return LivePreprocessResult(
    tensorFromPacked(p.rgb, lb.newWidth, lb.newHeight, lb),
    lb,
    p.uprightWidth,
    p.uprightHeight,
  );
}

/// Converts a raw camera buffer into upright, letterbox-resized RGB pixels
/// in a single pass: colour conversion, rotation, mirroring and
/// nearest-neighbour resize are fused, and only the ~300k destination pixels
/// are ever computed (the prototype converted every sensor pixel first, then
/// resized again).
LivePackedFrame packLiveFrame(LiveFrame f) {
  final int uw = f.uprightWidth;
  final int uh = f.uprightHeight;
  final lb = LetterboxInfo.forSize(uw, uh);
  final Uint8List out = Uint8List(lb.newWidth * lb.newHeight * 3);

  // Nearest-neighbour lookup tables from destination to upright coordinates.
  final Int32List ux = Int32List(lb.newWidth);
  for (int dx = 0; dx < lb.newWidth; dx++) {
    int x = ((dx + 0.5) / lb.scale).floor();
    if (x >= uw) x = uw - 1;
    ux[dx] = f.mirror ? uw - 1 - x : x;
  }

  final int w = f.width;
  final int h = f.height;
  final Uint8List p0 = f.plane0;
  final int s0 = f.plane0RowStride;
  final Uint8List? pu = f.planeU;
  final Uint8List? pv = f.planeV;
  final int uvRow = f.uvRowStride;
  final int uvPix = f.uvPixelStride;
  final int nv21Offset = s0 * h;

  for (int dy = 0; dy < lb.newHeight; dy++) {
    int uy = ((dy + 0.5) / lb.scale).floor();
    if (uy >= uh) uy = uh - 1;
    final int dstRow = dy * lb.newWidth;

    for (int dx = 0; dx < lb.newWidth; dx++) {
      final int x = ux[dx];

      // Upright (x, uy) -> sensor (sx, sy).
      int sx;
      int sy;
      switch (f.rotation) {
        case 90:
          sx = uy;
          sy = h - 1 - x;
          break;
        case 180:
          sx = w - 1 - x;
          sy = h - 1 - uy;
          break;
        case 270:
          sx = w - 1 - uy;
          sy = x;
          break;
        default:
          sx = x;
          sy = uy;
      }

      int r;
      int g;
      int b;
      if (f.format == LiveFrameFormat.bgra8888) {
        final int i = sy * s0 + sx * 4;
        b = p0[i];
        g = p0[i + 1];
        r = p0[i + 2];
      } else {
        final int yv = p0[sy * s0 + sx];
        int uv;
        int vv;
        if (f.format == LiveFrameFormat.nv21) {
          final int i = nv21Offset + (sy >> 1) * s0 + (sx >> 1) * 2;
          vv = p0[i];
          uv = p0[i + 1];
        } else {
          final int i = (sy >> 1) * uvRow + (sx >> 1) * uvPix;
          uv = pu![i];
          vv = pv![i];
        }
        // Same YUV->RGB coefficients as the prototype.
        r = (yv + vv * 1436 / 1024 - 179).round();
        g = (yv - uv * 46549 / 131072 + 44 - vv * 93604 / 131072 + 91).round();
        b = (yv + uv * 1814 / 1024 - 227).round();
        r = r < 0 ? 0 : (r > 255 ? 255 : r);
        g = g < 0 ? 0 : (g > 255 ? 255 : g);
        b = b < 0 ? 0 : (b > 255 ? 255 : b);
      }

      final int di = (dstRow + dx) * 3;
      out[di] = r;
      out[di + 1] = g;
      out[di + 2] = b;
    }
  }

  return LivePackedFrame(out, lb, uw, uh);
}
