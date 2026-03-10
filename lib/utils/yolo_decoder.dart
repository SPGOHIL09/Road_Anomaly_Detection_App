import 'dart:ui';
import 'package:road_anomaly_detector/models/detection.dart';

const List<String> labels = [
  'Longitudinal Crack',
  'Transverse Crack',
  'Alligator Crack',
  'Block Crack',
  'Pothole',
  'Manhole cover',
  'Other corruption'
];

List<Detection> decodeYOLO(List<double> output, double confidenceThreshold) {

  const int numClasses = 7;
  const int numPred = 8400;

  List<Detection> detections = [];

  for (int i = 0; i < numPred; i++) {

    double x = output[i];
    double y = output[i + numPred];
    double w = output[i + 2 * numPred];
    double h = output[i + 3 * numPred];

    int bestClass = -1;
    double bestScore = 0;

    for (int c = 0; c < numClasses; c++) {

      double score = output[i + (4 + c) * numPred];

      if (score > bestScore) {
        bestScore = score;
        bestClass = c;
      }
    }

    if (bestScore < confidenceThreshold) continue;

    Rect box = Rect.fromLTWH(
      x - w / 2,
      y - h / 2,
      w,
      h,
    );

    detections.add(
      Detection(
        label: labels[bestClass],
        confidence: bestScore,
        boundingBox: box,
      ),
    );
  }

  return detections;
}