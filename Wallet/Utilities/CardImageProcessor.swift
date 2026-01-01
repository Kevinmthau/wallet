import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
@preconcurrency import Vision

class CardImageProcessor {
    static let shared = CardImageProcessor()

    // Use shared CIContext from ImageEnhancer (expensive to create, should be reused)
    private let context = ImageProcessingContext.shared

    private init() {}

    // MARK: - Orientation Correction

    /// Normalizes image orientation by redrawing if not already .up
    func fixImageOrientation(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up {
            return image
        }

        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return normalizedImage ?? image
    }

    /// Rotates image by specified radians (e.g., .pi / 2 for 90 degrees)
    func rotateImage(_ image: UIImage, by radians: CGFloat) -> UIImage {
        let rotatedSize = CGSize(width: image.size.height, height: image.size.width)

        UIGraphicsBeginImageContextWithOptions(rotatedSize, false, image.scale)
        guard let context = UIGraphicsGetCurrentContext() else { return image }

        context.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
        context.rotate(by: radians)
        context.translateBy(x: -image.size.width / 2, y: -image.size.height / 2)

        image.draw(at: .zero)

        let rotatedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return rotatedImage ?? image
    }

    /// Uses text detection to determine if image needs rotation for proper reading orientation (async version)
    func ensureProperOrientationAsync(_ image: UIImage) async -> UIImage {
        guard let ciImage = CIImage(image: image) else {
            AppLogger.scanner.warning("CardImageProcessor: Failed to create CIImage for orientation check")
            return image
        }

        return await withCheckedContinuation { continuation in
            var needsRotation = false
            var hasResumed = false

            let request = VNRecognizeTextRequest { request, error in
                guard !hasResumed else { return }

                if let error = error {
                    AppLogger.scanner.error("CardImageProcessor: Text recognition error: \(error.localizedDescription)")
                    hasResumed = true
                    continuation.resume(returning: image)
                    return
                }

                guard let observations = request.results as? [VNRecognizedTextObservation],
                      !observations.isEmpty else {
                    hasResumed = true
                    continuation.resume(returning: image)
                    return
                }

                // Analyze text bounding boxes to determine if text is sideways
                var horizontalTextCount = 0
                var verticalTextCount = 0

                for observation in observations.prefix(Constants.Scanner.maxTextBlocksForOrientation) {
                    let box = observation.boundingBox
                    if box.width > box.height {
                        horizontalTextCount += 1
                    } else {
                        verticalTextCount += 1
                    }
                }

                needsRotation = verticalTextCount > horizontalTextCount
                hasResumed = true

                if needsRotation {
                    continuation.resume(returning: self.rotateImage(image, by: .pi / 2))
                } else {
                    continuation.resume(returning: image)
                }
            }

            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                AppLogger.scanner.error("CardImageProcessor: Text orientation detection failed: \(error.localizedDescription)")
                if !hasResumed {
                    hasResumed = true
                    continuation.resume(returning: image)
                }
            }

            // Handle timeout
            DispatchQueue.global().asyncAfter(deadline: .now() + Constants.Scanner.textDetectionTimeout) {
                if !hasResumed {
                    AppLogger.scanner.warning("CardImageProcessor: Text orientation detection timed out")
                    hasResumed = true
                    continuation.resume(returning: image)
                }
            }
        }
    }

    /// Uses text detection to determine if image needs rotation for proper reading orientation (sync version - may block)
    func ensureProperOrientation(_ image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else {
            AppLogger.scanner.warning("CardImageProcessor: Failed to create CIImage for orientation check")
            return image
        }

        var needsRotation = false
        let semaphore = DispatchSemaphore(value: 0)

        let request = VNRecognizeTextRequest { request, error in
            defer { semaphore.signal() }

            if let error = error {
                AppLogger.scanner.error("CardImageProcessor: Text recognition error: \(error.localizedDescription)")
                return
            }

            guard let observations = request.results as? [VNRecognizedTextObservation],
                  !observations.isEmpty else { return }

            // Analyze text bounding boxes to determine if text is sideways
            var horizontalTextCount = 0
            var verticalTextCount = 0

            for observation in observations.prefix(Constants.Scanner.maxTextBlocksForOrientation) {
                let box = observation.boundingBox
                // Text blocks are wider than tall when readable horizontally
                if box.width > box.height {
                    horizontalTextCount += 1
                } else {
                    verticalTextCount += 1
                }
            }

            // If most text appears vertical (sideways), we need to rotate
            needsRotation = verticalTextCount > horizontalTextCount
        }

        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            AppLogger.scanner.error("CardImageProcessor: Text orientation detection failed: \(error.localizedDescription)")
        }

        // Wait briefly for detection (with timeout)
        let waitResult = semaphore.wait(timeout: .now() + Constants.Scanner.textDetectionTimeout)
        if waitResult == .timedOut {
            AppLogger.scanner.warning("CardImageProcessor: Text orientation detection timed out")
        }

        // Only rotate if text detection says text is sideways
        if needsRotation {
            return rotateImage(image, by: .pi / 2)
        }

        // Keep original orientation - respect portrait cards
        return image
    }

    // MARK: - Perspective Correction

    /// Corrects perspective using VNRectangleObservation from Vision framework
    func correctPerspective(image: UIImage, observation: VNRectangleObservation) -> UIImage? {
        guard let ciImage = CIImage(image: image) else {
            AppLogger.scanner.warning("CardImageProcessor: Failed to create CIImage for perspective correction")
            return nil
        }

        let imageSize = ciImage.extent.size

        // Convert normalized coordinates to image coordinates
        let topLeft = CGPoint(
            x: observation.topLeft.x * imageSize.width,
            y: observation.topLeft.y * imageSize.height
        )
        let topRight = CGPoint(
            x: observation.topRight.x * imageSize.width,
            y: observation.topRight.y * imageSize.height
        )
        let bottomLeft = CGPoint(
            x: observation.bottomLeft.x * imageSize.width,
            y: observation.bottomLeft.y * imageSize.height
        )
        let bottomRight = CGPoint(
            x: observation.bottomRight.x * imageSize.width,
            y: observation.bottomRight.y * imageSize.height
        )

        return applyPerspectiveCorrection(
            ciImage: ciImage,
            topLeft: topLeft,
            topRight: topRight,
            bottomLeft: bottomLeft,
            bottomRight: bottomRight,
            scale: image.scale
        )
    }

    /// Corrects perspective using explicit corner points
    func correctPerspective(_ image: UIImage, topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint) -> UIImage? {
        guard let ciImage = CIImage(image: image) else {
            AppLogger.scanner.warning("CardImageProcessor: Failed to create CIImage for perspective correction")
            return nil
        }

        return applyPerspectiveCorrection(
            ciImage: ciImage,
            topLeft: topLeft,
            topRight: topRight,
            bottomLeft: bottomLeft,
            bottomRight: bottomRight,
            scale: image.scale,
            orientation: image.imageOrientation
        )
    }

    /// Async perspective correction using VNRectangleObservation - does not block
    func correctPerspectiveAsync(image: UIImage, observation: VNRectangleObservation) async -> UIImage? {
        guard let ciImage = CIImage(image: image) else {
            AppLogger.scanner.warning("CardImageProcessor: Failed to create CIImage for perspective correction")
            return nil
        }

        let imageSize = ciImage.extent.size

        let topLeft = CGPoint(
            x: observation.topLeft.x * imageSize.width,
            y: observation.topLeft.y * imageSize.height
        )
        let topRight = CGPoint(
            x: observation.topRight.x * imageSize.width,
            y: observation.topRight.y * imageSize.height
        )
        let bottomLeft = CGPoint(
            x: observation.bottomLeft.x * imageSize.width,
            y: observation.bottomLeft.y * imageSize.height
        )
        let bottomRight = CGPoint(
            x: observation.bottomRight.x * imageSize.width,
            y: observation.bottomRight.y * imageSize.height
        )

        // Apply perspective correction (fast, synchronous operation)
        guard let correctedImage = applyPerspectiveCorrectionOnly(
            ciImage: ciImage,
            topLeft: topLeft,
            topRight: topRight,
            bottomLeft: bottomLeft,
            bottomRight: bottomRight,
            scale: image.scale
        ) else {
            return nil
        }

        // Now do async orientation check (non-blocking)
        return await ensureProperOrientationAsync(correctedImage)
    }

    // MARK: - Private Helpers

    /// Applies only perspective correction without orientation check
    private func applyPerspectiveCorrectionOnly(
        ciImage: CIImage,
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomLeft: CGPoint,
        bottomRight: CGPoint,
        scale: CGFloat,
        orientation: UIImage.Orientation = .up
    ) -> UIImage? {
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ciImage
        filter.topLeft = topLeft
        filter.topRight = topRight
        filter.bottomLeft = bottomLeft
        filter.bottomRight = bottomRight

        guard let output = filter.outputImage else {
            AppLogger.scanner.warning("CardImageProcessor: Perspective correction filter produced no output")
            return nil
        }

        guard let cgImage = context.createCGImage(output, from: output.extent) else {
            AppLogger.scanner.warning("CardImageProcessor: Failed to create CGImage from perspective correction")
            return nil
        }

        return UIImage(cgImage: cgImage, scale: scale, orientation: orientation)
    }

    private func applyPerspectiveCorrection(
        ciImage: CIImage,
        topLeft: CGPoint,
        topRight: CGPoint,
        bottomLeft: CGPoint,
        bottomRight: CGPoint,
        scale: CGFloat,
        orientation: UIImage.Orientation = .up
    ) -> UIImage? {
        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ciImage
        filter.topLeft = topLeft
        filter.topRight = topRight
        filter.bottomLeft = bottomLeft
        filter.bottomRight = bottomRight

        guard let output = filter.outputImage else {
            AppLogger.scanner.warning("CardImageProcessor: Perspective correction filter produced no output")
            return nil
        }

        guard let cgImage = context.createCGImage(output, from: output.extent) else {
            AppLogger.scanner.warning("CardImageProcessor: Failed to create CGImage from perspective correction")
            return nil
        }

        let correctedImage = UIImage(cgImage: cgImage, scale: scale, orientation: orientation)

        // For VNRectangleObservation-based correction, also check orientation
        if orientation == .up {
            return ensureProperOrientation(correctedImage)
        }

        return correctedImage
    }
}
