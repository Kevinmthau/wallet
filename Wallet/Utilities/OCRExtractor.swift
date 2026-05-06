import UIKit
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

final class OCRExtractor: @unchecked Sendable {
    static let shared = OCRExtractor()

    private init() {}

    /// Extract all text from image using Vision framework
    func extractText(from image: UIImage) async -> OCRExtractionResult {
        guard let ciImage = CIImage(image: image) else {
            AppLogger.scanner.warning("OCRExtractor: Failed to create CIImage for text extraction")
            return OCRExtractionResult(texts: [])
        }

        do {
            return try await withImageProcessingTimeout(seconds: Constants.Scanner.ocrTimeout) {
                try await ImageProcessingWorkQueue.shared.run { isCancelled in
                    guard !isCancelled() else {
                        throw CancellationError()
                    }

                    return try self.extractTextSynchronously(from: ciImage, isCancelled: isCancelled)
                }
            }
        } catch is CancellationError {
            return OCRExtractionResult(texts: [])
        } catch ImageProcessingTimeoutError.timedOut {
            AppLogger.scanner.warning("OCRExtractor: Text extraction timed out")
            return OCRExtractionResult(texts: [])
        } catch {
            AppLogger.scanner.error("OCR failed: \(error.localizedDescription)")
            return OCRExtractionResult(texts: [])
        }
    }

    private func extractTextSynchronously(
        from ciImage: CIImage,
        isCancelled: () -> Bool
    ) throws -> OCRExtractionResult {
        try autoreleasepool {
            guard !isCancelled() else {
                throw CancellationError()
            }

            var extractedTexts: [String] = []
            var requestError: Error?

            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    requestError = error
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation] else {
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
            try handler.perform([request])

            guard !isCancelled() else {
                throw CancellationError()
            }

            if let requestError {
                throw requestError
            }

            AppLogger.scanner.info("OCR extracted \(extractedTexts.count) text blocks")
            return OCRExtractionResult(texts: extractedTexts)
        }
    }
}
