import SwiftUI
import PhotosUI

@Observable
class CardImageState {

    // MARK: - Types

    enum ScanTarget {
        case front, back
    }

    // MARK: - Image Data

    var frontImage: UIImage?
    var backImage: UIImage?
    var frontChanged = false
    var backChanged = false

    // MARK: - Task Tracking

    private var currentTask: Task<Void, Never>?

    // MARK: - OCR Results

    var frontOCRResult: OCRExtractionResult?
    var backOCRResult: OCRExtractionResult?
    /// Tracks last auto-populated OCR notes to detect manual user edits
    var lastOCRNotes: String?

    // MARK: - Scanner State

    var showingScanner = false
    var scannerTarget: ScanTarget = .front

    // MARK: - Photo Picker State

    /// Note: Separate front/back pickers required by SwiftUI photosPicker API
    var showingFrontPicker = false
    var showingBackPicker = false
    var selectedFrontItem: PhotosPickerItem?
    var selectedBackItem: PhotosPickerItem?

    // MARK: - UI State

    var isEnhancing = false

    // MARK: - Initialization

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
        currentTask?.cancel()
        currentTask = Task {
            guard !Task.isCancelled else {
                await MainActor.run { self.isEnhancing = false }
                return
            }

            let enhanced = await ImageEnhancer.shared.enhanceAsync(result.image)

            guard !Task.isCancelled else {
                await MainActor.run { self.isEnhancing = false }
                return
            }

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
        currentTask?.cancel()
        currentTask = Task {
            do {
                guard !Task.isCancelled else {
                    await MainActor.run { self.isEnhancing = false }
                    return
                }

                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    await MainActor.run { self.isEnhancing = false }
                    return
                }

                guard !Task.isCancelled else {
                    await MainActor.run { self.isEnhancing = false }
                    return
                }

                async let enhancedImage = ImageEnhancer.shared.enhanceAsync(image)
                async let ocrResult = OCRExtractor.shared.extractText(from: image)

                let enhanced = await enhancedImage
                let extractedText = await ocrResult

                guard !Task.isCancelled else {
                    await MainActor.run { self.isEnhancing = false }
                    return
                }

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
        currentTask?.cancel()
        currentTask = Task {
            guard !Task.isCancelled else {
                await MainActor.run { self.isEnhancing = false }
                return
            }

            let enhanced = await ImageEnhancer.shared.enhanceAsDocumentAsync(img)

            guard !Task.isCancelled else {
                await MainActor.run { self.isEnhancing = false }
                return
            }

            await MainActor.run {
                self.setImage(enhanced, for: target, isEditMode: isEditMode)
                self.isEnhancing = false
            }
        }
    }

    // MARK: - Cleanup

    func cancelPendingTasks() {
        currentTask?.cancel()
        currentTask = nil
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
