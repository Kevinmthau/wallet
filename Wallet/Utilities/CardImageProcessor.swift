import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
@preconcurrency import Vision

final class CardImageProcessor: @unchecked Sendable {
    static let shared = CardImageProcessor()

    /// Maximum image dimension before resizing
    static let maxStorageDimension: CGFloat = 3072

    private enum BackgroundTrim {
        static let analysisMaxDimension: CGFloat = 768
        static let cornerSampleRatio: CGFloat = 0.04
        static let colorDistanceThreshold: CGFloat = 34
        static let alphaDistanceWeight: CGFloat = 0.5
        static let alphaThreshold: CGFloat = 16
        static let cropPaddingRatio: CGFloat = 0.02
        static let minimumContentWidthRatio: CGFloat = 0.25
        static let minimumContentHeightRatio: CGFloat = 0.12
        static let minimumTrimRatio: CGFloat = 0.04
        static let minimumTrimmedAreaRatio: CGFloat = 0.06
        static let minimumAspectRatio: CGFloat = 0.35
        static let maximumAspectRatio: CGFloat = 3.2
    }

    // Use shared CIContext from ImageEnhancer (expensive to create, should be reused)
    private let context = ImageProcessingContext.shared

    private init() {}

    // MARK: - Storage Preparation

    /// Resizes (if above the storage dimension limit) and compresses an image for
    /// persistent storage. Runs off the main thread.
    func prepareForStorage(_ image: UIImage) async throws -> Data {
        try await ImageProcessingWorkQueue.shared.run { isCancelled in
            guard !isCancelled() else {
                throw CancellationError()
            }
            return try Self.compressForStorage(image)
        }
    }

    /// Synchronous resize + compress for storage. Prefer `prepareForStorage(_:)` from UI code.
    static func compressForStorage(_ image: UIImage) throws -> Data {
        let resized = resizeIfNeeded(image, maxDimension: maxStorageDimension)
        return try compress(resized)
    }

