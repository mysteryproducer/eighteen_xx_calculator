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
    // "recognizeTextWords" with each word and where it lies in the image,
    // and "recognizeTextLines" with each line and where it lies, both as
    // {text, left, top, right, bottom}, from 0 to 1 across and down.
    let words = call.method == "recognizeTextWords"
    let lines = call.method == "recognizeTextLines"
    guard call.method == "recognizeText" || words || lines else {
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
        let observations = request.results ?? []
        let candidates = observations.compactMap {
          $0.topCandidates(1).first
        }
        let answer: Any
        if words {
          answer = candidates.flatMap(TextRecognitionPlugin.placedWords)
        } else if lines {
          answer = observations.compactMap(TextRecognitionPlugin.placedLine)
        } else {
          answer = candidates.map { $0.string }.joined(separator: "\n")
        }
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
        placed.append(placing(String(text[start..<end]), box))
      }
      start = end
    }
    return placed
  }

  /// The line [observation] read, and where it lies in the image.
  private static func placedLine(_ observation: VNRecognizedTextObservation) -> [String: Any]? {
    guard let candidate = observation.topCandidates(1).first else { return nil }
    return placing(candidate.string, observation.boundingBox)
  }

  /// [text] and its [box], turned from Vision's coordinates (0 to 1 from the
  /// bottom left) to the image's (from the top left).
  private static func placing(_ text: String, _ box: CGRect) -> [String: Any] {
    return [
      "text": text,
      "left": Double(box.minX),
      "top": Double(1 - box.maxY),
      "right": Double(box.maxX),
      "bottom": Double(1 - box.minY),
    ]
  }
}
