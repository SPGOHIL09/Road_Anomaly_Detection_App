package com.example.road_anomaly_detector;

import android.os.Handler;
import android.os.Looper;

import androidx.annotation.NonNull;

import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;

import io.flutter.plugin.common.BinaryMessenger;
import io.flutter.plugin.common.MethodCall;
import io.flutter.plugin.common.MethodChannel;

/**
 * Method channel for {@link HwVideoDecoder}: "open", "next" and "close". Work runs on each decoder's own thread; replies
 * are posted back to the platform thread.
 */
final class HwVideoDecoderChannel implements MethodChannel.MethodCallHandler {
    static final String NAME = "road_anomaly_detector/hw_video_decoder";

    private final Map<Integer, HwVideoDecoder> decoders = new ConcurrentHashMap<>();
    private final AtomicInteger nextId = new AtomicInteger(1);
    private final Handler main = new Handler(Looper.getMainLooper());

    static void register(BinaryMessenger messenger) {
        new MethodChannel(messenger, NAME).setMethodCallHandler(new HwVideoDecoderChannel());
    }

    @Override
    public void onMethodCall(@NonNull MethodCall call, @NonNull MethodChannel.Result result) {
        switch (call.method) {
            case "open": {
                String path = call.argument("path");
                Boolean expectPortrait = call.argument("expectPortrait");
                HwVideoDecoder dec = new HwVideoDecoder();
                Boolean yuv = call.argument("yuv");
                if (yuv != null) dec.preferYuv = yuv;
                int id = nextId.getAndIncrement();
                dec.run(() -> {
                    dec.open(path, expectPortrait);
                    return describe(id, dec);
                }, (value, error) -> {
                    if (error == null) {
                        decoders.put(id, dec);
                    } else {
                        dec.shutdown();
                    }
                    reply(result, value, error);
                });
                break;
            }
            case "next": {
                HwVideoDecoder dec = decoders.get(intArg(call, "id"));
                if (dec == null) {
                    result.error("closed", "Decoder is closed", null);
                    return;
                }
                long minRelUs = longArg(call, "minRelUs");
                int outW = intArg(call, "outW");
                int outH = intArg(call, "outH");
                dec.run(() -> {
                    HwVideoDecoder.Frame f = dec.next(minRelUs, outW, outH);
                    if (f == null) return null;
                    Map<String, Object> m = new HashMap<>();
                    m.put("relUs", f.relUs);
                    m.put("index", f.index);
                    m.put("rgb", f.rgb);
                    return m;
                }, (value, error) -> reply(result, value, error));
                break;
            }
            case "close": {
                HwVideoDecoder dec = decoders.remove(intArg(call, "id"));
                if (dec != null) dec.shutdown();
                result.success(null);
                break;
            }
            default:
                result.notImplemented();
        }
    }

    private static Map<String, Object> describe(int id, HwVideoDecoder dec) {
        Map<String, Object> m = new HashMap<>();
        m.put("id", id);
        m.put("codec", dec.codecName);
        m.put("width", dec.uprightWidth());
        m.put("height", dec.uprightHeight());
        m.put("meta", dec.meta);
        m.put("rotation", dec.rotation);
        m.put("durationUs", dec.durationUs);
        m.put("frameRate", (double) dec.frameRate);
        m.put("yuv601", dec.yuv601);
        return m;
    }

    private void reply(MethodChannel.Result result, Object value, Exception error) {
        main.post(() -> {
            if (error == null) {
                result.success(value);
            } else {
                result.error("hw_decode", String.valueOf(error), null);
            }
        });
    }

    private static int intArg(MethodCall call, String key) {
        Number n = call.argument(key);
        return n == null ? 0 : n.intValue();
    }

    private static long longArg(MethodCall call, String key) {
        Number n = call.argument(key);
        return n == null ? 0 : n.longValue();
    }
}
