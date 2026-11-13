import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:video_thumbnail/video_thumbnail.dart';

class VideoProcessor {

  // 🔥 Extract single frame at given timestamp
  static Future<File?> extractFrameAt(
      File videoFile,
      int timeMs,
      ) async {
    try {
      final filePath = await VideoThumbnail.thumbnailFile(
        video: videoFile.path,
        imageFormat: ImageFormat.JPEG,
        timeMs: timeMs,
        quality: 80,
        maxWidth: 640,
        maxHeight: 640,
      ).timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          debugPrint("⚠️  Frame extraction timed out at ${timeMs}ms");
          return null;
        },
      );

      if (filePath == null) return null;

      return File(filePath);

    } catch (e) {
      debugPrint("❌ Frame extraction error at ${timeMs}ms: $e");
      return null;
    }
  }
}


