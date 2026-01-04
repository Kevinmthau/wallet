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
            var hasResumed = false

            let request = VNRecognizeTextRequest { request, error in
                guard !hasResumed else { return }

                if let error = error {
                    AppLogger.scanner.error("OCR failed: \(error.localizedDescription)")
                    hasResumed = true
                    continuation.resume(returning: OCRExtractionResult(texts: []))
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
                    hasResumed = true
                    continuation.resume(returning: OCRExtractionResult(texts: []))
                    return
                }

                let texts = observations.compactMap { observation -> String? in
                    observation.topCandidates(1).first?.string
                }

                AppLogger.scanner.info("OCR extracted \(texts.count) text blocks")

                hasResumed = true
                continuation.resume(returning: OCRExtractionResult(texts: texts))
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
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(returning: OCRExtractionResult(texts: []))
                }
            }

            // Handle timeout - 2 seconds for .accurate recognition level
            DispatchQueue.global().asyncAfter(deadline: .now() + Constants.Scanner.ocrTimeout) {
                if !hasResumed {
                    AppLogger.scanner.warning("OCRExtractor: Text extraction timed out")
                    hasResumed = true
                    continuation.resume(returning: OCRExtractionResult(texts: []))
                }
            }
        }
    }
}
