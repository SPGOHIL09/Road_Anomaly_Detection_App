import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// A downscaled, upright RGB frame from [HwVideoDecoder].
class HwVideoFrame {
  /// Presentation time relative to the first frame (same as FFmpeg's).
  final int timestampUs;
  final Uint8List rgb;
  const HwVideoFrame(this.timestampUs, this.rgb);
}

/// Android-only video decoder: MediaCodec decodes into a GPU texture, the
/// GPU rotates and area-downscales it to the size the model needs, and only
/// that small RGB frame is read back (native side: `HwVideoDecoder.java`).
///
/// A 4K frame never reaches the CPU, so 4K videos decode at the hardware
/// decoder's speed (~55-60 fps for 44 Mbit/s 4K HEVC on a Pixel 9) using
/// under one CPU core, against ~35-45 fps on ~5 cores with FFmpeg.
///
/// Colours are converted from raw YUV with the BT.601 matrix, as OpenCV's
/// FFmpeg backend does, so frames match the software decoder (mean
/// difference under 1/255 after downscaling).
///
/// Works from background isolates once
/// `BackgroundIsolateBinaryMessenger.ensureInitialized` has been called.
class HwVideoDecoder {
  static const _channel = MethodChannel(
    'road_anomaly_detector/hw_video_decoder',
  );

  final int _id;

  /// Upright frame size (after rotation).
  final int width;
  final int height;

  /// Container rotation tag and the rotation applied to frames (degrees
  /// clockwise).
  final int meta;
  final int rotation;
  final double frameRate;
  final int durationMs;
  final String codec;

  /// Whether colours are converted with BT.601 (else the driver's matrix).
  final bool yuv601;

  bool _closed = false;

  HwVideoDecoder._(
    this._id,
    this.width,
    this.height,
    this.meta,
    this.rotation,
    this.frameRate,
    this.durationMs,
    this.codec,
    this.yuv601,
  );

  /// Opens [path], or returns null when hardware decoding is unavailable
  /// (not Android, unsupported codec, no GPU support). [expectPortrait] is
  /// the orientation the player shows; frames are rotated to match it.
  static Future<HwVideoDecoder?> open(
    String path, {
    bool? expectPortrait,
  }) async {
    if (!Platform.isAndroid) return null;
    try {
      final m = await _channel.invokeMapMethod<String, dynamic>('open', {
        'path': path,
        'expectPortrait': expectPortrait,
      });
      if (m == null) return null;
      return HwVideoDecoder._(
        m['id'] as int,
        m['width'] as int,
        m['height'] as int,
        m['meta'] as int,
        m['rotation'] as int,
        (m['frameRate'] as num).toDouble(),
        ((m['durationUs'] as num) / 1000).round(),
        m['codec'] as String? ?? '?',
        m['yuv601'] as bool? ?? false,
      );
    } on PlatformException catch (e) {
      if (!kReleaseMode) debugPrint('🎞️ hardware decoder unavailable: $e');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Decodes (dropping frames without reading them back) until the first
  /// frame at or after [minTimestampUs], and returns it downscaled to
  /// [outWidth] x [outHeight] RGB. Returns null at the end of the video.
  Future<HwVideoFrame?> next(
    int minTimestampUs,
    int outWidth,
    int outHeight,
  ) async {
    if (_closed) return null;
    final m = await _channel.invokeMapMethod<String, dynamic>('next', {
      'id': _id,
      'minRelUs': minTimestampUs,
      'outW': outWidth,
      'outH': outHeight,
    });
    if (m == null) return null;
    return HwVideoFrame(m['relUs'] as int, m['rgb'] as Uint8List);
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _channel.invokeMethod('close', {'id': _id});
    } catch (_) {}
  }
}
