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

    deinit {
        cancelPendingTasks()
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

    /// Runs an async image operation while guaranteeing that:
    /// - any prior in-flight task is cancelled first,
    /// - `isEnhancing` is flipped on for the duration,
    /// - cancellation is honored (no state is written if cancelled),
    /// - `isEnhancing` and `currentTask` are always reset on exit.
    private func runExclusiveImageTask(_ work: @MainActor @escaping () async -> Void) {
        currentTask?.cancel()
        isEnhancing = true
        currentTask = Task { @MainActor in
            defer {
                isEnhancing = false
                currentTask = nil
            }
            guard !Task.isCancelled else { return }
            await work()
        }
    }

    // MARK: - Scan Result Handling

    func handleScanResult(_ result: ScanResult, isEditMode: Bool) {
        // Store OCR result immediately, then enhance asynchronously
        let target = scannerTarget
        setOCRResult(result.extractedText, for: target)

        runExclusiveImageTask { [weak self] in
            let enhanced = await ImageEnhancer.shared.enhanceAsync(result.image)
            guard !Task.isCancelled, let self else { return }
            self.setImage(enhanced, for: target, isEditMode: isEditMode)
        }
    }

    // MARK: - Photo Picker Handling

    func loadAndEnhanceImage(from item: PhotosPickerItem?, for target: ScanTarget, isEditMode: Bool) {
        guard let item else { return }

        runExclusiveImageTask { [weak self] in
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    return
                }
                guard !Task.isCancelled else { return }

                async let enhancedImage = ImageEnhancer.shared.enhanceAsync(image)
                async let ocrResult = OCRExtractor.shared.extractText(from: image)
                let enhanced = await enhancedImage
                let extractedText = await ocrResult

                guard !Task.isCancelled, let self else { return }
                self.setImage(enhanced, for: target, isEditMode: isEditMode)
                self.setOCRResult(extractedText, for: target)
            } catch {
                AppLogger.ui.error("CardImageState: Failed to load image: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Enhancement

    func enhanceImage(for target: ScanTarget, isEditMode: Bool) {
        guard let img = image(for: target) else { return }

        runExclusiveImageTask { [weak self] in
            let enhanced = await ImageEnhancer.shared.enhanceAsDocumentAsync(img)
            guard !Task.isCancelled, let self else { return }
            self.setImage(enhanced, for: target, isEditMode: isEditMode)
        }
    }

    // MARK: - Cleanup

    func cancelPendingTasks() {
        currentTask?.cancel()
        currentTask = nil
        isEnhancing = false
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
