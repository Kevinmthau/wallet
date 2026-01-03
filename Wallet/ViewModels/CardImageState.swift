import SwiftUI
import PhotosUI

@Observable
class CardImageState {
    // Images
    var frontImage: UIImage?
    var backImage: UIImage?
    var frontChanged = false
    var backChanged = false

    // OCR results
    var frontOCRResult: OCRExtractionResult?
    var backOCRResult: OCRExtractionResult?
    var lastOCRNotes: String?

    // Scanner control
    var showingScanner = false
    var scannerTarget: ScanTarget = .front

    // Photo picker control
    var showingFrontPicker = false
    var showingBackPicker = false
    var selectedFrontItem: PhotosPickerItem?
    var selectedBackItem: PhotosPickerItem?

    // UI state
    var isEnhancing = false

    enum ScanTarget {
        case front, back
    }

    init(frontImage: UIImage? = nil, backImage: UIImage? = nil) {
        self.frontImage = frontImage
        self.backImage = backImage
    }

    // MARK: - Private Helpers

    private func image(for target: ScanTarget) -> UIImage? {
        switch target {
        case .front: return frontImage
        case .back: return backImage
        }
    }

    private func setImage(_ image: UIImage?, for target: ScanTarget, isEditMode: Bool) {
        switch target {
        case .front:
            frontImage = image
            if isEditMode { frontChanged = true }
        case .back:
            backImage = image
            if isEditMode { backChanged = true }
        }
    }

    private func setOCRResult(_ result: OCRExtractionResult?, for target: ScanTarget) {
        switch target {
        case .front: frontOCRResult = result
        case .back: backOCRResult = result
        }
    }

    // MARK: - Scan Result Handling

    func handleScanResult(_ result: ScanResult, isEditMode: Bool) {
        // Store OCR result immediately, then enhance asynchronously
        let target = scannerTarget
        setOCRResult(result.extractedText, for: target)

        isEnhancing = true
        Task {
            let enhanced = await ImageEnhancer.shared.enhanceAsync(result.image)
            await MainActor.run {
                self.setImage(enhanced, for: target, isEditMode: isEditMode)
                self.isEnhancing = false
            }
        }
    }

    // MARK: - Photo Picker Handling

    func loadAndEnhanceImage(from item: PhotosPickerItem?, for target: ScanTarget, isEditMode: Bool) {
        guard let item = item else { return }

        isEnhancing = true
        Task {
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    await MainActor.run { self.isEnhancing = false }
                    return
                }

                async let enhancedImage = ImageEnhancer.shared.enhanceAsync(image)
                async let ocrResult = OCRExtractor.shared.extractText(from: image)

                let enhanced = await enhancedImage
                let extractedText = await ocrResult

                await MainActor.run {
                    self.setImage(enhanced, for: target, isEditMode: isEditMode)
                    self.setOCRResult(extractedText, for: target)
                    self.isEnhancing = false
                }
            } catch {
                AppLogger.ui.error("CardImageState: Failed to load image: \(error.localizedDescription)")
                await MainActor.run { self.isEnhancing = false }
            }
        }
    }

    // MARK: - Enhancement

    func enhanceImage(for target: ScanTarget, isEditMode: Bool) {
        guard let img = image(for: target) else { return }

        isEnhancing = true
        Task {
            let enhanced = await ImageEnhancer.shared.enhanceAsDocumentAsync(img)
            await MainActor.run {
                self.setImage(enhanced, for: target, isEditMode: isEditMode)
                self.isEnhancing = false
            }
        }
    }

    // MARK: - Remove Image

    func removeImage(for target: ScanTarget, isEditMode: Bool) {
        setImage(nil, for: target, isEditMode: isEditMode)
    }

    // MARK: - OCR Text Collection

    func collectOCRTexts() -> [String] {
        var allTexts: [String] = []

        if let frontTexts = frontOCRResult?.texts {
            allTexts.append(contentsOf: frontTexts)
        }

        if let backTexts = backOCRResult?.texts {
            for text in backTexts {
                if !allTexts.contains(text) {
                    allTexts.append(text)
                }
            }
        }

        return allTexts
    }
}
