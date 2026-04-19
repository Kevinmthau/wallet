import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
@preconcurrency import Dispatch
@preconcurrency import Vision

final class CardImageProcessor: @unchecked Sendable {
    static let shared = CardImageProcessor()

    /// Maximum image dimension before resizing
    static let maxStorageDimension: CGFloat = 2048

    // Use shared CIContext from ImageEnhancer (expensive to create, should be reused)
    private let context = ImageProcessingContext.shared
    private let queue = DispatchQueue(
        label: "card.image.processor.queue",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {}

    // MARK: - Storage Preparation

    /// Resizes (if above the storage dimension limit) and compresses an image for
    /// persistent storage. Runs off the main thread.
    func prepareForStorage(_ image: UIImage) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                autoreleasepool {
                    do {
                        let data = try Self.compressForStorage(image)
                        continuation.resume(returning: data)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Synchronous resize + compress for storage. Prefer `prepareForStorage(_:)` from UI code.
    static func compressForStorage(_ image: UIImage) throws -> Data {
        let resized = resizeIfNeeded(image, maxDimension: maxStorageDimension)
        return try compress(resized)
    }

    static func resizeIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else {
            return image
        }

        let scale = size.width > size.height
            ? maxDimension / size.width
            : maxDimension / size.height
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }
        image.draw(in: CGRect(origin: .zero, size: newSize))
        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }

    private static func compress(_ image: UIImage) throws -> Data {
        if let jpegData = image.jpegData(compressionQuality: Constants.jpegCompressionQuality) {
            return jpegData
        }

        if let pngData = image.pngData() {
            AppLogger.data.warning("CardImageProcessor: JPEG compression failed, using PNG fallback")
            return pngData
        }

        throw CardError.imageCompressionFailed
    }

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
    private static func rotateImage(_ image: UIImage, by radians: CGFloat) -> UIImage {
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
            let resumer = ContinuationResumer(continuation)

            queue.asyncAfter(deadline: .now() + Constants.Scanner.textDetectionTimeout) {
                AppLogger.scanner.warning("CardImageProcessor: Text orientation detection timed out")
                resumer.resume(with: image)
            }

            queue.async {
                autoreleasepool {
                    let request = VNRecognizeTextRequest { request, error in
                        if let error {
                            AppLogger.scanner.error("CardImageProcessor: Text recognition error: \(error.localizedDescription)")
                            resumer.resume(with: image)
                            return
                        }

                        guard let observations = request.results as? [VNRecognizedTextObservation],
                              !observations.isEmpty else {
                            resumer.resume(with: image)
                            return
                        }

                        let needsRotation = Self.shouldRotateBasedOnTextOrientation(observations)
                        let result = needsRotation ? Self.rotateImage(image, by: .pi / 2) : image
                        resumer.resume(with: result)
                    }

                    request.recognitionLevel = .fast
                    request.usesLanguageCorrection = false

                    let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
                    do {
                        try handler.perform([request])
                    } catch {
                        AppLogger.scanner.error("CardImageProcessor: Text orientation detection failed: \(error.localizedDescription)")
                        resumer.resume(with: image)
                    }
                }
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
            let resumer = ContinuationResumer(continuation)

            queue.asyncAfter(deadline: .now() + Constants.Scanner.textDetectionTimeout) {
                AppLogger.scanner.warning("CardImageProcessor: Rectangle detection timed out")
                resumer.resume(with: nil)
            }

            queue.async {
                autoreleasepool {
                    let request = VNDetectRectanglesRequest { request, error in
                        if let error {
                            AppLogger.scanner.error("CardImageProcessor: Rectangle detection error: \(error.localizedDescription)")
                            resumer.resume(with: nil)
                            return
                        }
                        let result = (request.results as? [VNRectangleObservation])?.first
                        resumer.resume(with: result)
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
                        resumer.resume(with: nil)
                    }
                }
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
    private static func shouldRotateBasedOnTextOrientation(_ observations: [VNRecognizedTextObservation]) -> Bool {
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
