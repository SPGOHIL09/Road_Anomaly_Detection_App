import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:road_anomaly_detector/models/detection.dart';
import 'package:road_anomaly_detector/services/upload/video_detection_track.dart';

Detection pothole(double l, double t, double r, double b, [double c = 0.8]) =>
    Detection(
        label: 'Pothole', confidence: c, boundingBox: Rect.fromLTRB(l, t, r, b));

void main() {
  late VideoDetectionTrack track;

  setUp(() {
    track = VideoDetectionTrack(sampleIntervalMs: 200);
    // A pothole visible in frames 0..400 ms, moving right; gone from 600 ms.
    track.add(0, [pothole(0.1, 0.5, 0.3, 0.7)]);
    track.add(200, [pothole(0.2, 0.5, 0.4, 0.7)]);
    track.add(400, [pothole(0.3, 0.5, 0.5, 0.7)]);
    track.add(600, []);
    track.add(800, []);
  });

  test('exact sample timestamps return that frame\'s boxes', () {
    expect(track.at(200).single.boundingBox.left, closeTo(0.2, 1e-9));
    expect(track.at(800), isEmpty);
  });

  test('boxes are interpolated between surrounding frames', () {
    final box = track.at(300).single.boundingBox;
    expect(box.left, closeTo(0.25, 1e-9));
    expect(box.right, closeTo(0.45, 1e-9));
  });

  test('box disappears once the defect has left the frame', () {
    // Halfway between last sighting (400) and first empty frame (600).
    expect(track.at(450), isNotEmpty);
    expect(track.at(500), isEmpty);
    expect(track.at(700), isEmpty, reason: 'no stale box on later frames');
  });

  test('nothing is shown beyond the analysed region', () {
    expect(track.analyzedUntilMs, 800);
    expect(track.at(850), isEmpty);
    track.add(1000, [pothole(0.1, 0.1, 0.2, 0.2)]);
    expect(track.at(1050), isNotEmpty, reason: 'within half an interval');
    expect(track.at(1200), isEmpty, reason: 'past analysed region');
  });

  test('a new defect appears from halfway to its first sighting', () {
    final t = VideoDetectionTrack(sampleIntervalMs: 200)
      ..add(0, [])
      ..add(200, [pothole(0.6, 0.6, 0.8, 0.8)]);
    expect(t.at(90), isEmpty);
    expect(t.at(110), isNotEmpty);
  });

  test('holes in the analysis do not stretch old boxes across time', () {
    final t = VideoDetectionTrack(sampleIntervalMs: 200)
      ..add(0, [pothole(0.1, 0.1, 0.2, 0.2)])
      ..add(2000, [pothole(0.1, 0.1, 0.2, 0.2)]);
    expect(t.at(50), isNotEmpty);
    expect(t.at(1000), isEmpty);
  });

  test('out-of-order samples are inserted in time order', () {
    final t = VideoDetectionTrack(sampleIntervalMs: 200)
      ..add(400, [])
      ..add(0, [pothole(0.1, 0.1, 0.2, 0.2)])
      ..add(200, [pothole(0.1, 0.1, 0.2, 0.2)]);
    expect(t.analyzedUntilMs, 400);
    expect(t.at(100), isNotEmpty);
    expect(t.framesWithDefects, 2);
  });
}
