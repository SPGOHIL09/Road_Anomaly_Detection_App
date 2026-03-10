import 'package:road_anomaly_detector/models/detection.dart';

double iou(Detection a, Detection b){

  final x1 = a.boundingBox.left > b.boundingBox.left ? a.boundingBox.left : b.boundingBox.left;
  final y1 = a.boundingBox.top > b.boundingBox.top ? a.boundingBox.top : b.boundingBox.top;

  final x2 = a.boundingBox.right < b.boundingBox.right ? a.boundingBox.right : b.boundingBox.right;
  final y2 = a.boundingBox.bottom < b.boundingBox.bottom ? a.boundingBox.bottom : b.boundingBox.bottom;

  final interArea = (x2 - x1) * (y2 - y1);
  if(interArea <= 0) return 0;

  final areaA = a.boundingBox.width * a.boundingBox.height;
  final areaB = b.boundingBox.width * b.boundingBox.height;

  return interArea / (areaA + areaB - interArea);
}

List<Detection> nonMaxSupression(List<Detection> detections, double threshold){

  detections.sort((a, b) => b.confidence.compareTo(a.confidence));

  List<Detection> result = [];

  for(var det in detections){
    bool keep = true;
    for(var res in result) {
      if(iou(det, res) > threshold ){
        keep = false;
        break;
      }
    }
    if(keep) result.add(det);
  }

  return result;

}