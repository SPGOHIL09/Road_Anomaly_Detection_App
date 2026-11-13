import 'dart:ui';

import '../../models/detection.dart';
import '../../utils/nms.dart';

class _Track {
  Detection det;
  int hits = 1;
  int misses = 0;

  _Track(this.det);
}

/// Light IoU tracker for the live camera overlay.
///
/// The prototype smoothed boxes by list index, so when the detection order
/// changed a box was blended with a *different* defect and slid across the
/// screen. Here each new box is matched to the previous box it overlaps most
/// (same label), smoothed toward the new position, and kept for at most
/// [maxMisses] missed inferences so boxes don't flicker but never linger.
class DetectionTracker {
  /// Minimum IoU to treat two boxes as the same defect.
  final double matchIou;

  /// Weight of the newest box when smoothing (higher = more responsive).
  final double newWeight;

  /// How many consecutive inferences a lost track stays visible.
  final int maxMisses;

  final List<_Track> _tracks = [];

  DetectionTracker({
    this.matchIou = 0.3,
    this.newWeight = 0.6,
    this.maxMisses = 1,
  });

  void reset() => _tracks.clear();

  List<Detection> update(List<Detection> detections) {
    final unmatchedTracks = List<_Track>.from(_tracks);
    final fresh = <_Track>[];

    final sorted = List<Detection>.from(detections)
      ..sort((a, b) => b.confidence.compareTo(a.confidence));

    for (final det in sorted) {
      _Track? best;
      double bestIou = matchIou;
      for (final t in unmatchedTracks) {
        if (t.det.label != det.label) continue;
        final overlap = iou(t.det, det);
        if (overlap >= bestIou) {
          bestIou = overlap;
          best = t;
        }
      }

      if (best == null) {
        fresh.add(_Track(det));
        continue;
      }

      unmatchedTracks.remove(best);
      final a = best.det.boundingBox;
      final b = det.boundingBox;
      final k = newWeight;
      best.det = Detection(
        label: det.label,
        confidence: det.confidence,
        boundingBox: Rect.fromLTRB(
          a.left + (b.left - a.left) * k,
          a.top + (b.top - a.top) * k,
          a.right + (b.right - a.right) * k,
          a.bottom + (b.bottom - a.bottom) * k,
        ),
      );
      best.hits++;
      best.misses = 0;
    }

    for (final t in unmatchedTracks) {
      t.misses++;
    }
    _tracks
      ..removeWhere((t) => t.misses > maxMisses)
      ..addAll(fresh);

    return [
      for (final t in _tracks)
        if (t.misses == 0 || t.hits >= 2) t.det,
    ];
  }
}
