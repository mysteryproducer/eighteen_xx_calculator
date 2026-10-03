package com.example.eighteen_xx_calculator

import android.graphics.BitmapFactory
import android.graphics.Rect
import com.google.mlkit.vision.common.InputImage
import com.google.mlkit.vision.text.Text
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
        // {text, left, top, right, bottom} from 0 to 1 across and down: a
        // line cut where its words stand far apart (see pieces).
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
                    block.lines.flatMap { line -> pieces(line) }.map { (words, box) ->
                        mapOf(
                            "text" to words,
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

    /**
     * [line] cut wherever a gap between its words is well over a space,
     * each piece with its own box. ML Kit runs things printed in
     * a row into one line -- a charter's token costs, "0 Fr. 40 Fr. 100 Fr.",
     * or a logo's letters and the name beside it -- where Apple's Vision
     * keeps them apart, and the reader needs each where it lies.
     */
    private fun pieces(line: Text.Line): List<Pair<String, Rect>> {
        val words = line.elements.filter { it.boundingBox != null }
        val box = line.boundingBox
        if (words.size < 2) {
            return if (box == null) emptyList() else listOf(line.text to box)
        }
        val pieces = mutableListOf<Pair<String, Rect>>()
        var text = StringBuilder(words[0].text)
        var bounds = Rect(words[0].boundingBox!!)
        for (i in 1 until words.size) {
            val word = words[i]
            val wordBox = word.boundingBox!!
            val gap = wordBox.left - bounds.right
            val tall = maxOf(bounds.height(), wordBox.height())
            // A space between words is a third of their height or so.
            if (gap > 0.6 * tall) {
                pieces.add(text.toString() to bounds)
                text = StringBuilder(word.text)
                bounds = Rect(wordBox)
            } else {
                text.append(' ').append(word.text)
                bounds.union(wordBox)
            }
        }
        pieces.add(text.toString() to bounds)
        return pieces
    }

    fun dispose() {
        channel.setMethodCallHandler(null)
        recognizer.close()
    }

    companion object {
        const val NAME = "eighteen_xx_calculator/text_recognition"
    }
}
