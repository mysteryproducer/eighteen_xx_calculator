import Flutter
import UIKit
import Vision

/// Reads text out of an image with Apple's Vision framework, for the revenue
/// numbers printed beside cities and towns.
///
/// Dart sends PNG bytes under "image" on the channel below and gets back the
/// recognized lines joined by newlines (see lib/processing/revenue_ocr.dart).
/// Vision ships with iOS, so this needs no third-party package, and the Android
/// side answers the same channel using ML Kit.
final class TextRecognitionPlugin: NSObject, FlutterPlugin {
  static let channelName = "eighteen_xx_calculator/text_recognition"

  private let queue = DispatchQueue(label: "text-recognition", qos: .userInitiated)

  static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(
      name: channelName,
      binaryMessenger: registrar.messenger()
    )
    registrar.addMethodCallDelegate(TextRecognitionPlugin(), channel: channel)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard call.method == "recognizeText" else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard
      let arguments = call.arguments as? [String: Any],
      let bytes = arguments["image"] as? FlutterStandardTypedData,
      let image = UIImage(data: bytes.data)?.cgImage
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
        let lines = (request.results ?? []).compactMap {
          $0.topCandidates(1).first?.string
        }
        DispatchQueue.main.async {
          result(lines.joined(separator: "\n"))
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
}
