import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

class ImageEnhancer {
    private let context = CIContext()

    static let shared = ImageEnhancer()

    private init() {}

    /// Enhances a card image for better legibility
    func enhance(_ image: UIImage) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }

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
            return image
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    /// Document-style enhancement (high contrast B&W option)
    func enhanceAsDocument(_ image: UIImage, blackAndWhite: Bool = false) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }

        var enhanced = ciImage

        // Auto-adjust
        enhanced = autoAdjust(enhanced)

        // Strong sharpening for documents
        enhanced = sharpen(enhanced, intensity: 0.8)

        // High contrast
        enhanced = adjustContrast(enhanced, contrast: 1.2)

        // Convert to B&W if requested (good for text-heavy cards)
        if blackAndWhite {
            enhanced = convertToGrayscale(enhanced)
            enhanced = adjustContrast(enhanced, contrast: 1.3)
        }

        guard let cgImage = context.createCGImage(enhanced, from: enhanced.extent) else {
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

    private func sharpen(_ image: CIImage, intensity: Float = 0.5) -> CIImage {
        let filter = CIFilter.sharpenLuminance()
        filter.inputImage = image
        filter.sharpness = intensity
        return filter.outputImage ?? image
    }

    private func unsharpMask(_ image: CIImage) -> CIImage {
        let filter = CIFilter.unsharpMask()
        filter.inputImage = image
        filter.radius = 2.5
        filter.intensity = 0.5
        return filter.outputImage ?? image
    }

    private func reduceNoise(_ image: CIImage) -> CIImage {
        let filter = CIFilter.noiseReduction()
        filter.inputImage = image
        filter.noiseLevel = 0.02
        filter.sharpness = 0.4
        return filter.outputImage ?? image
    }

    private func adjustContrast(_ image: CIImage, contrast: Float) -> CIImage {
        let filter = CIFilter.colorControls()
        filter.inputImage = image
        filter.contrast = contrast
        filter.saturation = 1.1
        filter.brightness = 0.0
        return filter.outputImage ?? image
    }

    private func convertToGrayscale(_ image: CIImage) -> CIImage {
        let filter = CIFilter.photoEffectNoir()
        filter.inputImage = image
        return filter.outputImage ?? image
    }

    // MARK: - Perspective Correction (if needed beyond document scanner)

    func correctPerspective(_ image: UIImage, topLeft: CGPoint, topRight: CGPoint, bottomLeft: CGPoint, bottomRight: CGPoint) -> UIImage {
        guard let ciImage = CIImage(image: image) else { return image }

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ciImage
        filter.topLeft = topLeft
        filter.topRight = topRight
        filter.bottomLeft = bottomLeft
        filter.bottomRight = bottomRight

        guard let output = filter.outputImage,
              let cgImage = context.createCGImage(output, from: output.extent) else {
            return image
        }

        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}
