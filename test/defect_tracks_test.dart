import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:road_anomaly_detector/models/detection.dart';
import 'package:road_anomaly_detector/services/upload/defect_tracks.dart';

Detection d(String label, double l, double t, double w, double h, [double c = 0.8]) =>
    Detection(label: label, confidence: c, boundingBox: Rect.fromLTWH(l, t, w, h));

void main() {
  test('a defect moving down the frame becomes one track with one box', () {
    // Pothole slides down 0.06 per 100 ms (vehicle moving forward).
    final samples = [
      for (int i = 0; i < 10; i++) (i * 100, [d('Pothole', 0.4, 0.1 + 0.06 * i, 0.2, 0.1)]),
    ];
    final tracks = DefectTracks.build(samples);
    expect(tracks.count, 1);
    expect(tracks.at(450), hasLength(1));
    expect(tracks.at(450).single.boundingBox.top, closeTo(0.1 + 0.06 * 4.5, 0.01));
  });

  test('label flicker is voted into one stable label', () {
    final samples = [
      for (int i = 0; i < 8; i++)
        (i * 100, [d(i == 3 || i == 6 ? 'Transverse Crack' : 'Longitudinal Crack', 0.3, 0.3, 0.1, 0.4)]),
    ];
    final tracks = DefectTracks.build(samples);
    expect(tracks.count, 1);
    for (int t = 0; t <= 700; t += 50) {
      expect(tracks.at(t).single.label, 'Longitudinal Crack');
    }
  });

  test('missed frames are bridged instead of blinking', () {
    final samples = <(int, List<Detection>)>[
      for (int i = 0; i < 10; i++) (i * 100, i == 4 || i == 5 ? <Detection>[] : [d('Pothole', 0.5, 0.5, 0.1, 0.1)]),
    ];
    final tracks = DefectTracks.build(samples);
    expect(tracks.count, 1);
    expect(tracks.at(450), hasLength(1), reason: 'gap of two scans bridged');
  });

  test('one-off low-confidence detections are dropped', () {
    final samples = <(int, List<Detection>)>[
      (0, [d('Pothole', 0.1, 0.1, 0.1, 0.1, 0.4)]),
      for (int i = 1; i < 10; i++) (i * 100, <Detection>[]),
    ];
    expect(DefectTracks.build(samples).count, 0);
  });

  test('box disappears after the defect leaves the frame', () {
    final samples = <(int, List<Detection>)>[
      for (int i = 0; i < 5; i++) (i * 100, [d('Pothole', 0.5, 0.5, 0.1, 0.1)]),
      for (int i = 5; i < 15; i++) (i * 100, <Detection>[]),
    ];
    final tracks = DefectTracks.build(samples);
    expect(tracks.at(400), hasLength(1));
    expect(tracks.at(600), isEmpty);
    expect(tracks.at(1200), isEmpty);
  });

  test('two separate defects stay two tracks', () {
    final samples = [
      for (int i = 0; i < 6; i++)
        (i * 100, [d('Pothole', 0.1, 0.5, 0.1, 0.1), d('Alligator Crack', 0.7, 0.5, 0.2, 0.2)]),
    ];
    final tracks = DefectTracks.build(samples);
    expect(tracks.count, 2);
    expect(tracks.at(250).map((x) => x.label).toSet(), {'Pothole', 'Alligator Crack'});
  });

  test('confidence shown is stable for the whole track', () {
    final samples = [
      for (int i = 0; i < 6; i++) (i * 100, [d('Pothole', 0.4, 0.4, 0.1, 0.1, 0.5 + i * 0.05)]),
    ];
    final tracks = DefectTracks.build(samples);
    final c = {for (int t = 0; t <= 500; t += 100) tracks.at(t).single.confidence};
    expect(c, hasLength(1));
  });
}
