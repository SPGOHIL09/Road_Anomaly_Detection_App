import 'dart:math';
import 'dart:ui';

import '../../models/detection.dart';
import '../../utils/nms.dart';

/// One physical defect followed through the video: a single stable label
/// and a box that moves with it, built from many per-frame detections.
class DefectTrack {
  final int id;
  final String label;

  /// Highest confidence seen for this defect.
  final double confidence;

  /// Observation times (ms) and the smoothed boxes at those times.
  final List<int> times;
  final List<Rect> boxes;

  const DefectTrack(
    this.id,
    this.label,
    this.confidence,
    this.times,
    this.boxes,
  );

  int get startMs => times.first;
  int get endMs => times.last;
}

/// Turns the per-frame detections of a whole-video scan into stable,
/// tracked defects for playback.
///
/// The detector sees every frame independently, so a defect's box jitters,
/// its class can flip (e.g. longitudinal/transverse crack), and it can be
/// missed for a frame or two. Here detections are linked across frames into
/// tracks (overlap with the track's motion-predicted position), each track
/// gets one label (confidence-weighted vote), its box is smoothed, short
/// gaps are bridged, and unconfirmed one-off detections are dropped.
class DefectTracks {
  final List<DefectTrack> tracks;

  /// Typical spacing of scanned frames (ms); used to bridge gaps.
  final int sampleIntervalMs;

  const DefectTracks._(this.tracks, this.sampleIntervalMs);

  static const DefectTracks empty = DefectTracks._([], 100);

  int get count => tracks.length;

  /// [samples]: scan results in time order, boxes normalized to the frame.
  static DefectTracks build(
    List<(int, List<Detection>)> samples, {
    double linkIou = 0.15,
    int maxMissedSamples = 3,
    int minObservations = 3,
    double minPeakConfidence = 0.5,
  }) {
    if (samples.isEmpty) return empty;
    final interval = _medianInterval(samples);

    final open = <_Building>[];
    final done = <_Building>[];
    int nextId = 1;

    for (final (ts, dets) in samples) {
      // Candidate links: (score, track, detection).
      final pairs = <(double, _Building, Detection)>[];
      for (final t in open) {
        final predicted = t.predictAt(ts);
        for (final d in dets) {
          final s = _linkScore(predicted, d.boundingBox, linkIou);
          if (s > 0) pairs.add((s, t, d));
        }
      }
      pairs.sort((a, b) => b.$1.compareTo(a.$1));

      final usedTracks = <_Building>{};
      final usedDets = <Detection>{};
      for (final (_, t, d) in pairs) {
        if (usedTracks.contains(t) || usedDets.contains(d)) continue;
        usedTracks.add(t);
        usedDets.add(d);
        t.add(ts, d);
      }

      for (final t in open) {
        if (!usedTracks.contains(t)) t.missed++;
      }
      for (final t in open.where((t) => t.missed > maxMissedSamples).toList()) {
        open.remove(t);
        done.add(t);
      }
      for (final d in dets) {
        if (!usedDets.contains(d)) open.add(_Building(nextId++)..add(ts, d));
      }
    }
    done.addAll(open);

    final tracks = <DefectTrack>[];
    for (final b in done) {
      final peak = b.confidences.reduce(max);
      final confirmed =
          b.times.length >= minObservations ||
          (b.times.length >= 2 && peak >= 0.6);
      if (!confirmed || peak < minPeakConfidence) continue;
      tracks.add(
        DefectTrack(b.id, b.votedLabel, peak, b.times, _smooth(b.boxes)),
      );
    }
    tracks.sort((a, b) => a.startMs.compareTo(b.startMs));
    return DefectTracks._(tracks, interval);
  }

  /// Boxes to draw on the frame shown at [positionMs]: one per defect.
  List<Detection> at(int positionMs) {
    final hold = sampleIntervalMs ~/ 2;
    final out = <Detection>[];
    for (final t in tracks) {
      if (positionMs < t.startMs - hold || positionMs > t.endMs + hold)
        continue;
      final box = _boxAt(t, positionMs);
      if (box == null) continue;
      out.add(
        Detection(label: t.label, confidence: t.confidence, boundingBox: box),
      );
    }
    return out;
  }

  Rect? _boxAt(DefectTrack t, int ms) {
    final times = t.times;
    if (ms <= times.first) return t.boxes.first;
    if (ms >= times.last) return t.boxes.last;
    int lo = 0, hi = times.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (times[mid] <= ms) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final f = (ms - times[lo]) / (times[hi] - times[lo]);
    return Rect.lerp(t.boxes[lo], t.boxes[hi], f);
  }

  static int _medianInterval(List<(int, List<Detection>)> s) {
    if (s.length < 2) return 100;
    final gaps = [for (int i = 1; i < s.length; i++) s[i].$1 - s[i - 1].$1]
      ..sort();
    return max(1, gaps[gaps.length ~/ 2]);
  }

  /// Overlap with the predicted box; falls back to a weak link when the
  /// centres are close and the sizes similar (fast motion between frames).
  static double _linkScore(Rect predicted, Rect box, double minIou) {
    final o = _iou(predicted, box);
    if (o >= minIou) return o;
    final scale = max(predicted.width, predicted.height);
    final dist = (predicted.center - box.center).distance;
    final ratio =
        (box.width * box.height) /
        max(1e-9, predicted.width * predicted.height);
    if (dist <= 0.6 * scale && ratio > 0.4 && ratio < 2.5) return 0.05;
    return 0;
  }

  static double _iou(Rect a, Rect b) => iou(
    Detection(label: '', confidence: 0, boundingBox: a),
    Detection(label: '', confidence: 0, boundingBox: b),
  );

  /// Centred 3-point moving average of each box edge.
  static List<Rect> _smooth(List<Rect> boxes) {
    if (boxes.length < 3) return boxes;
    return [
      for (int i = 0; i < boxes.length; i++)
        () {
          final a = boxes[max(0, i - 1)],
              b = boxes[i],
              c = boxes[min(boxes.length - 1, i + 1)];
          return Rect.fromLTRB(
            (a.left + b.left + c.left) / 3,
            (a.top + b.top + c.top) / 3,
            (a.right + b.right + c.right) / 3,
            (a.bottom + b.bottom + c.bottom) / 3,
          );
        }(),
    ];
  }
}

class _Building {
  final int id;
  final times = <int>[];
  final boxes = <Rect>[];
  final confidences = <double>[];
  final labelWeight = <String, double>{};
  int missed = 0;

  _Building(this.id);

  void add(int ts, Detection d) {
    times.add(ts);
    boxes.add(d.boundingBox);
    confidences.add(d.confidence);
    labelWeight[d.label] = (labelWeight[d.label] ?? 0) + d.confidence;
    missed = 0;
  }

  String get votedLabel =>
      labelWeight.entries.reduce((a, b) => a.value >= b.value ? a : b).key;

  /// Box extrapolated to [ts] from the last two observations.
  Rect predictAt(int ts) {
    final last = boxes.last;
    if (boxes.length < 2) return last;
    final prev = boxes[boxes.length - 2];
    final dt = times.last - times[times.length - 2];
    if (dt <= 0) return last;
    final k = ((ts - times.last) / dt).clamp(0.0, 3.0);
    return last.shift((last.center - prev.center) * k);
  }
}
