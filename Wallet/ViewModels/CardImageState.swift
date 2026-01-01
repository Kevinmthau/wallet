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

    // MARK: - Scan Result Handling

    func handleScanResult(_ result: ScanResult, isEditMode: Bool) {
        // Store OCR result immediately, then enhance asynchronously
        let target = scannerTarget
        switch target {
        case .front:
            frontOCRResult = result.extractedText
        case .back:
            backOCRResult = result.extractedText
        }

        isEnhancing = true
        Task {
            let enhanced = await ImageEnhancer.shared.enhanceAsync(result.image)
            await MainActor.run {
                switch target {
                case .front:
                    self.frontImage = enhanced
                    if isEditMode { self.frontChanged = true }
                case .back:
                    self.backImage = enhanced
                    if isEditMode { self.backChanged = true }
                }
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

                let enhanced = await ImageEnhancer.shared.enhanceAsync(image)

                await MainActor.run {
                    switch target {
                    case .front:
                        self.frontImage = enhanced
                        if isEditMode { self.frontChanged = true }
                    case .back:
                        self.backImage = enhanced
                        if isEditMode { self.backChanged = true }
                    }
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
        let image: UIImage?
        switch target {
        case .front: image = frontImage
        case .back: image = backImage
        }

        guard let img = image else { return }

        isEnhancing = true
        Task {
            let enhanced = await ImageEnhancer.shared.enhanceAsDocumentAsync(img)
            await MainActor.run {
                switch target {
                case .front:
                    self.frontImage = enhanced
                    if isEditMode { self.frontChanged = true }
                case .back:
                    self.backImage = enhanced
                    if isEditMode { self.backChanged = true }
                }
                self.isEnhancing = false
            }
        }
    }

    // MARK: - Remove Image

    func removeImage(for target: ScanTarget, isEditMode: Bool) {
        switch target {
        case .front:
            frontImage = nil
            if isEditMode { frontChanged = true }
        case .back:
            backImage = nil
            if isEditMode { backChanged = true }
        }
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
