package com.example.eighteen_xx_calculator

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var textRecognition: TextRecognitionChannel? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        textRecognition = TextRecognitionChannel(flutterEngine.dartExecutor.binaryMessenger)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        textRecognition?.dispose()
        textRecognition = null
        super.cleanUpFlutterEngine(flutterEngine)
    }
}
