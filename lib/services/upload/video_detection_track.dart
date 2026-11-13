import 'dart:ui';

import '../../models/detection.dart';
import '../../utils/nms.dart';

/// Timestamped detections for an uploaded video.
///
/// [at] answers "which boxes belong on the frame shown at this playback
/// position?". Boxes are interpolated between the two analysed frames that
/// surround the position, and a sample is never used further than one
/// sample interval away, so boxes disappear when the defect leaves the frame
/// instead of lingering on later frames.
class VideoDetectionTrack {
  final int sampleIntervalMs;

  final List<int> _times = [];
  final List<List<Detection>> _dets = [];

  bool complete = false;

  VideoDetectionTrack({required this.sampleIntervalMs});

  int get sampleCount => _times.length;

  /// Latest video time covered by analysis (-1 if nothing yet).
  int get analyzedUntilMs => _times.isEmpty ? -1 : _times.last;

  int get framesWithDefects => _dets.where((d) => d.isNotEmpty).length;

  void clear() {
    _times.clear();
    _dets.clear();
    complete = false;
  }

  void add(int timestampMs, List<Detection> detections) {
    if (_times.isEmpty || timestampMs > _times.last) {
      _times.add(timestampMs);
      _dets.add(detections);
      return;
    }
    final i = _lowerBound(timestampMs);
    if (i < _times.length && _times[i] == timestampMs) {
      _dets[i] = detections;
    } else {
      _times.insert(i, timestampMs);
      _dets.insert(i, detections);
    }
  }

  /// First index with time >= [t].
  int _lowerBound(int t) {
    int lo = 0, hi = _times.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_times[mid] < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  List<Detection> at(int positionMs) {
    if (_times.isEmpty) return const [];

    // b = first sample at/after position, a = the one before it.
    final bi = _lowerBound(positionMs);
    final int? ai = bi > 0 ? bi - 1 : null;
    final bool hasB = bi < _times.length;

    if (hasB && _times[bi] == positionMs) return _dets[bi];

    final int maxGap = sampleIntervalMs;
    final int half = sampleIntervalMs ~/ 2;

    if (!hasB) {
      // Past the last analysed frame: only valid very close to it.
      final a = ai!;
      return positionMs - _times[a] <= half ? _dets[a] : const [];
    }
    if (ai == null) {
      return _times[bi] - positionMs <= half ? _dets[bi] : const [];
    }

    final ta = _times[ai], tb = _times[bi];
    final gap = tb - ta;
    if (gap > maxGap * 2) {
      // Hole in the analysis: only use a sample if it is close enough.
      if (positionMs - ta <= half) return _dets[ai];
      if (tb - positionMs <= half) return _dets[bi];
      return const [];
    }

    final double t = (positionMs - ta) / gap;
    return _interpolate(_dets[ai], _dets[bi], t);
  }

  static List<Detection> _interpolate(
    List<Detection> a,
    List<Detection> b,
    double t,
  ) {
    final out = <Detection>[];
    final usedB = List<bool>.filled(b.length, false);

    for (final da in a) {
      int best = -1;
      double bestIou = 0.2;
      for (int j = 0; j < b.length; j++) {
        if (usedB[j] || b[j].label != da.label) continue;
        final o = iou(da, b[j]);
        if (o >= bestIou) {
          bestIou = o;
          best = j;
        }
      }
      if (best >= 0) {
        usedB[best] = true;
        final ra = da.boundingBox, rb = b[best].boundingBox;
        out.add(
          Detection(
            label: da.label,
            confidence:
                da.confidence + (b[best].confidence - da.confidence) * t,
            boundingBox: Rect.lerp(ra, rb, t)!,
          ),
        );
      } else if (t < 0.5) {
        out.add(da); // defect vanishes after a: show until halfway
      }
    }
    for (int j = 0; j < b.length; j++) {
      if (!usedB[j] && t >= 0.5) out.add(b[j]); // appears in b: from halfway
    }
    return out;
  }
}
