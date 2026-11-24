import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:tflite_flutter/tflite_flutter.dart';
// TfLiteDelegate is not exported by the package's public library.
// ignore: implementation_imports
import 'package:tflite_flutter/src/bindings/tensorflow_lite_bindings_generated.dart'
    show TfLiteDelegate;

/// LiteRT 1.4 `TfLiteGpuDelegateOptionsV2` (tensorflow/lite/delegates/gpu/
/// delegate_options.h). tflite_flutter 0.12.1's own binding stops after
/// `max_delegated_partitions`, so the native side reads uninitialised memory
/// for the remaining fields, and kernel caching cannot be configured.
final class _GpuOptions extends Struct {
  @Int32()
  external int isPrecisionLossAllowed;
  @Int32()
  external int inferencePreference;
  @Int32()
  external int inferencePriority1;
  @Int32()
  external int inferencePriority2;
  @Int32()
  external int inferencePriority3;
  @Int64()
  external int experimentalFlags;
  @Int32()
  external int maxDelegatedPartitions;
  external Pointer<Utf8> serializationDir;
  external Pointer<Utf8> modelToken;

  /// Headroom for fields added by newer LiteRT versions; zero = default.
  @Array(32)
  external Array<Uint64> reserved;
}

typedef _DefaultNative = _GpuOptions Function();
typedef _CreateNative = Pointer<TfLiteDelegate> Function(Pointer<_GpuOptions>);
typedef _DeleteNative = Void Function(Pointer<TfLiteDelegate>);
typedef _DeleteDart = void Function(Pointer<TfLiteDelegate>);

final DynamicLibrary _lib = DynamicLibrary.open('libtensorflowlite_gpu_jni.so');
final _defaults = _lib.lookupFunction<_DefaultNative, _DefaultNative>(
  'TfLiteGpuDelegateOptionsV2Default',
);
final _create = _lib.lookupFunction<_CreateNative, _CreateNative>(
  'TfLiteGpuDelegateV2Create',
);
final _delete = _lib.lookupFunction<_DeleteNative, _DeleteDart>(
  'TfLiteGpuDelegateV2Delete',
);

/// LiteRT GPU delegate with a correctly laid out options struct and
/// on-disk kernel caching ([cacheDir] + [modelToken]): the first start
/// compiles GPU kernels (10-50 s on a Pixel 9), later starts reuse them.
class CachedGpuDelegate implements Delegate {
  final Pointer<TfLiteDelegate> _delegate;
  final Pointer<Utf8> _dir;
  final Pointer<Utf8> _token;
  bool _deleted = false;

  CachedGpuDelegate._(this._delegate, this._dir, this._token);

  /// Returns the library defaults read through this struct definition, so
  /// callers can verify the layout matches the native one.
  static Map<String, int> nativeDefaults() {
    final d = _defaults();
    return {
      'isPrecisionLossAllowed': d.isPrecisionLossAllowed,
      'inferencePreference': d.inferencePreference,
      'inferencePriority1': d.inferencePriority1,
      'inferencePriority2': d.inferencePriority2,
      'inferencePriority3': d.inferencePriority3,
      'experimentalFlags': d.experimentalFlags,
      'maxDelegatedPartitions': d.maxDelegatedPartitions,
      'serializationDir': d.serializationDir.address,
      'modelToken': d.modelToken.address,
    };
  }

  factory CachedGpuDelegate({
    String? cacheDir,
    String? modelToken,
    bool fp16 = true,
  }) {
    final opts = calloc<_GpuOptions>();
    opts.ref = _defaults();
    opts.ref
      ..isPrecisionLossAllowed = fp16 ? 1 : 0
      ..inferencePreference = 1 // SUSTAINED_SPEED
      ..inferencePriority1 = fp16 ? 2 : 1 // MIN_LATENCY : MAX_PRECISION
      ..inferencePriority2 = 0 // AUTO
      ..inferencePriority3 = 0; // AUTO
    Pointer<Utf8> dir = nullptr, token = nullptr;
    if (cacheDir != null && modelToken != null) {
      dir = cacheDir.toNativeUtf8();
      token = modelToken.toNativeUtf8();
      opts.ref
        ..serializationDir = dir
        ..modelToken = token;
    }
    final delegate = _create(opts);
    calloc.free(opts);
    if (delegate == nullptr) {
      if (dir != nullptr) malloc.free(dir);
      if (token != nullptr) malloc.free(token);
      throw StateError('GPU delegate could not be created');
    }
    // Strings stay alive as long as the delegate, in case it keeps pointers.
    return CachedGpuDelegate._(delegate, dir, token);
  }

  @override
  Pointer<TfLiteDelegate> get base => _delegate;

  @override
  void delete() {
    if (_deleted) return;
    _delete(_delegate);
    if (_dir != nullptr) malloc.free(_dir);
    if (_token != nullptr) malloc.free(_token);
    _deleted = true;
  }
}
