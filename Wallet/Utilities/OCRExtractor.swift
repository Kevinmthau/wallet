import UIKit
import Vision

/// Result from OCR extraction
struct OCRExtractionResult {
    let texts: [String]

    var formattedNotes: String {
        texts.joined(separator: "\n")
    }

    var isEmpty: Bool {
        texts.isEmpty
    }
}

class OCRExtractor {
    static let shared = OCRExtractor()

    private init() {}

    /// Extract all text from image using Vision framework
    func extractText(from image: UIImage) async -> OCRExtractionResult {
        guard let ciImage = CIImage(image: image) else {
            AppLogger.scanner.warning("OCRExtractor: Failed to create CIImage for text extraction")
            return OCRExtractionResult(texts: [])
        }

        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var hasResumed = false

            /// Thread-safe resume helper to prevent double-resuming continuation
            func safeResume(with result: OCRExtractionResult) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: result)
            }

            let request = VNRecognizeTextRequest { request, error in
                if let error = error {
                    AppLogger.scanner.error("OCR failed: \(error.localizedDescription)")
                    safeResume(with: OCRExtractionResult(texts: []))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    safeResume(with: OCRExtractionResult(texts: []))
                    return
                }

                let texts = observations.compactMap { observation -> String? in
                    observation.topCandidates(1).first?.string
                }

                AppLogger.scanner.info("OCR extracted \(texts.count) text blocks")
                safeResume(with: OCRExtractionResult(texts: texts))
            }

            // Use .accurate for better recognition
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]

            let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                AppLogger.scanner.error("OCR failed: \(error.localizedDescription)")
                safeResume(with: OCRExtractionResult(texts: []))
            }

            // Handle timeout - safeResume is thread-safe and handles duplicate calls
            DispatchQueue.global().asyncAfter(deadline: .now() + Constants.Scanner.ocrTimeout) {
                AppLogger.scanner.warning("OCRExtractor: Text extraction timed out")
                safeResume(with: OCRExtractionResult(texts: []))
            }
        }
    }
}
