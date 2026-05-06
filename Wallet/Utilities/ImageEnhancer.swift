import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Shared CIContext for all image processing operations (expensive to create)
enum ImageProcessingContext {
    static let shared = CIContext()
}

enum ImageProcessingTimeoutError: Error {
    case timedOut
}

func withImageProcessingTimeout<Value>(
    seconds: TimeInterval,
    operation: @escaping () async throws -> Value
) async throws -> Value {
    try await withThrowingTaskGroup(of: Value.self) { group in
        group.addTask {
            try await operation()
        }
        group.addTask {
            let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
            try await Task.sleep(nanoseconds: nanoseconds)
            throw ImageProcessingTimeoutError.timedOut
        }

        guard let result = try await group.next() else {
            throw CancellationError()
        }

        group.cancelAll()
        return result
    }
}

final class ImageProcessingWorkQueue: @unchecked Sendable {
    static let shared = ImageProcessingWorkQueue()

    private let queue: OperationQueue

    init(
        maxConcurrentOperationCount: Int = 2,
        name: String = "wallet.image-processing.work-queue"
    ) {
        queue = OperationQueue()
        queue.name = name
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = max(1, maxConcurrentOperationCount)
    }

    func run<Value>(
        _ operation: @escaping (_ isCancelled: @escaping () -> Bool) throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()

        let workItem = ImageProcessingOperation(operation: operation)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Value, any Error>) in
                workItem.setContinuation(continuation)
                queue.addOperation(workItem)
            }
        } onCancel: {
            workItem.cancel()
        }
    }
}

private final class ImageProcessingOperation<Value>: Operation, @unchecked Sendable {
    private let operation: (_ isCancelled: @escaping () -> Bool) throws -> Value
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?
    private var didFinish = false

    init(operation: @escaping (_ isCancelled: @escaping () -> Bool) throws -> Value) {
        self.operation = operation
    }

    func setContinuation(_ continuation: CheckedContinuation<Value, any Error>) {
        lock.lock()
        if didFinish {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }

        self.continuation = continuation
        lock.unlock()
    }

    override func main() {
        guard !isCancelled else {
            finish(.failure(CancellationError()))
            return
        }

        let result: Result<Value, any Error> = autoreleasepool {
            do {
                guard !isCancelled else {
                    throw CancellationError()
                }

                let value = try operation { [weak self] in
                    self?.isCancelled ?? true
                }

                guard !isCancelled else {
                    throw CancellationError()
                }

                return .success(value)
            } catch {
                return .failure(error)
            }
        }

        finish(result)
    }

    override func cancel() {
        super.cancel()
        finish(.failure(CancellationError()))
    }

    private func finish(_ result: Result<Value, any Error>) {
        lock.lock()
        guard !didFinish else {
            lock.unlock()
            return
        }

        didFinish = true
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()

        continuation?.resume(with: result)
    }
}

final class ImageEnhancer: @unchecked Sendable {
    private let context = ImageProcessingContext.shared

    static let shared = ImageEnhancer()

    private init() {}

