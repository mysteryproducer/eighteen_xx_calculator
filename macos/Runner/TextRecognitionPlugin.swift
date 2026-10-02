import Cocoa
import FlutterMacOS
import Vision

/// Reads text out of an image with Apple's Vision framework: the revenue
/// numbers printed beside cities and towns, and the figures on 1844's
/// mountain railway plates.
///
/// The same channel as on iOS (`ios/Runner/TextRecognitionPlugin.swift`):
/// Dart sends PNG bytes under "image" and gets back the recognized lines
/// joined by newlines (see lib/processing/revenue_ocr.dart). Vision ships with
/// macOS, so this needs no third-party package.
final class TextRecognitionPlugin: NSObject, FlutterPlugin {
  static let channelName = "eighteen_xx_calculator/text_recognition"

  private let queue = DispatchQueue(label: "text-recognition", qos: .userInitiated)

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger
    )
    registrar.addMethodCallDelegate(TextRecognitionPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    // "recognizeText" answers with the lines read, joined by newlines;
    // "recognizeTextWords" with each word and where it lies across the
    // image, as {text, left, right}, left and right from 0 to 1.
    let words = call.method == "recognizeTextWords"
    guard call.method == "recognizeText" || words else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let bytes = arguments["image"] as? FlutterStandardTypedData,
      let source = CGImageSourceCreateWithData(bytes.data as CFData, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      result(FlutterError(
        code: "bad_image",
        message: "Expected PNG bytes under \"image\".",
        details: nil
      ))
      return
    }

    // Vision's recognition is synchronous and can take a moment, so keep it
    // off the main thread and reply there.
    queue.async {
      let request = VNRecognizeTextRequest()
      request.recognitionLevel = .accurate
      // Revenue values are bare numbers; language correction only gets in
      // the way of reading them.
      request.usesLanguageCorrection = false

      do {
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let candidates = (request.results ?? []).compactMap {
          $0.topCandidates(1).first
        }
        let answer: Any = words
          ? candidates.flatMap(TextRecognitionPlugin.placedWords)
          : candidates.map { $0.string }.joined(separator: "\n")
        DispatchQueue.main.async {
          result(answer)
        }
      } catch {
        DispatchQueue.main.async {
          result(FlutterError(
            code: "recognition_failed",
            message: error.localizedDescription,
            details: nil
          ))
        }
      }
    }
  }

  /// Each word of [candidate] -- a run without spaces -- and where it lies
  /// across the image. Vision places whole words, not single characters.
  private static func placedWords(_ candidate: VNRecognizedText) -> [[String: Any]] {
    let text = candidate.string
    var placed: [[String: Any]] = []
    var start = text.startIndex
    while start < text.endIndex {
      if text[start].isWhitespace {
        start = text.index(after: start)
        continue
      }
      var end = start
      while end < text.endIndex && !text[end].isWhitespace {
        end = text.index(after: end)
      }
      if let box = try? candidate.boundingBox(for: start..<end)?.boundingBox {
        placed.append([
          "text": String(text[start..<end]),
          "left": Double(box.minX),
          "right": Double(box.maxX),
        ])
      }
      start = end
    }
    return placed
  }
}