    static func resizeIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        CardImageRepository.resizeIfNeeded(image, maxDimension: maxDimension)
    }

    /// Normalizes imported images and rendered documents so saved card images
    /// contain the card instead of surrounding page/photo whitespace.
    func cropToCardContentAsync(_ image: UIImage) async -> UIImage {
        let orientedImage = fixImageOrientation(image)
        let storageSizedImage = Self.resizeIfNeeded(orientedImage, maxDimension: Self.maxStorageDimension)
        let blankTrimmedImage = Self.trimUniformBackground(from: storageSizedImage)

        guard let observation = await detectRectangle(in: blankTrimmedImage),
              let correctedImage = await correctPerspectiveAsync(
                image: blankTrimmedImage,
                observation: observation
              ) else {
            return await ensureProperOrientationAsync(blankTrimmedImage)
        }

        return Self.trimUniformBackground(from: correctedImage)
    }

    private static func trimUniformBackground(from image: UIImage) -> UIImage {
        let analysisImage = resizeIfNeeded(image, maxDimension: BackgroundTrim.analysisMaxDimension)
        guard let originalCGImage = image.cgImage,
              let analysisBuffer = PixelBuffer(image: analysisImage),
              let analysisCropRect = uniformBackgroundCropRect(in: analysisBuffer) else {
            return image
        }

        let scaleX = CGFloat(originalCGImage.width) / CGFloat(analysisBuffer.width)
        let scaleY = CGFloat(originalCGImage.height) / CGFloat(analysisBuffer.height)
        let cropRect = CGRect(
            x: floor(analysisCropRect.minX * scaleX),
            y: floor(analysisCropRect.minY * scaleY),
            width: ceil(analysisCropRect.width * scaleX),
            height: ceil(analysisCropRect.height * scaleY)
        )
        .intersection(CGRect(
            x: 0,
            y: 0,
            width: CGFloat(originalCGImage.width),
            height: CGFloat(originalCGImage.height)
        ))

        guard cropRect.width >= 1,
              cropRect.height >= 1,
              let croppedImage = originalCGImage.cropping(to: cropRect) else {
            return image
        }

        return UIImage(cgImage: croppedImage, scale: image.scale, orientation: image.imageOrientation)
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

        return CardImageRepository.redraw(image)
    }

    /// Rotates image by specified radians (e.g., .pi / 2 for 90 degrees)
    private static func rotateImage(_ image: UIImage, by radians: CGFloat) -> UIImage {
        let rotatedSize = CGSize(width: image.size.height, height: image.size.width)

        return CardImageRepository.redraw(image, size: rotatedSize) { context, size in
            context.translateBy(x: size.width / 2, y: size.height / 2)
            context.rotate(by: radians)
            context.translateBy(x: -image.size.width / 2, y: -image.size.height / 2)
            image.draw(at: .zero)
        }
    }

    /// Uses text detection to determine if image needs rotation for proper reading orientation (async version)
    func ensureProperOrientationAsync(_ image: UIImage) async -> UIImage {
        guard let ciImage = CIImage(image: image) else {
            AppLogger.scanner.warning("CardImageProcessor: Failed to create CIImage for orientation check")
            return image
        }

        do {
            return try await withImageProcessingTimeout(seconds: Constants.Scanner.textDetectionTimeout) { startTimeout in
                try await ImageProcessingWorkQueue.shared.run(onStart: startTimeout) { isCancelled in
                    guard !isCancelled() else {
                        throw CancellationError()
                    }
                    return try self.ensureProperOrientationSynchronously(
                        image,
                        ciImage: ciImage,
                        isCancelled: isCancelled
                    )
                }
            }
        } catch is CancellationError {
            return image
        } catch ImageProcessingTimeoutError.timedOut {
            AppLogger.scanner.warning("CardImageProcessor: Text orientation detection timed out")
            return image
        } catch {
            AppLogger.scanner.error("CardImageProcessor: Text orientation detection failed: \(error.localizedDescription)")
            return image
        }
    }

    // MARK: - Rectangle Detection

    /// Detects a rectangle in a still image for accurate perspective correction
    func detectRectangle(in image: UIImage) async -> VNRectangleObservation? {
        guard let cgImage = image.cgImage else {
            AppLogger.scanner.warning("CardImageProcessor: Failed to get CGImage for rectangle detection")
            return nil
        }

        do {
            return try await withImageProcessingTimeout(seconds: Constants.Scanner.textDetectionTimeout) { startTimeout in
                try await ImageProcessingWorkQueue.shared.run(onStart: startTimeout) { isCancelled in
                    guard !isCancelled() else {
                        throw CancellationError()
                    }
                    return try self.detectRectangleSynchronously(
                        cgImage: cgImage,
                        isCancelled: isCancelled
                    )
                }
            }
        } catch is CancellationError {
            return nil
        } catch ImageProcessingTimeoutError.timedOut {
            AppLogger.scanner.warning("CardImageProcessor: Rectangle detection timed out")
            return nil
        } catch {
            AppLogger.scanner.error("CardImageProcessor: Rectangle detection failed: \(error.localizedDescription)")
            return nil
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

    private static func uniformBackgroundCropRect(in buffer: PixelBuffer) -> CGRect? {
        let backgroundColor = averageCornerColor(in: buffer)
        var minX = buffer.width
        var minY = buffer.height
        var maxX = -1
        var maxY = -1

        for y in 0..<buffer.height {
            for x in 0..<buffer.width {
                let color = buffer.color(atX: x, y: y)
                guard isForeground(color, comparedTo: backgroundColor) else { continue }

                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)
            }
        }

        guard maxX >= minX, maxY >= minY else {
            return nil
        }

        let padding = max(2, Int(CGFloat(max(buffer.width, buffer.height)) * BackgroundTrim.cropPaddingRatio))
        minX = max(0, minX - padding)
        minY = max(0, minY - padding)
        maxX = min(buffer.width - 1, maxX + padding)
        maxY = min(buffer.height - 1, maxY + padding)

        let cropWidth = maxX - minX + 1
        let cropHeight = maxY - minY + 1
        let widthRatio = CGFloat(cropWidth) / CGFloat(buffer.width)
        let heightRatio = CGFloat(cropHeight) / CGFloat(buffer.height)
        let aspectRatio = CGFloat(cropWidth) / CGFloat(cropHeight)
        let horizontalTrimRatio = CGFloat(minX + (buffer.width - 1 - maxX)) / CGFloat(buffer.width)
        let verticalTrimRatio = CGFloat(minY + (buffer.height - 1 - maxY)) / CGFloat(buffer.height)
        let cropArea = CGFloat(cropWidth * cropHeight)
        let totalArea = CGFloat(buffer.width * buffer.height)
        let trimmedAreaRatio = 1 - cropArea / totalArea

        guard widthRatio >= BackgroundTrim.minimumContentWidthRatio,
              heightRatio >= BackgroundTrim.minimumContentHeightRatio,
              aspectRatio >= BackgroundTrim.minimumAspectRatio,
              aspectRatio <= BackgroundTrim.maximumAspectRatio,
              max(horizontalTrimRatio, verticalTrimRatio) >= BackgroundTrim.minimumTrimRatio,
              trimmedAreaRatio >= BackgroundTrim.minimumTrimmedAreaRatio else {
            return nil
        }

        return CGRect(
            x: CGFloat(minX),
            y: CGFloat(minY),
            width: CGFloat(cropWidth),
            height: CGFloat(cropHeight)
        )
    }

    private static func averageCornerColor(in buffer: PixelBuffer) -> PixelSample {
        let sampleWidth = min(
            buffer.width,
            max(2, Int(CGFloat(buffer.width) * BackgroundTrim.cornerSampleRatio))
        )
        let sampleHeight = min(
            buffer.height,
            max(2, Int(CGFloat(buffer.height) * BackgroundTrim.cornerSampleRatio))
        )
        let regions = [
            (x: 0..<sampleWidth, y: 0..<sampleHeight),
            (x: (buffer.width - sampleWidth)..<buffer.width, y: 0..<sampleHeight),
            (x: 0..<sampleWidth, y: (buffer.height - sampleHeight)..<buffer.height),
            (x: (buffer.width - sampleWidth)..<buffer.width, y: (buffer.height - sampleHeight)..<buffer.height)
        ]

        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        var count: CGFloat = 0

        for region in regions {
            for y in region.y {
                for x in region.x {
                    let color = buffer.color(atX: x, y: y)
                    red += color.red
                    green += color.green
                    blue += color.blue
                    alpha += color.alpha
                    count += 1
                }
            }
        }

        guard count > 0 else {
            return PixelSample(red: 255, green: 255, blue: 255, alpha: 255)
        }

        return PixelSample(
            red: red / count,
            green: green / count,
            blue: blue / count,
            alpha: alpha / count
        )
    }

    private static func isForeground(_ color: PixelSample, comparedTo background: PixelSample) -> Bool {
        guard color.alpha > BackgroundTrim.alphaThreshold else {
            return false
        }

        let redDelta = color.red - background.red
        let greenDelta = color.green - background.green
        let blueDelta = color.blue - background.blue
        let alphaDelta = (color.alpha - background.alpha) * BackgroundTrim.alphaDistanceWeight
        let distance = (redDelta * redDelta
            + greenDelta * greenDelta
            + blueDelta * blueDelta
            + alphaDelta * alphaDelta
        ).squareRoot()

        return distance > BackgroundTrim.colorDistanceThreshold
    }

    private struct PixelSample {
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
    }

    private struct PixelBuffer {
        let width: Int
        let height: Int

        private let bytes: [UInt8]
        private let bytesPerPixel = 4
        private let bytesPerRow: Int

        init?(image: UIImage) {
            guard let cgImage = image.cgImage else {
                return nil
            }

            let width = cgImage.width
            let height = cgImage.height
            guard width > 0, height > 0 else {
                return nil
            }

            let bytesPerPixel = 4
            let bytesPerRow = width * bytesPerPixel
            var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
            let bitmapInfo = CGBitmapInfo.byteOrder32Big.rawValue
                | CGImageAlphaInfo.premultipliedLast.rawValue

            let didDraw = bytes.withUnsafeMutableBytes { bufferPointer -> Bool in
                guard let baseAddress = bufferPointer.baseAddress,
                      let context = CGContext(
                        data: baseAddress,
                        width: width,
                        height: height,
                        bitsPerComponent: 8,
                        bytesPerRow: bytesPerRow,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: bitmapInfo
                      ) else {
                    return false
                }

                context.draw(cgImage, in: CGRect(
                    x: 0,
                    y: 0,
                    width: CGFloat(width),
                    height: CGFloat(height)
                ))
                return true
            }

            guard didDraw else {
                return nil
            }

            self.width = width
            self.height = height
            self.bytes = bytes
            self.bytesPerRow = bytesPerRow
        }

        func color(atX x: Int, y: Int) -> PixelSample {
            let offset = y * bytesPerRow + x * bytesPerPixel
            return PixelSample(
                red: CGFloat(bytes[offset]),
                green: CGFloat(bytes[offset + 1]),
                blue: CGFloat(bytes[offset + 2]),
                alpha: CGFloat(bytes[offset + 3])
            )
        }
    }

    private func ensureProperOrientationSynchronously(
        _ image: UIImage,
        ciImage: CIImage,
        isCancelled: () -> Bool
    ) throws -> UIImage {
        try autoreleasepool {
            guard !isCancelled() else {
                throw CancellationError()
            }

            var observations: [VNRecognizedTextObservation] = []
            var requestError: Error?

            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    requestError = error
                    return
                }

                observations = request.results as? [VNRecognizedTextObservation] ?? []
            }

            request.recognitionLevel = .fast
            request.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
            try handler.perform([request])

            guard !isCancelled() else {
                throw CancellationError()
            }

            if let requestError {
                AppLogger.scanner.error("CardImageProcessor: Text recognition error: \(requestError.localizedDescription)")
                throw requestError
            }

            guard !observations.isEmpty else {
                return image
            }

            let needsRotation = Self.shouldRotateBasedOnTextOrientation(observations)
            return needsRotation ? Self.rotateImage(image, by: .pi / 2) : image
        }
    }

    private func detectRectangleSynchronously(
        cgImage: CGImage,
        isCancelled: () -> Bool
    ) throws -> VNRectangleObservation? {
        try autoreleasepool {
            guard !isCancelled() else {
                throw CancellationError()
            }

            var rectangle: VNRectangleObservation?
            var requestError: Error?

            let request = VNDetectRectanglesRequest { request, error in
                if let error {
                    requestError = error
                    return
                }
                rectangle = (request.results as? [VNRectangleObservation])?.first
            }

            request.minimumAspectRatio = Constants.Scanner.minimumAspectRatio
            request.maximumAspectRatio = Constants.Scanner.maximumAspectRatio
            request.minimumSize = Constants.Scanner.minimumSize
            request.minimumConfidence = Constants.Scanner.minimumConfidence
            request.maximumObservations = 1
            request.quadratureTolerance = Constants.Scanner.quadratureTolerance

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            try handler.perform([request])

            guard !isCancelled() else {
                throw CancellationError()
            }

            if let requestError {
                AppLogger.scanner.error("CardImageProcessor: Rectangle detection error: \(requestError.localizedDescription)")
                throw requestError
            }

            return rectangle
        }
    }

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
