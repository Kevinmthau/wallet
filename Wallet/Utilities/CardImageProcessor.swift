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
        defer { UIGraphicsEndImageContext() }  // Ensure context cleanup on all exit paths

        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()

        return normalizedImage ?? image
    }

    /// Rotates image by specified radians (e.g., .pi / 2 for 90 degrees)
    func rotateImage(_ image: UIImage, by radians: CGFloat) -> UIImage {
        let rotatedSize = CGSize(width: image.size.height, height: image.size.width)

        UIGraphicsBeginImageContextWithOptions(rotatedSize, false, image.scale)
        defer { UIGraphicsEndImageContext() }  // Ensure context cleanup on all exit paths

        guard let context = UIGraphicsGetCurrentContext() else { return image }

        context.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
        context.rotate(by: radians)
        context.translateBy(x: -image.size.width / 2, y: -image.size.height / 2)

        image.draw(at: .zero)

        let rotatedImage = UIGraphicsGetImageFromCurrentImageContext()

        return rotatedImage ?? image
    }

    /// Uses text detection to determine if image needs rotation for proper reading orientation (async version)
    func ensureProperOrientationAsync(_ image: UIImage) async -> UIImage {
        guard let ciImage = CIImage(image: image) else {
            AppLogger.scanner.warning("CardImageProcessor: Failed to create CIImage for orientation check")
            return image
        }

        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var hasResumed = false

            /// Thread-safe resume helper to prevent double-resuming continuation
            func safeResume(with result: UIImage) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: result)
            }

            let request = VNRecognizeTextRequest { [weak self] request, error in
                if let error = error {
                    AppLogger.scanner.error("CardImageProcessor: Text recognition error: \(error.localizedDescription)")
                    safeResume(with: image)
                    return
                }

                guard let self,
                      let observations = request.results as? [VNRecognizedTextObservation],
                      !observations.isEmpty else {
                    safeResume(with: image)
                    return
                }

                let needsRotation = self.shouldRotateBasedOnTextOrientation(observations)

                if needsRotation {
                    safeResume(with: self.rotateImage(image, by: .pi / 2))
                } else {
                    safeResume(with: image)
                }
            }

            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                AppLogger.scanner.error("CardImageProcessor: Text orientation detection failed: \(error.localizedDescription)")
                safeResume(with: image)
            }

            // Handle timeout - safeResume is thread-safe and handles duplicate calls
            DispatchQueue.global().asyncAfter(deadline: .now() + Constants.Scanner.textDetectionTimeout) {
                AppLogger.scanner.warning("CardImageProcessor: Text orientation detection timed out")
                safeResume(with: image)
            }
        }
    }

    // MARK: - Rectangle Detection

    /// Detects a rectangle in a still image for accurate perspective correction
    func detectRectangle(in image: UIImage) async -> VNRectangleObservation? {
        guard let cgImage = image.cgImage else {
            AppLogger.scanner.warning("CardImageProcessor: Failed to get CGImage for rectangle detection")
            return nil
        }

        return await withCheckedContinuation { continuation in
            var hasResumed = false
            let lock = NSLock()

            func safeResume(_ result: VNRectangleObservation?) {
                lock.lock()
                defer { lock.unlock() }
                guard !hasResumed else { return }
                hasResumed = true
                continuation.resume(returning: result)
            }

            let request = VNDetectRectanglesRequest { request, error in
                if let error = error {
                    AppLogger.scanner.error("CardImageProcessor: Rectangle detection error: \(error.localizedDescription)")
                    safeResume(nil)
                    return
                }
                let result = (request.results as? [VNRectangleObservation])?.first
                safeResume(result)
            }
            request.minimumAspectRatio = Constants.Scanner.minimumAspectRatio
            request.maximumAspectRatio = Constants.Scanner.maximumAspectRatio
            request.minimumConfidence = Constants.Scanner.minimumConfidence
            request.maximumObservations = 1

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                AppLogger.scanner.error("CardImageProcessor: Rectangle detection failed: \(error.localizedDescription)")
                safeResume(nil)
            }

            // Handle timeout - safeResume is thread-safe and handles duplicate calls
            DispatchQueue.global().asyncAfter(deadline: .now() + Constants.Scanner.textDetectionTimeout) {
                AppLogger.scanner.warning("CardImageProcessor: Rectangle detection timed out")
                safeResume(nil)
            }
        }
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
        // Vision uses bottom-left origin (like CIImage), so Y doesn't need flipping here
        // since we're going from Vision coords to CIImage coords directly
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

        // Convert normalized coordinates to image coordinates
        // Vision uses bottom-left origin (like CIImage), so Y doesn't need flipping here
        // since we're going from Vision coords to CIImage coords directly
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

    /// Analyzes text observations to determine if image needs rotation for proper reading orientation
    private func shouldRotateBasedOnTextOrientation(_ observations: [VNRecognizedTextObservation]) -> Bool {
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
        return verticalTextCount > horizontalTextCount
    }

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
        // Note: This is the synchronous version - callers should use correctPerspectiveAsync
        // for non-blocking orientation correction
        return applyPerspectiveCorrectionOnly(
            ciImage: ciImage,
            topLeft: topLeft,
            topRight: topRight,
            bottomLeft: bottomLeft,
            bottomRight: bottomRight,
            scale: scale,
            orientation: orientation
        )
    }
}