    /// Enhances a card image for better legibility
    func enhance(_ image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else {
            AppLogger.ui.warning("ImageEnhancer: Failed to create CIImage for enhancement")
            return image
        }

        var enhanced = ciImage

        // Step 1: Auto-adjust exposure, contrast, and saturation
        enhanced = autoAdjust(enhanced)

        // Step 2: Sharpen for text clarity
        enhanced = sharpen(enhanced)

        // Step 3: Reduce noise
        enhanced = reduceNoise(enhanced)

        // Step 4: Increase local contrast for text
        enhanced = unsharpMask(enhanced)

        // Convert back to UIImage
        guard let cgImage = context.createCGImage(enhanced, from: enhanced.extent) else {
            AppLogger.ui.warning("ImageEnhancer: Failed to create CGImage from enhanced image")
            return image
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Async enhancement on the bounded image processing queue.
    func enhanceAsync(_ image: UIImage) async -> UIImage {
        do {
            return try await ImageProcessingWorkQueue.shared.run { isCancelled in
                guard !isCancelled() else {
                    throw CancellationError()
                }
                return self.enhance(image)
            }
        } catch is CancellationError {
            return image
        } catch {
            AppLogger.ui.error("ImageEnhancer: Enhancement failed: \(error.localizedDescription)")
            return image
        }
    }

    /// Async document enhancement on the bounded image processing queue.
    func enhanceAsDocumentAsync(_ image: UIImage) async -> UIImage {
        do {
            return try await ImageProcessingWorkQueue.shared.run { isCancelled in
                guard !isCancelled() else {
                    throw CancellationError()
                }
                return self.enhanceAsDocument(image)
            }
        } catch is CancellationError {
            return image
        } catch {
            AppLogger.ui.error("ImageEnhancer: Document enhancement failed: \(error.localizedDescription)")
            return image
        }
    }

    /// Document-style enhancement (high contrast B&W option)
    func enhanceAsDocument(_ image: UIImage, blackAndWhite: Bool = false) -> UIImage {
        guard let ciImage = CIImage(image: image) else {
            AppLogger.ui.warning("ImageEnhancer: Failed to create CIImage for document enhancement")
            return image
        }

        var enhanced = ciImage

        // Auto-adjust
        enhanced = autoAdjust(enhanced)

        // Strong sharpening for documents
        enhanced = sharpen(enhanced, intensity: Constants.Enhancement.documentSharpness)

        // High contrast
        enhanced = adjustContrast(enhanced, contrast: Constants.Enhancement.documentContrast)

        // Convert to B&W if requested (good for text-heavy cards)
        if blackAndWhite {
            enhanced = convertToGrayscale(enhanced)
            enhanced = adjustContrast(enhanced, contrast: Constants.Enhancement.bwContrast)
        }

        guard let cgImage = context.createCGImage(enhanced, from: enhanced.extent) else {
            AppLogger.ui.warning("ImageEnhancer: Failed to create CGImage from document-enhanced image")
            return image
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - Filter Operations

    private func autoAdjust(_ image: CIImage) -> CIImage {
        let filters = image.autoAdjustmentFilters()
        var output = image
        for filter in filters {
            filter.setValue(output, forKey: kCIInputImageKey)
            if let result = filter.outputImage {
                output = result
            }
        }
        return output
    }

    private func sharpen(_ image: CIImage, intensity: Float = Constants.Enhancement.defaultSharpness) -> CIImage {
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = image
        filter.sharpness = intensity
        guard let output = filter.outputImage else {
            AppLogger.ui.warning("ImageEnhancer: Sharpen filter failed")
            return image
        }
        return output
    }

    private func unsharpMask(_ image: CIImage) -> CIImage {
        let filter = CIFilter.unsharpMask()
        filter.inputImage = image
        filter.radius = Constants.Enhancement.unsharpMaskRadius
        filter.intensity = Constants.Enhancement.unsharpMaskIntensity
        guard let output = filter.outputImage else {
            AppLogger.ui.warning("ImageEnhancer: Unsharp mask filter failed")
            return image
        }
        return output
    }

    private func reduceNoise(_ image: CIImage) -> CIImage {
        let filter = CIFilter.noiseReduction()
        filter.inputImage = image
        filter.noiseLevel = Constants.Enhancement.noiseLevel
        filter.sharpness = Constants.Enhancement.noiseSharpness
        guard let output = filter.outputImage else {
            AppLogger.ui.warning("ImageEnhancer: Noise reduction filter failed")
            return image
        }
        return output
    }

    private func adjustContrast(_ image: CIImage, contrast: Float) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.contrast = contrast
        filter.saturation = Constants.Enhancement.saturation
        filter.brightness = 0.0
        guard let output = filter.outputImage else {
            AppLogger.ui.warning("ImageEnhancer: Contrast adjustment filter failed")
            return image
        }
        return output
    }

    private func convertToGrayscale(_ image: CIImage) -> CIImage {
        let filter = CIFilter.photoEffectNoir()
        filter.inputImage = image
        guard let output = filter.outputImage else {
            AppLogger.ui.warning("ImageEnhancer: Grayscale conversion filter failed")
            return image
        }
        return output
    }
}
