import 'dart:typed_data';

import 'package:camera/camera.dart';

/// Pixel layout of a camera stream buffer.
enum LiveFrameFormat { yuv420, nv21, bgra8888 }

/// A camera frame copied out of [CameraImage] so it can be sent to the live
/// inference isolate. Holds raw planes plus everything needed to turn the
/// sensor buffer into an upright image (rotation / mirroring).
class LiveFrame {
  final LiveFrameFormat format;

  /// Sensor buffer size (before rotation).
  final int width;
  final int height;

  /// Y plane (yuv420 / nv21) or the single BGRA plane.
  final Uint8List plane0;
  final int plane0RowStride;

  /// U and V planes (yuv420 only).
  final Uint8List? planeU;
  final Uint8List? planeV;
  final int uvRowStride;
  final int uvPixelStride;

  /// Clockwise rotation (0/90/180/270) that makes the buffer upright.
  final int rotation;

  /// Mirror horizontally after rotating (front camera previews are mirrored).
  final bool mirror;

  const LiveFrame({
    required this.format,
    required this.width,
    required this.height,
    required this.plane0,
    required this.plane0RowStride,
    this.planeU,
    this.planeV,
    this.uvRowStride = 0,
    this.uvPixelStride = 1,
    this.rotation = 0,
    this.mirror = false,
  });

  /// Upright frame size (after rotation).
  int get uprightWidth => (rotation == 90 || rotation == 270) ? height : width;
  int get uprightHeight => (rotation == 90 || rotation == 270) ? width : height;

  /// Builds a [LiveFrame] from a camera stream image.
  ///
  /// [sensorOrientation] comes from [CameraDescription.sensorOrientation].
  /// The app is portrait-locked, so a landscape sensor buffer needs rotating
  /// by the sensor orientation; an already-portrait buffer needs none.
  /// Returns null for formats this pipeline cannot read.
  static LiveFrame? fromCameraImage(
    CameraImage image, {
    required int sensorOrientation,
    required bool mirror,
  }) {
    final bool landscapeBuffer = image.width > image.height;
    final int rotation = landscapeBuffer ? sensorOrientation % 360 : 0;
    final planes = image.planes;

    switch (image.format.group) {
      case ImageFormatGroup.bgra8888:
        return LiveFrame(
          format: LiveFrameFormat.bgra8888,
          width: image.width,
          height: image.height,
          plane0: planes[0].bytes,
          plane0RowStride: planes[0].bytesPerRow,
          rotation: rotation,
          mirror: mirror,
        );
      case ImageFormatGroup.nv21:
        return LiveFrame(
          format: LiveFrameFormat.nv21,
          width: image.width,
          height: image.height,
          plane0: planes[0].bytes,
          plane0RowStride: planes[0].bytesPerRow,
          rotation: rotation,
          mirror: mirror,
        );
      case ImageFormatGroup.yuv420:
        if (planes.length < 3) return null;
        return LiveFrame(
          format: LiveFrameFormat.yuv420,
          width: image.width,
          height: image.height,
          plane0: planes[0].bytes,
          plane0RowStride: planes[0].bytesPerRow,
          planeU: planes[1].bytes,
          planeV: planes[2].bytes,
          uvRowStride: planes[1].bytesPerRow,
          uvPixelStride: planes[1].bytesPerPixel ?? 1,
          rotation: rotation,
          mirror: mirror,
        );
      default:
        return null;
    }
  }
}
