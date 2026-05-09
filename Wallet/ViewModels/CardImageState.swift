import SwiftUI
import PhotosUI
import PDFKit
import UniformTypeIdentifiers

enum CardFileImportError: LocalizedError {
    case unsupportedFileType
    case unreadablePDF

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "Choose an image file or PDF."
        case .unreadablePDF:
            return "The selected PDF could not be rendered."
        }
    }
}

enum CardFileImageImporter {
    static let allowedContentTypes: [UTType] = [.image, .pdf]

    static func image(fromFileAt url: URL) async throws -> UIImage {
        try await ImageProcessingWorkQueue.shared.run { isCancelled in
            guard !isCancelled() else { throw CancellationError() }

            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityScope {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let data = try Data(contentsOf: url)
            guard !isCancelled() else { throw CancellationError() }
            return try image(from: data, filenameExtension: url.pathExtension)
        }
    }

    static func image(from data: Data, filenameExtension: String?) throws -> UIImage {
        if isPDF(data: data, filenameExtension: filenameExtension) {
            return try renderFirstPDFPage(from: data)
        }

        if let image = UIImage(data: data) {
            return image
        }

        throw CardFileImportError.unsupportedFileType
    }

    private static func isPDF(data: Data, filenameExtension: String?) -> Bool {
        if let filenameExtension,
           UTType(filenameExtension: filenameExtension)?.conforms(to: .pdf) == true {
            return true
        }

        return data.starts(with: [0x25, 0x50, 0x44, 0x46])
    }

    private static func renderFirstPDFPage(from data: Data) throws -> UIImage {
        guard let document = PDFDocument(data: data),
              let page = document.page(at: 0) else {
            throw CardFileImportError.unreadablePDF
        }

        let pageBounds = page.bounds(for: .cropBox)
        guard pageBounds.width > 0, pageBounds.height > 0 else {
            throw CardFileImportError.unreadablePDF
        }

        let maxDimension = CardImageProcessor.maxStorageDimension
        let scale = min(
            maxDimension / pageBounds.width,
            maxDimension / pageBounds.height
        )
        let renderSize = CGSize(
            width: pageBounds.width * scale,
            height: pageBounds.height * scale
        )
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0

        return UIGraphicsImageRenderer(size: renderSize, format: format).image { rendererContext in
            UIColor.white.setFill()
            rendererContext.fill(CGRect(origin: .zero, size: renderSize))

            let context = rendererContext.cgContext
            context.saveGState()
            context.translateBy(x: 0, y: renderSize.height)
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -pageBounds.minX, y: -pageBounds.minY)
            page.draw(with: .cropBox, to: context)
            context.restoreGState()
        }
    }
}

@Observable
class CardImageState {

    // MARK: - Types

    enum ScanTarget: Hashable {
        case front, back
    }

    typealias ImageEnhancementOperation = (UIImage) async -> UIImage
    typealias TextExtractionOperation = (UIImage) async -> OCRExtractionResult

    // MARK: - Image Data

    var frontImage: UIImage?
    var backImage: UIImage?
    var frontChanged = false
    var backChanged = false

    // MARK: - Task Tracking

    @ObservationIgnored private var imageTasks: [ScanTarget: Task<Void, Never>] = [:]
    @ObservationIgnored private var operationIDs: [ScanTarget: UUID] = [:]
    @ObservationIgnored private var activeTargets = Set<ScanTarget>()

    @ObservationIgnored private let enhanceImageOperation: ImageEnhancementOperation
    @ObservationIgnored private let enhanceDocumentImageOperation: ImageEnhancementOperation
    @ObservationIgnored private let extractTextOperation: TextExtractionOperation

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

    // MARK: - File Importer State

    var showingFrontFileImporter = false
    var showingBackFileImporter = false
    var importErrorMessage: String?

    // MARK: - UI State

    var isEnhancing = false

    // MARK: - Initialization

