import UIKit
@preconcurrency import Dispatch
@preconcurrency import Vision

/// Result from OCR extraction
struct OCRExtractionResult: Sendable {
    let texts: [String]

    var formattedNotes: String {
        texts.joined(separator: "\n")
    }

    var isEmpty: Bool {
        texts.isEmpty
    }
}

private final class OCRContinuationResumer<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    func resume(with value: Value) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(returning: value)
    }
}

final class OCRExtractor: @unchecked Sendable {
    static let shared = OCRExtractor()

    private let queue = DispatchQueue(
        label: "ocr.extractor.queue",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {}

    /// Extract all text from image using Vision framework
    func extractText(from image: UIImage) async -> OCRExtractionResult {
        guard let ciImage = CIImage(image: image) else {
            AppLogger.scanner.warning("OCRExtractor: Failed to create CIImage for text extraction")
            return OCRExtractionResult(texts: [])
        }

        return await withCheckedContinuation { continuation in
            let resumer = OCRContinuationResumer(continuation)

            queue.asyncAfter(deadline: .now() + Constants.Scanner.ocrTimeout) {
                AppLogger.scanner.warning("OCRExtractor: Text extraction timed out")
                resumer.resume(with: OCRExtractionResult(texts: []))
            }

            queue.async {
                autoreleasepool {
                    var extractedTexts: [String] = []

                    let request = VNRecognizeTextRequest { request, error in
                        if let error {
                            AppLogger.scanner.error("OCR failed: \(error.localizedDescription)")
                            resumer.resume(with: OCRExtractionResult(texts: []))
                            return
                        }

                        guard let observations = request.results as? [VNRecognizedTextObservation] else {
                            resumer.resume(with: OCRExtractionResult(texts: []))
                            return
                        }

                        extractedTexts = observations.compactMap { observation in
                            observation.topCandidates(1).first?.string
                        }
                    }

                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = false
                    request.recognitionLanguages = ["en-US"]

                    let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
                    do {
                        try handler.perform([request])
                        AppLogger.scanner.info("OCR extracted \(extractedTexts.count) text blocks")
                        resumer.resume(with: OCRExtractionResult(texts: extractedTexts))
                    } catch {
                        AppLogger.scanner.error("OCR failed: \(error.localizedDescription)")
                        resumer.resume(with: OCRExtractionResult(texts: []))
                    }
                }
            }
        }
    }
}
