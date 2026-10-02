package com.example.eighteen_xx_calculator

import android.graphics.BitmapFactory
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.TextRecognition
import com.google.mlkit.vision.text.latin.TextRecognizerOptions
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Reads text out of an image with ML Kit's on-device recognizer, for the
 * revenue numbers printed beside cities and towns.
 *
 * Dart sends PNG bytes under "image" and gets back the recognized text, one
 * line per line of print (see lib/processing/revenue_ocr.dart). The iOS side
 * answers the same channel using Apple's Vision framework.
 */
class TextRecognitionChannel(messenger: BinaryMessenger) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, NAME)
    private val recognizer = TextRecognition.getClient(TextRecognizerOptions.DEFAULT_OPTIONS)

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        // "recognizeTextLines" answers with each line and where it lies, as
        // {text, left, top, right, bottom} from 0 to 1 across and down.
        val lines = call.method == "recognizeTextLines"
        if (call.method != "recognizeText" && !lines) {
            result.notImplemented()
            return
        }
        val bytes = call.argument<ByteArray>("image")
        val bitmap = bytes?.let { BitmapFactory.decodeByteArray(it, 0, it.size) }
        if (bitmap == null) {
            result.error("bad_image", "Expected PNG bytes under \"image\".", null)
            return
        }
        val width = bitmap.width.toDouble()
        val height = bitmap.height.toDouble()
        recognizer.process(InputImage.fromBitmap(bitmap, 0))
            .addOnSuccessListener { text ->
                if (!lines) {
                    result.success(text.text)
                    return@addOnSuccessListener
                }
                result.success(text.textBlocks.flatMap { block ->
                    block.lines.mapNotNull { line ->
                        val box = line.boundingBox ?: return@mapNotNull null
                        mapOf(
                            "text" to line.text,
                            "left" to box.left / width,
                            "top" to box.top / height,
                            "right" to box.right / width,
                            "bottom" to box.bottom / height,
                        )
                    }
                })
            }
            .addOnFailureListener { error ->
                result.error("recognition_failed", error.message, null)
            }
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        recognizer.close()
    }

    companion object {
        const val NAME = "eighteen_xx_calculator/text_recognition"
    }
}