    init(
        frontImage: UIImage? = nil,
        backImage: UIImage? = nil,
        enhanceImageOperation: @escaping ImageEnhancementOperation = { image in
            await ImageEnhancer.shared.enhanceAsync(image)
        },
        enhanceDocumentImageOperation: @escaping ImageEnhancementOperation = { image in
            await ImageEnhancer.shared.enhanceAsDocumentAsync(image)
        },
        extractTextOperation: @escaping TextExtractionOperation = { image in
            await OCRExtractor.shared.extractText(from: image)
        }
    ) {
        self.frontImage = frontImage
        self.backImage = backImage
        self.enhanceImageOperation = enhanceImageOperation
        self.enhanceDocumentImageOperation = enhanceDocumentImageOperation
        self.extractTextOperation = extractTextOperation
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

    private func updateEnhancingState() {
        isEnhancing = !activeTargets.isEmpty
    }

    private func isCurrentOperation(_ operationID: UUID, for target: ScanTarget) -> Bool {
        operationIDs[target] == operationID && !Task.isCancelled
    }

    /// Runs an async image operation for one side while guaranteeing that:
    /// - prior work for that same side is cancelled first,
    /// - front and back operations can proceed independently,
    /// - stale or cancelled operations cannot write state,
    /// - `isEnhancing` reflects all active side-specific operations.
    private func runCurrentImageTask(
        for target: ScanTarget,
        _ work: @MainActor @escaping (_ operationID: UUID) async -> Void
    ) {
        cancelImageTask(for: target)

        let operationID = UUID()
        operationIDs[target] = operationID
        activeTargets.insert(target)
        updateEnhancingState()

        imageTasks[target] = Task { @MainActor [weak self] in
            defer {
                self?.finishImageTask(for: target, operationID: operationID)
            }
            guard !Task.isCancelled else { return }
            await work(operationID)
        }
    }

    private func cancelImageTask(for target: ScanTarget) {
        imageTasks[target]?.cancel()
        imageTasks[target] = nil
        operationIDs[target] = nil
        activeTargets.remove(target)
        updateEnhancingState()
    }

    private func finishImageTask(for target: ScanTarget, operationID: UUID) {
        guard operationIDs[target] == operationID else { return }

        imageTasks[target] = nil
        operationIDs[target] = nil
        activeTargets.remove(target)
        updateEnhancingState()
    }

    // MARK: - Scan Result Handling

    func handleScanResult(_ result: ScanResult, isEditMode: Bool) {
        // Store OCR result immediately, then enhance asynchronously
        let target = scannerTarget
        setOCRResult(result.extractedText, for: target)

        runCurrentImageTask(for: target) { [weak self] operationID in
            guard let self else { return }
            let enhanced = await self.enhanceImageOperation(result.image)
            guard self.isCurrentOperation(operationID, for: target) else { return }
            self.setImage(enhanced, for: target, isEditMode: isEditMode)
        }
    }

    // MARK: - Photo Picker Handling

    func loadAndEnhanceImage(from item: PhotosPickerItem?, for target: ScanTarget, isEditMode: Bool) {
        guard let item else { return }

        runCurrentImageTask(for: target) { [weak self] operationID in
            do {
                guard let data = try await item.loadTransferable(type: Data.self),
                      let image = UIImage(data: data) else {
                    return
                }
                guard let self, self.isCurrentOperation(operationID, for: target) else { return }

                async let enhancedImage = self.enhanceImageOperation(image)
                async let ocrResult = self.extractTextOperation(image)
                let enhanced = await enhancedImage
                let extractedText = await ocrResult

                guard self.isCurrentOperation(operationID, for: target) else { return }
                self.setImage(enhanced, for: target, isEditMode: isEditMode)
                self.setOCRResult(extractedText, for: target)
            } catch is CancellationError {
                return
            } catch {
                AppLogger.ui.error("CardImageState: Failed to load image: \(error.localizedDescription)")
            }
        }
    }

    func loadAndEnhanceImage(fromFileAt url: URL, for target: ScanTarget, isEditMode: Bool) {
        runCurrentImageTask(for: target) { [weak self] operationID in
            do {
                let image = try await CardFileImageImporter.image(fromFileAt: url)
                guard let self, self.isCurrentOperation(operationID, for: target) else { return }

                async let enhancedImage = self.enhanceImageOperation(image)
                async let ocrResult = self.extractTextOperation(image)
                let enhanced = await enhancedImage
                let extractedText = await ocrResult

                guard self.isCurrentOperation(operationID, for: target) else { return }
                self.setImage(enhanced, for: target, isEditMode: isEditMode)
                self.setOCRResult(extractedText, for: target)
            } catch is CancellationError {
                return
            } catch {
                self?.importErrorMessage = error.localizedDescription
                AppLogger.ui.error("CardImageState: Failed to import file: \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Enhancement

    func enhanceImage(
        for target: ScanTarget,
        isEditMode: Bool,
        sourceImage: (@MainActor () async -> UIImage?)? = nil
    ) {
        guard sourceImage != nil || image(for: target) != nil else { return }

        runCurrentImageTask(for: target) { [weak self] operationID in
            guard let self else { return }
            let source: UIImage?
            if let sourceImage {
                source = await sourceImage()
            } else {
                source = self.image(for: target)
            }

            guard self.isCurrentOperation(operationID, for: target), let source else { return }
            let enhanced = await self.enhanceDocumentImageOperation(source)
            guard self.isCurrentOperation(operationID, for: target) else { return }
            self.setImage(enhanced, for: target, isEditMode: isEditMode)
        }
    }

    // MARK: - Cleanup

    func cancelPendingTasks() {
        imageTasks.values.forEach { $0.cancel() }
        imageTasks.removeAll()
        operationIDs.removeAll()
        activeTargets.removeAll()
        isEnhancing = false
    }

    // MARK: - Remove Image

    func removeImage(for target: ScanTarget, isEditMode: Bool) {
        cancelImageTask(for: target)
        setImage(nil, for: target, isEditMode: isEditMode)
        setOCRResult(nil, for: target)
    }

    func setExistingImages(front: UIImage?, back: UIImage?) {
        if !frontChanged {
            frontImage = front
        }
        if !backChanged {
            backImage = back
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
