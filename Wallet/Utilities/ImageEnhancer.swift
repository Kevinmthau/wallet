import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Shared CIContext for all image processing operations (expensive to create)
enum ImageProcessingContext {
    static let shared = CIContext()
}

class ImageEnhancer {
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

    /// Async enhancement on background thread
    func enhanceAsync(_ image: UIImage) async -> UIImage {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let enhanced = self.enhance(image)
                continuation.resume(returning: enhanced)
            }
        }
    }

    /// Async document enhancement on background thread
    func enhanceAsDocumentAsync(_ image: UIImage) async -> UIImage {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let enhanced = self.enhanceAsDocument(image)
                continuation.resume(returning: enhanced)
            }
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
