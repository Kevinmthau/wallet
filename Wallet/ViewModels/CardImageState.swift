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
        let enhanced = ImageEnhancer.shared.enhance(result.image)
        switch scannerTarget {
        case .front:
            frontImage = enhanced
            frontOCRResult = result.extractedText
            if isEditMode { frontChanged = true }
        case .back:
            backImage = enhanced
            backOCRResult = result.extractedText
            if isEditMode { backChanged = true }
        }
    }

    // MARK: - Photo Picker Handling

    func loadAndEnhanceImage(from item: PhotosPickerItem?, for target: ScanTarget, isEditMode: Bool) {
        guard let item = item else { return }

        isEnhancing = true
        item.loadTransferable(type: Data.self) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let data):
                    if let data = data, let image = UIImage(data: data) {
                        let enhanced = ImageEnhancer.shared.enhance(image)
                        switch target {
                        case .front:
                            self.frontImage = enhanced
                            if isEditMode { self.frontChanged = true }
                        case .back:
                            self.backImage = enhanced
                            if isEditMode { self.backChanged = true }
                        }
                    }
                case .failure(let error):
                    AppLogger.ui.error("CardImageState: Failed to load image: \(error.localizedDescription)")
                }
                self.isEnhancing = false
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
