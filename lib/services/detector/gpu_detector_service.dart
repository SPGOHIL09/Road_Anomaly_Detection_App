import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

import '../../models/detection.dart';
import '../../utils/nms.dart';
import '../../utils/preprocessing.dart';
import '../../utils/yolo_decoder.dart';
import 'gpu_delegate.dart';

/// Shared GPU inference engine (Android only).
///
/// One long-lived isolate owns the LiteRT GPU interpreter. Compiling the
/// GPU program takes ~14 s on a Pixel 9 and cannot be cached there, so the
/// engine starts in the background at app launch; until [port] is set, the
/// pipelines (photo, video, live) run on the CPU in their own isolates.
///
/// The pipelines stay separate: each keeps its own isolate, decoding and
/// pre/post-processing and only sends letterboxed pixels here.
class GpuDetectorService {
  GpuDetectorService._();

  static const String asset = 'assets/models/best_gpu_fp16.tflite';

  static final ValueNotifier<SendPort?> _port = ValueNotifier(null);
  static Future<void>? _starting;

  /// Send port of the engine once it is ready (null before / if it failed).
  static SendPort? get port => _port.value;

  /// Notifies when the engine becomes ready, so running pipelines can switch.
  static ValueListenable<SendPort?> get portListenable => _port;

  static Future<void> start() => _starting ??= _start();

  static Future<void> _start() async {
    if (!Platform.isAndroid) return;
    try {
      final data = await rootBundle.load(asset);
      final bytes = data.buffer.asUint8List(
        data.offsetInBytes,
        data.lengthInBytes,
      );
      // LiteRT reads the model from a file; keep one copy in the app cache.
      final file = File('${Directory.systemTemp.path}/best_gpu_fp16.tflite');
      if (!file.existsSync() || file.lengthSync() != bytes.length) {
        file.writeAsBytesSync(bytes, flush: true);
      }

      final ready = ReceivePort();
      final sw = Stopwatch()..start();
      await Isolate.spawn(_entry, [ready.sendPort, file.path]);
      final msg = await ready.first;
      if (msg is SendPort) {
        _port.value = msg;
        if (!kReleaseMode) {
          debugPrint('⚡ GPU engine ready in ${sw.elapsedMilliseconds} ms');
        }
      } else {
        debugPrint('⚡ GPU engine unavailable, using CPU: $msg');
      }
    } catch (e) {
      debugPrint('⚡ GPU engine unavailable, using CPU: $e');
    }
  }

  static Future<void> _entry(List<dynamic> args) async {
    final SendPort main = args[0];
    final String path = args[1];
    final Interpreter it;
    try {
      it = Interpreter.fromFile(
        File(path),
        options: InterpreterOptions()
          ..addDelegate(CachedGpuDelegate(fp16: true)),
      )..allocateTensors();
    } catch (e) {
      main.send('$e');
      return;
    }

    const s = kModelInputSize;
    final input = Float32List(s * s * 3);
    final inputBytes = input.buffer.asUint8List();
    final port = ReceivePort();
    main.send(port.sendPort);

    await for (final msg in port) {
      // [packed, newW, newH, xOff, yOff, bgr, reply]
      final SendPort reply = msg[6];
      try {
        final pixels = (msg[0] as TransferableTypedData)
            .materialize()
            .asUint8List();
        _fillNhwc(input, pixels, msg[1], msg[2], msg[3], msg[4], msg[5]);
        it.getInputTensor(0).data = inputBytes;
        it.invoke();
        final out = it.getOutputTensor(0).data;
        final raw = out.buffer.asFloat32List(
          out.offsetInBytes,
          out.lengthInBytes ~/ 4,
        );
        reply.send(nonMaxSupression(decodeYOLO(raw, 0.3), 0.3));
      } catch (e) {
        reply.send('GPU inference failed: $e');
      }
    }
  }

  /// Letterboxed NHWC RGB float input from a packed newW x newH x 3 buffer.
  static void _fillNhwc(
    Float32List t,
    Uint8List px,
    int newW,
    int newH,
    int xOff,
    int yOff,
    bool bgr,
  ) {
    const s = kModelInputSize;
    t.fillRange(0, t.length, kLetterboxPadValue / 255.0);
    final r = bgr ? 2 : 0, b = bgr ? 0 : 2;
    for (int y = 0; y < newH; y++) {
      int src = y * newW * 3;
      int dst = ((y + yOff) * s + xOff) * 3;
      for (int x = 0; x < newW; x++, src += 3, dst += 3) {
        t[dst] = px[src + r] / 255.0;
        t[dst + 1] = px[src + 1] / 255.0;
        t[dst + 2] = px[src + b] / 255.0;
      }
    }
  }
}

/// Requests a detection from the GPU engine. Returns boxes in 640x640
/// model space, or throws if the engine reported an error.
Future<List<Detection>> requestGpuDetection(
  SendPort engine,
  Uint8List packed,
  LetterboxInfo lb, {
  required bool bgr,
}) async {
  final reply = ReceivePort();
  engine.send([
    TransferableTypedData.fromList([packed]),
    lb.newWidth,
    lb.newHeight,
    lb.xOffset,
    lb.yOffset,
    bgr,
    reply.sendPort,
  ]);
  final r = await reply.first;
  reply.close();
  if (r is String) throw StateError(r);
  return List<Detection>.from(r as List);
}
