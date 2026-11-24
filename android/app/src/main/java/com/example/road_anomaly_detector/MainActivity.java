package com.example.road_anomaly_detector;

import androidx.annotation.NonNull;

import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;

public class MainActivity extends FlutterActivity {
    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine flutterEngine) {
        super.configureFlutterEngine(flutterEngine);
        HwVideoDecoderChannel.register(flutterEngine.getDartExecutor().getBinaryMessenger());
    }
}
