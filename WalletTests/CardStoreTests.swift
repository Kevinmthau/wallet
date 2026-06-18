import XCTest
import UIKit
import CoreData
import CloudKit
@testable import Wallet

@MainActor
final class CardStoreTests: XCTestCase {
    private var persistence: PersistenceController!
    private var context: NSManagedObjectContext!
    private var store: CardStore!

    override func setUp() {
        super.setUp()
        persistence = PersistenceController(inMemory: true)
        context = persistence.container.viewContext
        store = CardStore(context: context)
    }

    override func tearDown() {
        store = nil
        context = nil
        persistence = nil
        super.tearDown()
    }

    func testAddCardStoresImagesAndMetadata() async throws {
        let front = makeImage(width: 3000, height: 1500, color: .blue)
        let back = makeImage(width: 1000, height: 600, color: .red)

        let success = await store.addCard(
            name: "Gym Membership",
            category: .membership,
            frontImage: front,
            backImage: back,
            notes: "Member #123"
        )

        XCTAssertTrue(success)
        let cards = try fetchCards()
        XCTAssertEqual(cards.count, 1)

        let card = try XCTUnwrap(cards.first)
        XCTAssertNotNil(card.id)
        XCTAssertEqual(card.name, "Gym Membership")
        XCTAssertEqual(card.category, .membership)
        XCTAssertEqual(card.notes, "Member #123")
        XCTAssertNotNil(card.createdAt)
        XCTAssertNotNil(card.lastAccessedAt)
        XCTAssertNotNil(card.updatedAt)
        XCTAssertNotNil(card.frontImageData)
        XCTAssertNotNil(card.backImageData)
        XCTAssertTrue(card.hasBack)

        let savedFrontData = try XCTUnwrap(card.frontImageData)
        let savedFrontImage = try XCTUnwrap(UIImage(data: savedFrontData))
        XCTAssertLessThanOrEqual(max(savedFrontImage.size.width, savedFrontImage.size.height), 3072.0)
        XCTAssertGreaterThan(max(savedFrontImage.size.width, savedFrontImage.size.height), 2048.0)
    }

    func testAddCardFailureDoesNotInsertPartialCard() async throws {
        let success = await store.addCard(
            name: "Broken Image",
            category: .membership,
            frontImage: UIImage()
        )

        XCTAssertFalse(success)
        XCTAssertTrue(try fetchCards().isEmpty)
        XCTAssertTrue(context.insertedObjects.isEmpty)
        XCTAssertFalse(context.hasChanges)

        guard case CardError.imageCompressionFailed = try XCTUnwrap(store.lastError as? CardError) else {
            return XCTFail("Expected image compression failure")
        }
    }

    func testDeleteByObjectIDIsNoopWhenCardIsAlreadyGone() throws {
        let card = try insertStoredCard(
            name: "Already Deleted",
            lastAccessedAt: Date(),
            updatedAt: Date()
        )
        let objectID = card.objectID

        context.delete(card)
        try context.save()

        XCTAssertTrue(store.delete(objectID: objectID))
        XCTAssertTrue(try fetchCards().isEmpty)
        XCTAssertNil(store.lastError)
    }

    func testUpdateCardFailsGracefullyWhenObjectIDNoLongerResolves() async throws {
        let card = try insertStoredCard(
            name: "Deleted Before Save",
            lastAccessedAt: Date(),
            updatedAt: Date()
        )

        context.delete(card)
        try context.save()

        let success = await store.updateCard(card, name: "Should Not Save")

        XCTAssertFalse(success)
        guard case CardError.cardNotFound = try XCTUnwrap(store.lastError as? CardError) else {
            return XCTFail("Expected missing card failure")
        }
    }

    func testImageStorageResizesToHigherQualityDimensionLimit() throws {
        let image = makeImage(width: 5000, height: 2500, color: .blue)

        let data = try CardImageProcessor.compressForStorage(image)
        let savedImage = try XCTUnwrap(UIImage(data: data))

        XCTAssertEqual(max(savedImage.size.width, savedImage.size.height), 3072.0, accuracy: 1.0)
        XCTAssertGreaterThan(max(savedImage.size.width, savedImage.size.height), 2048.0)
    }

    func testImageStorageProducesNonEmptyJPEGData() throws {
        let image = makeImage(width: 1800, height: 1200, color: .green)

        let data = try CardImageProcessor.compressForStorage(image)

        XCTAssertFalse(data.isEmpty)
        XCTAssertEqual(data.first, 0xFF)
        XCTAssertEqual(data.dropFirst().first, 0xD8)
        XCTAssertNotNil(UIImage(data: data))
    }

    func testFileImageImporterLoadsImageData() throws {
        let sourceImage = makeImage(width: 900, height: 600, color: .blue)
        let data = try XCTUnwrap(sourceImage.pngData())

        let importedImage = try CardFileImageImporter.image(from: data, filenameExtension: "png")

        XCTAssertEqual(importedImage.pixelSize.width, sourceImage.pixelSize.width, accuracy: 1)
        XCTAssertEqual(importedImage.pixelSize.height, sourceImage.pixelSize.height, accuracy: 1)
    }

    func testFileImageImporterLoadsImageFromFileURL() async throws {
        let sourceImage = makeImage(width: 900, height: 600, color: .blue)
        let data = try XCTUnwrap(sourceImage.pngData())
        let fileURL = makeTemporaryFileURL(filenameExtension: "png")
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let importedImage = try await CardFileImageImporter.image(fromFileAt: fileURL)

        XCTAssertEqual(importedImage.pixelSize.width, sourceImage.pixelSize.width, accuracy: 1)
        XCTAssertEqual(importedImage.pixelSize.height, sourceImage.pixelSize.height, accuracy: 1)
    }

    func testFileImportPresentationTracksSelectedTarget() {
        let state = CardImageState()

        state.showFileImporter(for: .back)

        XCTAssertTrue(state.showingFileImporter)
        XCTAssertEqual(state.fileImporterTarget, .back)
    }

    func testFileImportUpdatesImageState() async throws {
        let sourceImage = makeImage(width: 640, height: 400, color: .green)
        let data = try XCTUnwrap(sourceImage.pngData())
        let fileURL = makeTemporaryFileURL(filenameExtension: "png")
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let state = CardImageState(
            enhanceImageOperation: { image in image },
            extractTextOperation: { _ in OCRExtractionResult(texts: ["Imported card"]) }
        )

        state.loadAndEnhanceImage(fromFileAt: fileURL, for: .front, isEditMode: true)
        try await waitForEnhancement(toFinishIn: state)

        let importedImage = try XCTUnwrap(state.frontImage)
        XCTAssertEqual(importedImage.pixelSize.width, sourceImage.pixelSize.width, accuracy: 1)
        XCTAssertEqual(importedImage.pixelSize.height, sourceImage.pixelSize.height, accuracy: 1)
        XCTAssertTrue(state.frontChanged)
        XCTAssertEqual(state.frontOCRResult?.texts, ["Imported card"])
        XCTAssertNil(state.importErrorMessage)
    }

    func testFileImportCropsWhitespaceAroundImageContent() async throws {
        let cardRect = CGRect(x: 160, y: 180, width: 680, height: 360)
        let sourceImage = makeImageWithCardOnBackground(
            width: 1000,
            height: 700,
            cardRect: cardRect
        )
        let data = try XCTUnwrap(sourceImage.pngData())
        let fileURL = makeTemporaryFileURL(filenameExtension: "png")
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let state = CardImageState(
            enhanceImageOperation: { image in image },
            extractTextOperation: { _ in OCRExtractionResult(texts: []) }
        )

        state.loadAndEnhanceImage(fromFileAt: fileURL, for: .front, isEditMode: true)
        try await waitForEnhancement(toFinishIn: state)

        let importedImage = try XCTUnwrap(state.frontImage)
        XCTAssertLessThan(importedImage.pixelSize.width, sourceImage.pixelSize.width * 0.9)
        XCTAssertLessThan(importedImage.pixelSize.height, sourceImage.pixelSize.height * 0.75)
        XCTAssertEqual(
            importedImage.pixelSize.width / importedImage.pixelSize.height,
            cardRect.width / cardRect.height,
            accuracy: 0.3
        )
    }

    func testFileImportCropsOneAxisWhitespaceOnCardAspectImage() async throws {
        let cardRect = CGRect(x: 0, y: 100, width: 1000, height: 430)
        let sourceImage = makeImageWithCardOnBackground(
            width: 1000,
            height: 630,
            cardRect: cardRect
        )
        let data = try XCTUnwrap(sourceImage.pngData())
        let fileURL = makeTemporaryFileURL(filenameExtension: "png")
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let state = CardImageState(
            enhanceImageOperation: { image in image },
            extractTextOperation: { _ in OCRExtractionResult(texts: []) }
        )

        state.loadAndEnhanceImage(fromFileAt: fileURL, for: .front, isEditMode: true)
        try await waitForEnhancement(toFinishIn: state)

        let importedImage = try XCTUnwrap(state.frontImage)
        XCTAssertGreaterThan(importedImage.pixelSize.width, sourceImage.pixelSize.width * 0.95)
        XCTAssertLessThan(importedImage.pixelSize.height, sourceImage.pixelSize.height * 0.85)
    }

    func testFileImportDoesNotCropTightlyFramedCardToDenseFullWidthPanel() async throws {
        let panelRect = CGRect(x: 0, y: 40, width: 1000, height: 340)
        let sourceImage = makeImageWithCardOnBackground(
            width: 1000,
            height: 630,
            cardRect: panelRect,
            cardColor: .systemBlue,
            backgroundColor: .white
        )
        let data = try XCTUnwrap(sourceImage.pngData())
        let fileURL = makeTemporaryFileURL(filenameExtension: "png")
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let state = CardImageState(
            enhanceImageOperation: { image in image },
            extractTextOperation: { _ in OCRExtractionResult(texts: []) }
        )

        state.loadAndEnhanceImage(fromFileAt: fileURL, for: .front, isEditMode: true)
        try await waitForEnhancement(toFinishIn: state)

        let importedImage = try XCTUnwrap(state.frontImage)
        XCTAssertEqual(importedImage.pixelSize.width, sourceImage.pixelSize.width, accuracy: 1)
        XCTAssertEqual(importedImage.pixelSize.height, sourceImage.pixelSize.height, accuracy: 1)
    }

    func testFileImportDoesNotCropTightlyFramedCardToInnerBarcode() async throws {
        let sourceImage = makeTightlyFramedCardWithBarcode(width: 1000, height: 630)
        let data = try XCTUnwrap(sourceImage.pngData())
        let fileURL = makeTemporaryFileURL(filenameExtension: "png")
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let state = CardImageState(
            enhanceImageOperation: { image in image },
            extractTextOperation: { _ in OCRExtractionResult(texts: []) }
        )

        state.loadAndEnhanceImage(fromFileAt: fileURL, for: .front, isEditMode: true)
        try await waitForEnhancement(toFinishIn: state)

        let importedImage = try XCTUnwrap(state.frontImage)
        XCTAssertEqual(importedImage.pixelSize.width, sourceImage.pixelSize.width, accuracy: 1)
        XCTAssertEqual(importedImage.pixelSize.height, sourceImage.pixelSize.height, accuracy: 1)
    }

    func testFileImportDoesNotCropTightlyFramedCardToInnerSquareCode() async throws {
        let sourceImage = makeTightlyFramedCardWithSquareCode(width: 1000, height: 630)
        let data = try XCTUnwrap(sourceImage.pngData())
        let fileURL = makeTemporaryFileURL(filenameExtension: "png")
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let state = CardImageState(
            enhanceImageOperation: { image in image },
            extractTextOperation: { _ in OCRExtractionResult(texts: []) }
        )

        state.loadAndEnhanceImage(fromFileAt: fileURL, for: .front, isEditMode: true)
        try await waitForEnhancement(toFinishIn: state)

        let importedImage = try XCTUnwrap(state.frontImage)
        XCTAssertEqual(importedImage.pixelSize.width, sourceImage.pixelSize.width, accuracy: 1)
        XCTAssertEqual(importedImage.pixelSize.height, sourceImage.pixelSize.height, accuracy: 1)
    }

    func testFileImageImporterRendersPDFPage() throws {
        let data = makePDFData(width: 612, height: 792)

        let importedImage = try CardFileImageImporter.image(from: data, filenameExtension: "pdf")

        XCTAssertGreaterThan(importedImage.pixelSize.width, 0)
        XCTAssertGreaterThan(importedImage.pixelSize.height, 0)
        XCTAssertLessThanOrEqual(
            max(importedImage.pixelSize.width, importedImage.pixelSize.height),
            CardImageProcessor.maxStorageDimension
        )
    }

    func testPDFFileImportCropsWhitespaceAroundCardContent() async throws {
        let cardRect = CGRect(x: 56, y: 210, width: 500, height: 315)
        let data = makePDFDataWithCard(width: 612, height: 792, cardRect: cardRect)
        let fileURL = makeTemporaryFileURL(filenameExtension: "pdf")
        try data.write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let state = CardImageState(
            enhanceImageOperation: { image in image },
            extractTextOperation: { _ in OCRExtractionResult(texts: []) }
        )

        state.loadAndEnhanceImage(fromFileAt: fileURL, for: .front, isEditMode: true)
        try await waitForEnhancement(toFinishIn: state)

        let importedImage = try XCTUnwrap(state.frontImage)
        XCTAssertLessThan(importedImage.pixelSize.width, CardImageProcessor.maxStorageDimension * 0.9)
        XCTAssertLessThan(importedImage.pixelSize.height, CardImageProcessor.maxStorageDimension * 0.7)
        XCTAssertEqual(
            importedImage.pixelSize.width / importedImage.pixelSize.height,
            cardRect.width / cardRect.height,
            accuracy: 0.3
        )
    }

    func testImageRepositoryDownsamplesThumbnailAndDisplayVariants() async throws {
        let image = makeImage(width: 5000, height: 2500, color: .blue)
        let data = try CardImageProcessor.compressForStorage(image)
        let cacheIdentity = UUID().uuidString

        let loadedThumbnail = await CardImageRepository.shared.image(
            from: data,
            cacheIdentity: cacheIdentity,
            side: .front,
            variant: .thumbnail
        )
        let loadedDisplayImage = await CardImageRepository.shared.image(
            from: data,
            cacheIdentity: cacheIdentity,
            side: .front,
            variant: .display
        )
        let thumbnail = try XCTUnwrap(loadedThumbnail)
        let displayImage = try XCTUnwrap(loadedDisplayImage)

        XCTAssertLessThanOrEqual(
            max(thumbnail.pixelSize.width, thumbnail.pixelSize.height),
            Constants.CardLayout.listThumbnailMaxDimension
        )
        XCTAssertLessThanOrEqual(
            max(displayImage.pixelSize.width, displayImage.pixelSize.height),
            Constants.CardLayout.displayImageMaxDimension
        )
        XCTAssertGreaterThan(
            max(displayImage.pixelSize.width, displayImage.pixelSize.height),
            max(thumbnail.pixelSize.width, thumbnail.pixelSize.height)
        )
    }

    func testImageRepositoryReturnsCachedVariantForRepeatedRequest() async throws {
        let image = makeImage(width: 1200, height: 800, color: .green)
        let data = try CardImageProcessor.compressForStorage(image)
        let cacheIdentity = UUID().uuidString

        let loadedFirstImage = await CardImageRepository.shared.image(
            from: data,
            cacheIdentity: cacheIdentity,
            side: .front,
            variant: .thumbnail
        )
        let loadedSecondImage = await CardImageRepository.shared.image(
            from: data,
            cacheIdentity: cacheIdentity,
            side: .front,
            variant: .thumbnail
        )
        let firstImage = try XCTUnwrap(loadedFirstImage)
        let secondImage = try XCTUnwrap(loadedSecondImage)

        XCTAssertTrue(firstImage === secondImage)
    }

    func testImageRepositoryDoesNotCacheFullVariant() async throws {
        let image = makeImage(width: 1200, height: 800, color: .green)
        let data = try CardImageProcessor.compressForStorage(image)
        let cacheIdentity = UUID().uuidString

        let loadedFirstImage = await CardImageRepository.shared.image(
            from: data,
            cacheIdentity: cacheIdentity,
            side: .front,
            variant: .full
        )
        let loadedSecondImage = await CardImageRepository.shared.image(
            from: data,
            cacheIdentity: cacheIdentity,
            side: .front,
            variant: .full
        )
        let firstImage = try XCTUnwrap(loadedFirstImage)
        let secondImage = try XCTUnwrap(loadedSecondImage)

        XCTAssertFalse(firstImage === secondImage)
    }

    func testImageRepositoryInvalidatesCacheWhenDataChanges() async throws {
        let firstData = try CardImageProcessor.compressForStorage(
            makeImage(width: 1200, height: 800, color: .red)
        )
        let secondData = try CardImageProcessor.compressForStorage(
            makeImage(width: 1200, height: 800, color: .blue)
        )
        let cacheIdentity = UUID().uuidString

        let loadedFirstImage = await CardImageRepository.shared.image(
            from: firstData,
            cacheIdentity: cacheIdentity,
            side: .front,
            variant: .thumbnail
        )
        let loadedSecondImage = await CardImageRepository.shared.image(
            from: secondData,
            cacheIdentity: cacheIdentity,
            side: .front,
            variant: .thumbnail
        )
        let firstImage = try XCTUnwrap(loadedFirstImage)
        let secondImage = try XCTUnwrap(loadedSecondImage)

        XCTAssertFalse(firstImage === secondImage)
    }

    func testImageRepositoryLoadsObjectIDThumbnailFromPersistentStore() async throws {
        let data = try CardImageProcessor.compressForStorage(
            makeImage(width: 5000, height: 2500, color: .blue)
        )
        let timestamp = Date()
        let card = Card.insert(into: context)
        card.id = UUID()
        card.name = "Stored Image"
        card.category = .membership
        card.frontImageData = data
        card.hasBackImage = false
        card.isFavorite = false
        card.createdAt = timestamp
        card.lastAccessedAt = timestamp
        card.updatedAt = timestamp
        card.markAllMutableFieldsUpdated(at: timestamp)
        try context.save()

        let loadedImage = await CardImageRepository.shared.image(
            for: card.objectID,
            side: .front,
            variant: .thumbnail,
            in: context
        )
        let thumbnail = try XCTUnwrap(loadedImage)

        XCTAssertLessThanOrEqual(
            max(thumbnail.pixelSize.width, thumbnail.pixelSize.height),
            Constants.CardLayout.listThumbnailMaxDimension
        )
    }

    func testImageRepositoryObjectIDThumbnailInvalidatesWhenImageDataChanges() async throws {
        let firstData = try CardImageProcessor.compressForStorage(
            makeImage(width: 1200, height: 800, color: .red)
        )
        let secondData = try CardImageProcessor.compressForStorage(
            makeImage(width: 1200, height: 800, color: .blue)
        )
        let timestamp = Date()
        let card = Card.insert(into: context)
        card.id = UUID()
        card.name = "Changing Image"
        card.category = .membership
        card.frontImageData = firstData
        card.hasBackImage = false
        card.isFavorite = false
        card.createdAt = timestamp
        card.lastAccessedAt = timestamp
        card.updatedAt = timestamp
        card.markAllMutableFieldsUpdated(at: timestamp)
        try context.save()

        let loadedFirstImage = await CardImageRepository.shared.image(
            for: card.objectID,
            side: .front,
            variant: .thumbnail,
            in: context
        )

        let mutationDate = timestamp.addingTimeInterval(10)
        card.frontImageData = secondData
        card.markFieldUpdated(Card.Attributes.frontImageData, at: mutationDate)
        card.touchUpdatedAt(mutationDate)
        try context.save()

        let loadedSecondImage = await CardImageRepository.shared.image(
            for: card.objectID,
            side: .front,
            variant: .thumbnail,
            in: context
        )
        let firstImage = try XCTUnwrap(loadedFirstImage)
        let secondImage = try XCTUnwrap(loadedSecondImage)

        XCTAssertFalse(firstImage === secondImage)
    }

    func testImageLoadIdentifierChangesWhenImageVersionChanges() throws {
        let timestamp = Date(timeIntervalSince1970: 2_000)
        let card = Card.insert(into: context)
        card.id = UUID()
        card.name = "Versioned Image"
        card.category = .membership
        card.frontImageData = Data([0x01])
        card.hasBackImage = false
        card.isFavorite = false
        card.createdAt = timestamp
        card.lastAccessedAt = timestamp
        card.updatedAt = timestamp
        card.markAllMutableFieldsUpdated(at: timestamp)

        let firstIdentifier = CardImageRepository.shared.loadIdentifier(
            for: card,
            side: .front,
            variant: .display
        )

        card.frontImageData = Data([0x02])
        card.markFieldUpdated(Card.Attributes.frontImageData, at: timestamp.addingTimeInterval(10))

        let secondIdentifier = CardImageRepository.shared.loadIdentifier(
            for: card,
            side: .front,
            variant: .display
        )

        XCTAssertNotEqual(firstIdentifier, secondIdentifier)
        XCTAssertEqual(card.updatedAt, timestamp)
    }

    func testUpdateCardCanClearBackImage() async throws {
        let front = makeImage(width: 600, height: 400, color: .green)
        let back = makeImage(width: 600, height: 400, color: .yellow)

        let addSuccess = await store.addCard(
            name: "Library Card",
            category: .loyalty,
            frontImage: front,
            backImage: back
        )
        XCTAssertTrue(addSuccess)

        let card = try XCTUnwrap(fetchCards().first)
        XCTAssertNotNil(card.backImageData)
        XCTAssertTrue(card.hasBack)

        let updateSuccess = await store.updateCard(card, clearBackImage: true)
        XCTAssertTrue(updateSuccess)

        XCTAssertNil(card.backImageData)
        XCTAssertFalse(card.hasBack)
    }

    func testUpdateCardCanClearNotes() async throws {
        let addSuccess = await store.addCard(
            name: "Rewards Card",
            category: .loyalty,
            frontImage: makeImage(width: 600, height: 400, color: .purple),
            notes: "Member #123"
        )
        XCTAssertTrue(addSuccess)

        let card = try XCTUnwrap(fetchCards().first)
        XCTAssertEqual(card.notes, "Member #123")

        let updateSuccess = await store.updateCard(
            card,
            notes: nil,
            clearNotes: true
        )

        XCTAssertTrue(updateSuccess)
        XCTAssertNil(card.notes)
    }

    func testSetExistingImagesPreservesChangedSides() throws {
        let state = CardImageState()
        state.removeImage(for: .front, isEditMode: true)

        let existingFront = makeImage(width: 600, height: 400, color: .blue)
        let existingBack = makeImage(width: 600, height: 400, color: .red)
        state.setExistingImages(front: existingFront, back: existingBack)

        XCTAssertNil(state.frontImage)
        XCTAssertTrue(state.frontChanged)
        XCTAssertTrue(state.backImage === existingBack)
        XCTAssertFalse(state.backChanged)
    }

    func testEnhanceImageUsesProvidedSourceImage() async throws {
        let displayImage = makeImage(width: 300, height: 200, color: .blue)
        let fullImage = makeImage(width: 1800, height: 1200, color: .red)
        let state = CardImageState(frontImage: displayImage)

        state.enhanceImage(for: .front, isEditMode: true) {
            fullImage
        }
        try await waitForEnhancement(toFinishIn: state)

        let enhancedImage = try XCTUnwrap(state.frontImage)
        XCTAssertTrue(state.frontChanged)
        XCTAssertGreaterThan(
            max(enhancedImage.pixelSize.width, enhancedImage.pixelSize.height),
            max(displayImage.pixelSize.width, displayImage.pixelSize.height)
        )
    }

    func testImageEnhancementTasksAreTrackedPerSide() async throws {
        let frontImage = makeImage(width: 300, height: 200, color: .blue)
        let backImage = makeImage(width: 320, height: 220, color: .red)
        let state = CardImageState(
            frontImage: frontImage,
            backImage: backImage,
            enhanceDocumentImageOperation: { image in
                try? await Task.sleep(nanoseconds: 50_000_000)
                return image
            }
        )

        state.enhanceImage(for: .front, isEditMode: true)
        state.enhanceImage(for: .back, isEditMode: true)

        try await waitForEnhancement(toFinishIn: state)

        XCTAssertTrue(state.frontChanged)
        XCTAssertTrue(state.backChanged)
        XCTAssertEqual(state.frontImage?.pixelSize.width, frontImage.pixelSize.width)
        XCTAssertEqual(state.backImage?.pixelSize.width, backImage.pixelSize.width)
    }

    func testRemovingImageCancelsPendingEnhancementAndSuppressesLateResult() async throws {
        let scannedImage = makeImage(width: 300, height: 200, color: .blue)
        let state = CardImageState(
            enhanceImageOperation: { image in
                await Task.detached {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }.value
                return image
            }
        )

        state.scannerTarget = .front
        state.handleScanResult(
            ScanResult(
                image: scannedImage,
                extractedText: OCRExtractionResult(texts: ["Member 123"])
            ),
            isEditMode: true
        )
        XCTAssertTrue(state.isEnhancing)

        state.removeImage(for: .front, isEditMode: true)
        XCTAssertNil(state.frontImage)
        XCTAssertNil(state.frontOCRResult)

        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertNil(state.frontImage)
        XCTAssertNil(state.frontOCRResult)
        XCTAssertTrue(state.frontChanged)
        XCTAssertFalse(state.isEnhancing)
    }

    func testReplacingImageSuppressesOlderEnhancementResult() async throws {
        let originalImage = makeImage(width: 300, height: 200, color: .blue)
        let replacementImage = makeImage(width: 420, height: 260, color: .red)
        let state = CardImageState(
            enhanceImageOperation: { image in
                let delay: UInt64 = image.pixelSize.width == originalImage.pixelSize.width
                    ? 120_000_000
                    : 20_000_000
                await Task.detached {
                    try? await Task.sleep(nanoseconds: delay)
                }.value
                return image
            }
        )

        state.scannerTarget = .front
        state.handleScanResult(ScanResult(image: originalImage), isEditMode: true)
        state.handleScanResult(ScanResult(image: replacementImage), isEditMode: true)

        try await waitForEnhancement(toFinishIn: state)
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(state.frontImage?.pixelSize.width, replacementImage.pixelSize.width)
        XCTAssertTrue(state.frontChanged)
        XCTAssertFalse(state.isEnhancing)
    }

    func testMarkAccessedUpdatesLastAccessedWithoutChangingUpdatedAt() async throws {
        let addSuccess = await store.addCard(
            name: "Access Test",
            category: .membership,
            frontImage: makeImage(width: 600, height: 400, color: .orange)
        )
        XCTAssertTrue(addSuccess)

        let card = try XCTUnwrap(fetchCards().first)
        let originalAccessDate = Date(timeIntervalSince1970: 1_000)
        let originalUpdatedAt = Date(timeIntervalSince1970: 2_000)
        card.lastAccessedAt = originalAccessDate
        card.updatedAt = originalUpdatedAt
        try context.save()

        store.markAccessed(card)

        XCTAssertGreaterThan(try XCTUnwrap(card.lastAccessedAt), originalAccessDate)
        XCTAssertEqual(try XCTUnwrap(card.updatedAt), originalUpdatedAt)
        XCTAssertTrue(context.hasChanges)

        XCTAssertTrue(store.toggleFavorite(card))
        XCTAssertTrue(card.isFavorite)
        XCTAssertGreaterThan(try XCTUnwrap(card.lastAccessedAt), originalAccessDate)
        XCTAssertGreaterThan(try XCTUnwrap(card.updatedAt), originalUpdatedAt)
    }

    func testUpdateCardAdvancesUpdatedAtWithoutChangingLastAccessed() async throws {
        let addSuccess = await store.addCard(
            name: "Edit Test",
            category: .membership,
            frontImage: makeImage(width: 600, height: 400, color: .blue)
        )
        XCTAssertTrue(addSuccess)

        let card = try XCTUnwrap(fetchCards().first)
        let originalAccessDate = Date(timeIntervalSince1970: 1_000)
        let originalUpdatedAt = Date(timeIntervalSince1970: 2_000)
        card.lastAccessedAt = originalAccessDate
        card.updatedAt = originalUpdatedAt
        try context.save()

        let updateSuccess = await store.updateCard(card, name: "Edited Test")

        XCTAssertTrue(updateSuccess)
        XCTAssertEqual(card.name, "Edited Test")
        XCTAssertEqual(try XCTUnwrap(card.lastAccessedAt), originalAccessDate)
        XCTAssertGreaterThan(try XCTUnwrap(card.updatedAt), originalUpdatedAt)
    }

    func testRecentlyUsedSortReflectsAccessWithoutChangingUpdatedAt() throws {
        let accessedCard = try insertStoredCard(
            name: "Older Access",
            lastAccessedAt: Date(timeIntervalSince1970: 1_000),
            updatedAt: Date(timeIntervalSince1970: 3_000)
        )
        let previouslyRecentCard = try insertStoredCard(
            name: "Recent Access",
            lastAccessedAt: Date(timeIntervalSince1970: 2_000),
            updatedAt: Date(timeIntervalSince1970: 4_000)
        )
        let originalUpdatedAt = try XCTUnwrap(accessedCard.updatedAt)

        store.markAccessed(accessedCard)

        let sortedCards = try fetchCardsSortedByLastAccessed()
        XCTAssertEqual(sortedCards.first?.objectID, accessedCard.objectID)
        XCTAssertEqual(sortedCards.dropFirst().first?.objectID, previouslyRecentCard.objectID)
        XCTAssertEqual(try XCTUnwrap(accessedCard.updatedAt), originalUpdatedAt)

        XCTAssertTrue(store.toggleFavorite(accessedCard))
    }

    func testBackfillsMissingIDsAndUpdatedAtOnInit() throws {
        let originalAccessDate = Date().addingTimeInterval(-120)
        let card = Card.insert(into: context)
        card.id = nil
        card.name = "Legacy Card"
        card.category = .other
        card.hasBackImage = false
        card.isFavorite = false
        card.createdAt = Date().addingTimeInterval(-3600)
        card.lastAccessedAt = originalAccessDate
        card.updatedAt = nil

        try context.save()

        let freshStore = CardStore(context: context)
        _ = freshStore
        let refreshedCard = try XCTUnwrap(fetchCards().first(where: { $0.name == "Legacy Card" }))
        XCTAssertNotNil(refreshedCard.id)
        XCTAssertEqual(try XCTUnwrap(refreshedCard.updatedAt), originalAccessDate)
        XCTAssertEqual(try XCTUnwrap(refreshedCard.nameUpdatedAt), originalAccessDate)
        XCTAssertEqual(try XCTUnwrap(refreshedCard.frontImageUpdatedAt), originalAccessDate)
    }

    func testBackfillsBackImagePresenceOnInit() throws {
        let timestamp = Date()
        let cardWithBack = try insertStoredCard(
            name: "Legacy Back",
            lastAccessedAt: timestamp,
            updatedAt: timestamp
        )
        cardWithBack.backImageData = Data([0x01])
        cardWithBack.hasBackImage = false

        let cardWithoutBack = try insertStoredCard(
            name: "Stale Back Flag",
            lastAccessedAt: timestamp,
            updatedAt: timestamp
        )
        cardWithoutBack.hasBackImage = true

        try context.save()

        let freshStore = CardStore(context: context)
        _ = freshStore

        XCTAssertTrue(cardWithBack.hasBack)
        XCTAssertFalse(cardWithoutBack.hasBack)
    }

    func testRemoteChangeRepairsImportedBackImagePresence() async throws {
        let timestamp = Date()
        let card = try insertStoredCard(
            name: "Imported Legacy Back",
            lastAccessedAt: timestamp,
            updatedAt: timestamp
        )
        card.backImageData = Data([0x01])
        card.hasBackImage = false
        try context.save()

        XCTAssertFalse(card.hasBack)

        let coordinator = try XCTUnwrap(context.persistentStoreCoordinator)
        NotificationCenter.default.post(name: .NSPersistentStoreRemoteChange, object: coordinator)

        for _ in 0..<10 where !card.hasBack {
            await Task.yield()
        }

        XCTAssertTrue(card.hasBack)
    }

    func testInMemoryPersistenceDisablesCloudKit() {
        XCTAssertNil(persistence.container.persistentStoreDescriptions.first?.cloudKitContainerOptions)
    }

    func testPersistentStoreLoadFailureIsObservable() async throws {
        let blockedParentURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: false)
        XCTAssertTrue(FileManager.default.createFile(atPath: blockedParentURL.path, contents: Data()))
        defer { try? FileManager.default.removeItem(at: blockedParentURL) }
        let storeURL = blockedParentURL.appendingPathComponent("Wallet.sqlite")
        let failingPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)

        for _ in 0..<50 where !failingPersistence.loadState.didFinishLoading {
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        XCTAssertTrue(failingPersistence.loadState.didFinishLoading)
        let failure = try XCTUnwrap(failingPersistence.loadState.loadFailure)
        XCTAssertFalse(failure.underlyingDescription.isEmpty)
        XCTAssertNotNil(failure.errorDescription)
        XCTAssertNotNil(failure.recoverySuggestion)
    }

    func testSyncStatusBannerWarningOnlyShowsFailures() {
        XCTAssertNil(SyncStatusBanner.warning(for: .unknown))
        XCTAssertNil(SyncStatusBanner.warning(for: .signedIn))
        XCTAssertNil(SyncStatusBanner.warning(for: .syncing))
        XCTAssertNil(SyncStatusBanner.warning(for: .upToDate))
        XCTAssertEqual(
            SyncStatusBanner.warning(for: .accountUnavailable("Sign in to iCloud.")),
            "Sign in to iCloud."
        )
        XCTAssertEqual(
            SyncStatusBanner.warning(for: .failed("iCloud sync failed.")),
            "iCloud sync failed."
        )
    }

    func testEmptyWalletSyncStatusShowsSignedInProgressFailuresAndLastEvent() throws {
        let signedIn = try XCTUnwrap(SyncStatusBanner.emptyWalletStatus(
            for: .signedIn,
            lastEvent: nil
        ))
        XCTAssertEqual(signedIn.message, "Signed in to iCloud. Waiting for cards to sync.")
        XCTAssertEqual(signedIn.style, .information)

        let startedImport = CloudKitSyncMonitor.LastEvent(
            direction: .importChanges,
            outcome: .started,
            date: Date(timeIntervalSinceReferenceDate: 0),
            message: "Importing cards from iCloud."
        )
        let syncing = try XCTUnwrap(SyncStatusBanner.emptyWalletStatus(
            for: .syncing,
            lastEvent: startedImport
        ))
        XCTAssertEqual(syncing.message, "Importing cards from iCloud.")
        XCTAssertEqual(syncing.style, .progress)

        let failed = try XCTUnwrap(SyncStatusBanner.emptyWalletStatus(
            for: .failed("iCloud sync failed."),
            lastEvent: nil
        ))
        XCTAssertEqual(failed.message, "iCloud sync failed.")
        XCTAssertEqual(failed.style, .warning)

        let completedImport = CloudKitSyncMonitor.LastEvent(
            direction: .importChanges,
            outcome: .succeeded,
            date: Date(timeIntervalSinceReferenceDate: 1),
            message: "Imported latest changes from iCloud."
        )
        let upToDate = try XCTUnwrap(SyncStatusBanner.emptyWalletStatus(
            for: .upToDate,
            lastEvent: completedImport
        ))
        XCTAssertEqual(upToDate.message, "Imported latest changes from iCloud.")
        XCTAssertEqual(upToDate.style, .success)
    }

    func testCloudKitPartialFailureMessageShowsNestedServerDescription() {
        let nestedError = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.serverRejectedRequest.rawValue,
            userInfo: [
                "CKErrorServerDescription": "Field 'CD_hasBackImage' is not defined in production schema."
            ]
        )
        let partialError = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.partialFailure.rawValue,
            userInfo: [
                CKPartialErrorsByItemIDKey: [
                    "record-id": nestedError
                ]
            ]
        )

        XCTAssertEqual(
            CloudKitSyncMonitor.failureMessage(for: partialError),
            "iCloud sync failed: 1 CloudKit item failed: Field 'CD_hasBackImage' is not defined in production schema."
        )
    }

    func testCloudKitRequestRateLimitedMessageShowsRetryDelay() {
        let error = NSError(
            domain: CKErrorDomain,
            code: CKError.Code.requestRateLimited.rawValue,
            userInfo: [
                CKErrorRetryAfterKey: NSNumber(value: 12.4)
            ]
        )

        XCTAssertEqual(
            CloudKitSyncMonitor.failureMessage(for: error),
            "iCloud sync failed: iCloud asked Wallet to retry in 12 seconds."
        )
    }

    func testTimestampMergePolicyPrefersNewerStoreVersion() throws {
        let storeURL = makeTemporaryStoreURL()
        do {
            let seedingPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let objectURI = try seedConflictTestCard(in: seedingPersistence.container.viewContext)
                .uriRepresentation()

            let newerPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let olderPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let verificationPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let newerObjectID = try resolveObjectID(from: objectURI, in: newerPersistence)
            let olderObjectID = try resolveObjectID(from: objectURI, in: olderPersistence)
            let verificationObjectID = try resolveObjectID(from: objectURI, in: verificationPersistence)
            let newerContext = newerPersistence.makeBackgroundContext()
            let olderContext = olderPersistence.makeBackgroundContext()
            let newerTimestamp = Date().addingTimeInterval(20)
            let olderTimestamp = Date().addingTimeInterval(10)

            try performAndWait(in: newerContext) {
                let card = try XCTUnwrap(try newerContext.existingObject(with: newerObjectID) as? Card)
                card.name = "Store Wins"
                card.updatedAt = newerTimestamp
                card.markFieldUpdated(Card.Attributes.name, at: newerTimestamp)
            }

            try performAndWait(in: olderContext) {
                let card = try XCTUnwrap(try olderContext.existingObject(with: olderObjectID) as? Card)
                card.name = "Stale Update"
                card.updatedAt = olderTimestamp
                card.markFieldUpdated(Card.Attributes.name, at: olderTimestamp)
            }

            try performAndWait(in: newerContext) {
                try newerContext.save()
            }

            try performAndWait(in: olderContext) {
                try olderContext.save()
            }

            let verificationContext = verificationPersistence.makeBackgroundContext()
            try performAndWait(in: verificationContext) {
                let card = try XCTUnwrap(try verificationContext.existingObject(with: verificationObjectID) as? Card)
                XCTAssertEqual(card.name, "Store Wins")
                XCTAssertEqual(try XCTUnwrap(card.updatedAt), newerTimestamp)
            }
        }
    }

    func testTimestampMergePolicyPrefersNewerLocalVersion() throws {
        let storeURL = makeTemporaryStoreURL()
        do {
            let seedingPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let objectURI = try seedConflictTestCard(in: seedingPersistence.container.viewContext)
                .uriRepresentation()

            let olderPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let newerPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let verificationPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let olderObjectID = try resolveObjectID(from: objectURI, in: olderPersistence)
            let newerObjectID = try resolveObjectID(from: objectURI, in: newerPersistence)
            let verificationObjectID = try resolveObjectID(from: objectURI, in: verificationPersistence)
            let olderContext = olderPersistence.makeBackgroundContext()
            let newerContext = newerPersistence.makeBackgroundContext()
            let olderTimestamp = Date().addingTimeInterval(10)
            let newerTimestamp = Date().addingTimeInterval(20)

            try performAndWait(in: olderContext) {
                let card = try XCTUnwrap(try olderContext.existingObject(with: olderObjectID) as? Card)
                card.name = "Older Update"
                card.updatedAt = olderTimestamp
                card.markFieldUpdated(Card.Attributes.name, at: olderTimestamp)
            }

            try performAndWait(in: newerContext) {
                let card = try XCTUnwrap(try newerContext.existingObject(with: newerObjectID) as? Card)
                card.name = "Local Wins"
                card.updatedAt = newerTimestamp
                card.markFieldUpdated(Card.Attributes.name, at: newerTimestamp)
            }

            try performAndWait(in: olderContext) {
                try olderContext.save()
            }

            try performAndWait(in: newerContext) {
                try newerContext.save()
            }

            let verificationContext = verificationPersistence.makeBackgroundContext()
            try performAndWait(in: verificationContext) {
                let card = try XCTUnwrap(try verificationContext.existingObject(with: verificationObjectID) as? Card)
                XCTAssertEqual(card.name, "Local Wins")
                XCTAssertEqual(try XCTUnwrap(card.updatedAt), newerTimestamp)
            }
        }
    }

    func testTimestampMergePolicyKeepsNewestAccessWhenEditTimestampTies() throws {
        let storeURL = makeTemporaryStoreURL()
        do {
            let editTimestamp = Date(timeIntervalSince1970: 10_000)
            let seedingPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let objectURI = try seedConflictTestCard(
                in: seedingPersistence.container.viewContext,
                timestamp: editTimestamp
            )
            .uriRepresentation()

            let firstAccessPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let secondAccessPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let verificationPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let firstAccessObjectID = try resolveObjectID(from: objectURI, in: firstAccessPersistence)
            let secondAccessObjectID = try resolveObjectID(from: objectURI, in: secondAccessPersistence)
            let verificationObjectID = try resolveObjectID(from: objectURI, in: verificationPersistence)
            let firstAccessContext = firstAccessPersistence.makeBackgroundContext()
            let secondAccessContext = secondAccessPersistence.makeBackgroundContext()
            let firstAccessTimestamp = editTimestamp.addingTimeInterval(10)
            let secondAccessTimestamp = editTimestamp.addingTimeInterval(20)

            try performAndWait(in: firstAccessContext) {
                let card = try XCTUnwrap(try firstAccessContext.existingObject(with: firstAccessObjectID) as? Card)
                card.updateLastAccessed(at: firstAccessTimestamp)
            }

            try performAndWait(in: secondAccessContext) {
                let card = try XCTUnwrap(try secondAccessContext.existingObject(with: secondAccessObjectID) as? Card)
                card.updateLastAccessed(at: secondAccessTimestamp)
            }

            try performAndWait(in: firstAccessContext) {
                try firstAccessContext.save()
            }

            try performAndWait(in: secondAccessContext) {
                try secondAccessContext.save()
            }

            let verificationContext = verificationPersistence.makeBackgroundContext()
            try performAndWait(in: verificationContext) {
                let card = try XCTUnwrap(try verificationContext.existingObject(with: verificationObjectID) as? Card)
                XCTAssertEqual(try XCTUnwrap(card.lastAccessedAt), secondAccessTimestamp)
                XCTAssertEqual(try XCTUnwrap(card.updatedAt), editTimestamp)
            }
        }
    }

    func testMergePolicyPreservesNonOverlappingConcurrentEdits() throws {
        let storeURL = makeTemporaryStoreURL()
        do {
            let seedingPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let objectURI = try seedConflictTestCard(in: seedingPersistence.container.viewContext)
                .uriRepresentation()

            let notesPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let favoritePersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let verificationPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let notesObjectID = try resolveObjectID(from: objectURI, in: notesPersistence)
            let favoriteObjectID = try resolveObjectID(from: objectURI, in: favoritePersistence)
            let verificationObjectID = try resolveObjectID(from: objectURI, in: verificationPersistence)
            let notesContext = notesPersistence.makeBackgroundContext()
            let favoriteContext = favoritePersistence.makeBackgroundContext()
            let notesTimestamp = Date().addingTimeInterval(10)
            let favoriteTimestamp = Date().addingTimeInterval(20)

            try performAndWait(in: notesContext) {
                let card = try XCTUnwrap(try notesContext.existingObject(with: notesObjectID) as? Card)
                card.notes = "Synced notes"
                card.updatedAt = notesTimestamp
                card.markFieldUpdated(Card.Attributes.notes, at: notesTimestamp)
            }

            try performAndWait(in: favoriteContext) {
                let card = try XCTUnwrap(try favoriteContext.existingObject(with: favoriteObjectID) as? Card)
                card.isFavorite = true
                card.updatedAt = favoriteTimestamp
                card.markFieldUpdated(Card.Attributes.isFavorite, at: favoriteTimestamp)
            }

            try performAndWait(in: notesContext) {
                try notesContext.save()
            }

            try performAndWait(in: favoriteContext) {
                try favoriteContext.save()
            }

            let verificationContext = verificationPersistence.makeBackgroundContext()
            try performAndWait(in: verificationContext) {
                let card = try XCTUnwrap(try verificationContext.existingObject(with: verificationObjectID) as? Card)
                XCTAssertEqual(card.notes, "Synced notes")
                XCTAssertTrue(card.isFavorite)
                XCTAssertEqual(try XCTUnwrap(card.updatedAt), favoriteTimestamp)
            }
        }
    }

    func testMergePolicyUsesFieldVersionsAfterNonOverlappingMerge() throws {
        let storeURL = makeTemporaryStoreURL()
        do {
            let baseTimestamp = Date(timeIntervalSince1970: 10_000)
            let firstNotesTimestamp = baseTimestamp.addingTimeInterval(20)
            let laterNotesTimestamp = baseTimestamp.addingTimeInterval(25)
            let favoriteTimestamp = baseTimestamp.addingTimeInterval(30)
            let seedingPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let objectURI = try seedConflictTestCard(
                in: seedingPersistence.container.viewContext,
                timestamp: baseTimestamp
            )
            .uriRepresentation()

            let firstNotesPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let favoritePersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let laterNotesPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let verificationPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let firstNotesObjectID = try resolveObjectID(from: objectURI, in: firstNotesPersistence)
            let favoriteObjectID = try resolveObjectID(from: objectURI, in: favoritePersistence)
            let laterNotesObjectID = try resolveObjectID(from: objectURI, in: laterNotesPersistence)
            let verificationObjectID = try resolveObjectID(from: objectURI, in: verificationPersistence)
            let firstNotesContext = firstNotesPersistence.makeBackgroundContext()
            let favoriteContext = favoritePersistence.makeBackgroundContext()
            let laterNotesContext = laterNotesPersistence.makeBackgroundContext()

            try performAndWait(in: firstNotesContext) {
                let card = try XCTUnwrap(try firstNotesContext.existingObject(with: firstNotesObjectID) as? Card)
                card.notes = "First notes"
                card.updatedAt = firstNotesTimestamp
                card.markFieldUpdated(Card.Attributes.notes, at: firstNotesTimestamp)
            }

            try performAndWait(in: favoriteContext) {
                let card = try XCTUnwrap(try favoriteContext.existingObject(with: favoriteObjectID) as? Card)
                card.isFavorite = true
                card.updatedAt = favoriteTimestamp
                card.markFieldUpdated(Card.Attributes.isFavorite, at: favoriteTimestamp)
            }

            try performAndWait(in: laterNotesContext) {
                let card = try XCTUnwrap(try laterNotesContext.existingObject(with: laterNotesObjectID) as? Card)
                card.notes = "Later notes"
                card.updatedAt = laterNotesTimestamp
                card.markFieldUpdated(Card.Attributes.notes, at: laterNotesTimestamp)
            }

            try performAndWait(in: firstNotesContext) {
                try firstNotesContext.save()
            }

            try performAndWait(in: favoriteContext) {
                try favoriteContext.save()
            }

            try performAndWait(in: laterNotesContext) {
                try laterNotesContext.save()
            }

            let verificationContext = verificationPersistence.makeBackgroundContext()
            try performAndWait(in: verificationContext) {
                let card = try XCTUnwrap(try verificationContext.existingObject(with: verificationObjectID) as? Card)
                XCTAssertEqual(card.notes, "Later notes")
                XCTAssertTrue(card.isFavorite)
                XCTAssertEqual(try XCTUnwrap(card.updatedAt), favoriteTimestamp)
                XCTAssertEqual(try XCTUnwrap(card.notesUpdatedAt), laterNotesTimestamp)
                XCTAssertEqual(try XCTUnwrap(card.isFavoriteUpdatedAt), favoriteTimestamp)
            }
        }
    }

    func testMergePolicyPreservesIndependentFrontAndBackImageEdits() throws {
        let storeURL = makeTemporaryStoreURL()
        do {
            let seedingPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let objectURI = try seedConflictTestCard(
                in: seedingPersistence.container.viewContext,
                frontImageData: Data([0x01]),
                backImageData: Data([0x02])
            )
            .uriRepresentation()

            let frontPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let backPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let verificationPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let frontObjectID = try resolveObjectID(from: objectURI, in: frontPersistence)
            let backObjectID = try resolveObjectID(from: objectURI, in: backPersistence)
            let verificationObjectID = try resolveObjectID(from: objectURI, in: verificationPersistence)
            let frontContext = frontPersistence.makeBackgroundContext()
            let backContext = backPersistence.makeBackgroundContext()
            let frontTimestamp = Date().addingTimeInterval(10)
            let backTimestamp = Date().addingTimeInterval(20)

            try performAndWait(in: frontContext) {
                let card = try XCTUnwrap(try frontContext.existingObject(with: frontObjectID) as? Card)
                card.frontImageData = Data([0x03])
                card.updatedAt = frontTimestamp
                card.markFieldUpdated(Card.Attributes.frontImageData, at: frontTimestamp)
            }

            try performAndWait(in: backContext) {
                let card = try XCTUnwrap(try backContext.existingObject(with: backObjectID) as? Card)
                card.backImageData = Data([0x04])
                card.updatedAt = backTimestamp
                card.markFieldUpdated(Card.Attributes.backImageData, at: backTimestamp)
            }

            try performAndWait(in: frontContext) {
                try frontContext.save()
            }

            try performAndWait(in: backContext) {
                try backContext.save()
            }

            let verificationContext = verificationPersistence.makeBackgroundContext()
            try performAndWait(in: verificationContext) {
                let card = try XCTUnwrap(try verificationContext.existingObject(with: verificationObjectID) as? Card)
                XCTAssertEqual(card.frontImageData, Data([0x03]))
                XCTAssertEqual(card.backImageData, Data([0x04]))
                XCTAssertTrue(card.hasBack)
                XCTAssertEqual(try XCTUnwrap(card.updatedAt), backTimestamp)
            }
        }
    }

    func testMergePolicyKeepsImagePairFromWinnerWhenSameSideImageConflicts() throws {
        let storeURL = makeTemporaryStoreURL()
        do {
            let seedingPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let objectURI = try seedConflictTestCard(
                in: seedingPersistence.container.viewContext,
                frontImageData: Data([0x01]),
                backImageData: Data([0x02])
            )
            .uriRepresentation()

            let storeImagePersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let localImagePersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let verificationPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let storeImageObjectID = try resolveObjectID(from: objectURI, in: storeImagePersistence)
            let localImageObjectID = try resolveObjectID(from: objectURI, in: localImagePersistence)
            let verificationObjectID = try resolveObjectID(from: objectURI, in: verificationPersistence)
            let storeImageContext = storeImagePersistence.makeBackgroundContext()
            let localImageContext = localImagePersistence.makeBackgroundContext()
            let storeImageTimestamp = Date().addingTimeInterval(10)
            let localImageTimestamp = Date().addingTimeInterval(20)

            try performAndWait(in: storeImageContext) {
                let card = try XCTUnwrap(try storeImageContext.existingObject(with: storeImageObjectID) as? Card)
                card.frontImageData = Data([0x03])
                card.backImageData = Data([0x04])
                card.updatedAt = storeImageTimestamp
                card.markFieldUpdated(Card.Attributes.frontImageData, at: storeImageTimestamp)
                card.markFieldUpdated(Card.Attributes.backImageData, at: storeImageTimestamp)
            }

            try performAndWait(in: localImageContext) {
                let card = try XCTUnwrap(try localImageContext.existingObject(with: localImageObjectID) as? Card)
                card.frontImageData = Data([0x05])
                card.updatedAt = localImageTimestamp
                card.markFieldUpdated(Card.Attributes.frontImageData, at: localImageTimestamp)
            }

            try performAndWait(in: storeImageContext) {
                try storeImageContext.save()
            }

            try performAndWait(in: localImageContext) {
                try localImageContext.save()
            }

            let verificationContext = verificationPersistence.makeBackgroundContext()
            try performAndWait(in: verificationContext) {
                let card = try XCTUnwrap(try verificationContext.existingObject(with: verificationObjectID) as? Card)
                XCTAssertEqual(card.frontImageData, Data([0x05]))
                XCTAssertEqual(card.backImageData, Data([0x02]))
                XCTAssertTrue(card.hasBack)
                XCTAssertEqual(try XCTUnwrap(card.updatedAt), localImageTimestamp)
            }
        }
    }

    func testMergePolicyPreservesNewerNonConflictingImageEditDuringSameSideConflict() throws {
        let storeURL = makeTemporaryStoreURL()
        do {
            let seedingPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let objectURI = try seedConflictTestCard(
                in: seedingPersistence.container.viewContext,
                frontImageData: Data([0x01]),
                backImageData: Data([0x02])
            )
            .uriRepresentation()

            let storeImagePersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let localImagePersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let verificationPersistence = PersistenceController(storeURL: storeURL, cloudKitEnabled: false)
            let storeImageObjectID = try resolveObjectID(from: objectURI, in: storeImagePersistence)
            let localImageObjectID = try resolveObjectID(from: objectURI, in: localImagePersistence)
            let verificationObjectID = try resolveObjectID(from: objectURI, in: verificationPersistence)
            let storeImageContext = storeImagePersistence.makeBackgroundContext()
            let localImageContext = localImagePersistence.makeBackgroundContext()
            let storeFrontTimestamp = Date().addingTimeInterval(10)
            let localFrontTimestamp = Date().addingTimeInterval(50)
            let storeBackTimestamp = Date().addingTimeInterval(100)

            try performAndWait(in: localImageContext) {
                let card = try XCTUnwrap(try localImageContext.existingObject(with: localImageObjectID) as? Card)
                card.frontImageData = Data([0x05])
                card.updatedAt = localFrontTimestamp
                card.markFieldUpdated(Card.Attributes.frontImageData, at: localFrontTimestamp)
            }

            try performAndWait(in: storeImageContext) {
                let card = try XCTUnwrap(try storeImageContext.existingObject(with: storeImageObjectID) as? Card)
                card.frontImageData = Data([0x03])
                card.updatedAt = storeFrontTimestamp
                card.markFieldUpdated(Card.Attributes.frontImageData, at: storeFrontTimestamp)
                try storeImageContext.save()

                card.backImageData = nil
                card.updatedAt = storeBackTimestamp
                card.markFieldUpdated(Card.Attributes.backImageData, at: storeBackTimestamp)
                try storeImageContext.save()
            }

            try performAndWait(in: localImageContext) {
                try localImageContext.save()
            }

            let verificationContext = verificationPersistence.makeBackgroundContext()
            try performAndWait(in: verificationContext) {
                let card = try XCTUnwrap(try verificationContext.existingObject(with: verificationObjectID) as? Card)
                XCTAssertEqual(card.frontImageData, Data([0x05]))
                XCTAssertNil(card.backImageData)
                XCTAssertFalse(card.hasBack)
                XCTAssertEqual(try XCTUnwrap(card.updatedAt), storeBackTimestamp)
                XCTAssertEqual(try XCTUnwrap(card.frontImageUpdatedAt), localFrontTimestamp)
                XCTAssertEqual(try XCTUnwrap(card.backImageUpdatedAt), storeBackTimestamp)
            }
        }
    }

    func testCardStackLayoutUsesPreferredSpacingWhenContentFits() {
        let layout = CardStackLayout(
            cardCount: 4,
            cardHeight: 200,
            preferredSpacing: 70,
            availableHeight: 500
        )

        XCTAssertEqual(layout.offset(for: 0), 0, accuracy: 0.001)
        XCTAssertEqual(layout.offset(for: 1), 70, accuracy: 0.001)
        XCTAssertEqual(layout.offset(for: 2), 140, accuracy: 0.001)
        XCTAssertEqual(layout.offset(for: 3), 210, accuracy: 0.001)
        XCTAssertEqual(layout.visibleHeight(for: 0), 70, accuracy: 0.001)
        XCTAssertEqual(layout.visibleHeight(for: 1), 70, accuracy: 0.001)
        XCTAssertEqual(layout.visibleHeight(for: 2), 70, accuracy: 0.001)
        XCTAssertEqual(layout.visibleHeight(for: 3), 200, accuracy: 0.001)
        XCTAssertEqual(layout.contentHeight, 410, accuracy: 0.001)
    }

    func testCardStackLayoutCompressesLowerCardsWhenViewportIsTight() {
        let layout = CardStackLayout(
            cardCount: 8,
            cardHeight: 200,
            preferredSpacing: 70,
            availableHeight: 520
        )

        XCTAssertEqual(layout.offset(for: 0), 0, accuracy: 0.001)
        XCTAssertEqual(layout.offset(for: 7), 320, accuracy: 0.001)
        XCTAssertGreaterThan(layout.visibleHeight(for: 0), layout.visibleHeight(for: 6))
        XCTAssertLessThan(layout.visibleHeight(for: 6), 70)
        XCTAssertLessThanOrEqual(layout.contentHeight, 520.001)

        for index in 0..<7 {
            XCTAssertGreaterThan(layout.offset(for: index + 1), layout.offset(for: index))
        }
    }

    func testCardStackItemLoadsThumbnailsOnlyWhenMeaningfullyVisible() {
        XCTAssertTrue(CardStackItem.shouldLoadThumbnail(isFrontCard: true, visibleHeight: 1))
        XCTAssertTrue(CardStackItem.shouldLoadThumbnail(
            isFrontCard: false,
            visibleHeight: Constants.CardLayout.minimumThumbnailVisibleHeight
        ))
        XCTAssertFalse(CardStackItem.shouldLoadThumbnail(
            isFrontCard: false,
            visibleHeight: Constants.CardLayout.minimumThumbnailVisibleHeight - 1
        ))
    }

    func testCardListFetchPredicateCombinesCategoryAndSearch() throws {
        let matchingCard = try insertStoredCard(
            name: "Library",
            lastAccessedAt: Date(),
            updatedAt: Date(),
            category: .loyalty,
            notes: "Member 123"
        )
        _ = try insertStoredCard(
            name: "Library",
            lastAccessedAt: Date(),
            updatedAt: Date(),
            category: .membership,
            notes: "Member 123"
        )
        _ = try insertStoredCard(
            name: "Museum",
            lastAccessedAt: Date(),
            updatedAt: Date(),
            category: .loyalty,
            notes: "No match"
        )

        let request = Card.makeFetchRequest()
        request.predicate = CardListView.makeFetchPredicate(
            filter: .category,
            category: .loyalty,
            searchText: " member 123 "
        )
        request.sortDescriptors = [NSSortDescriptor(key: Card.Attributes.name, ascending: true)]

        let results = try context.fetch(request)
        XCTAssertEqual(results.map(\.objectID), [matchingCard.objectID])
    }

    func testCardListFetchPredicateTreatsWhitespaceSearchAsEmpty() throws {
        let favoriteCard = try insertStoredCard(
            name: "Favorite",
            lastAccessedAt: Date(),
            updatedAt: Date(),
            isFavorite: true
        )
        _ = try insertStoredCard(
            name: "Other",
            lastAccessedAt: Date(),
            updatedAt: Date(),
            isFavorite: false
        )

        let request = Card.makeFetchRequest()
        request.predicate = CardListView.makeFetchPredicate(
            filter: .favorites,
            category: .membership,
            searchText: "   "
        )

        let results = try context.fetch(request)
        XCTAssertEqual(results.map(\.objectID), [favoriteCard.objectID])
    }

    func testPreferredCardRectanglePicksCardOutlineOverHighContrastInnerPanel() {
        // Mirrors a card photographed on a textured background: Vision ranks the
        // bold inner panel first by confidence, but the card outline should win.
        let imagePixelSize = CGSize(width: 1000, height: 665)
        let innerPanel = CGRect(x: 0.15, y: 0.30, width: 0.70, height: 0.39)
        let cardOutline = CGRect(x: 0.06, y: 0.08, width: 0.88, height: 0.835)

        let selectedIndex = CardImageProcessor.preferredCardRectangleIndex(
            boundingBoxes: [innerPanel, cardOutline],
            imagePixelSize: imagePixelSize
        )

        XCTAssertEqual(selectedIndex, 1)
    }

    func testPreferredCardRectanglePrefersLargerCardOutlineAmongCandidates() {
        let imagePixelSize = CGSize(width: 1000, height: 665)
        let smallerCardAspect = CGRect(x: 0.25, y: 0.25, width: 0.45, height: 0.427)
        let largerCardAspect = CGRect(x: 0.06, y: 0.08, width: 0.88, height: 0.835)

        let selectedIndex = CardImageProcessor.preferredCardRectangleIndex(
            boundingBoxes: [smallerCardAspect, largerCardAspect],
            imagePixelSize: imagePixelSize
        )

        XCTAssertEqual(selectedIndex, 1)
    }

    func testPreferredCardRectanglePicksLargeWideCardOverTinyCardAspectLogo() {
        // Regression for uploaded screenshots where Vision finds the full card
        // plus a tiny Rx/PPO-style mark whose aspect is closer to a standard card.
        let imagePixelSize = CGSize(width: 1260, height: 2736)
        let wideVisibleCard = CGRect(x: 0.0760, y: 0.3633, width: 0.7993, height: 0.1713)
        let innerBluePanel = CGRect(x: 0.0907, y: 0.3936, width: 0.7704, height: 0.1354)
        let tinyCardAspectLogo = CGRect(x: 0.3165, y: 0.4067, width: 0.1449, height: 0.0469)

        let selectedIndex = CardImageProcessor.preferredCardRectangleIndex(
            boundingBoxes: [wideVisibleCard, innerBluePanel, tinyCardAspectLogo],
            imagePixelSize: imagePixelSize
        )

        XCTAssertEqual(selectedIndex, 0)
    }

    func testPreferredCardRectanglePicksCardAspectRectangleInsidePage() {
        // A rendered PDF/photo can produce a high-confidence page outline before
        // the actual card. The smaller card should still win once it clears the
        // absolute candidate-size threshold.
        let imagePixelSize = CGSize(width: 850, height: 1100)
        let pageOutline = CGRect(x: 0.02, y: 0.02, width: 0.96, height: 0.96)
        let cardOnPage = CGRect(x: 0.25, y: 0.40, width: 0.50, height: 0.2436)

        let selectedIndex = CardImageProcessor.preferredCardRectangleIndex(
            boundingBoxes: [pageOutline, cardOnPage],
            imagePixelSize: imagePixelSize
        )

        XCTAssertEqual(selectedIndex, 1)
    }

    func testPreferredCardRectangleFallsBackToHighestConfidenceWithoutCardAspectMatch() {
        // Inner square/barcode codes are not plausible whole-card candidates, so
        // the highest confidence result (index 0) is preserved and the upload
        // crop guards can continue to protect tightly framed cards.
        let imagePixelSize = CGSize(width: 1000, height: 665)
        let squareCode = CGRect(x: 0.40, y: 0.40, width: 0.20, height: 0.30)
        let wideStripe = CGRect(x: 0.10, y: 0.45, width: 0.80, height: 0.12)

        let selectedIndex = CardImageProcessor.preferredCardRectangleIndex(
            boundingBoxes: [squareCode, wideStripe],
            imagePixelSize: imagePixelSize
        )

        XCTAssertEqual(selectedIndex, 0)
    }

    func testPreferredCardRectangleReturnsNilWhenNoRectanglesDetected() {
        let selectedIndex = CardImageProcessor.preferredCardRectangleIndex(
            boundingBoxes: [],
            imagePixelSize: CGSize(width: 1000, height: 665)
        )

        XCTAssertNil(selectedIndex)
    }

    private func seedConflictTestCard(
        in context: NSManagedObjectContext,
        timestamp: Date = Date(),
        frontImageData: Data? = nil,
        backImageData: Data? = nil
    ) throws -> NSManagedObjectID {
        let card = Card.insert(into: context)
        card.id = UUID()
        card.name = "Conflict Card"
        card.category = .membership
        card.frontImageData = frontImageData
        card.backImageData = backImageData
        card.hasBackImage = backImageData != nil
        card.isFavorite = false
        card.createdAt = timestamp
        card.lastAccessedAt = timestamp
        card.updatedAt = timestamp
        card.markAllMutableFieldsUpdated(at: timestamp)

        try context.save()
        return card.objectID
    }

    private func resolveObjectID(
        from uri: URL,
        in persistence: PersistenceController
    ) throws -> NSManagedObjectID {
        guard let objectID = persistence.container.persistentStoreCoordinator
            .managedObjectID(forURIRepresentation: uri) else {
            throw XCTSkip("Failed to resolve object ID for shared store URI")
        }
        return objectID
    }

    private func makeTemporaryStoreURL() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("Wallet.sqlite")
    }

    private func makeTemporaryFileURL(filenameExtension: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(filenameExtension)
    }

    private func fetchCards(in context: NSManagedObjectContext? = nil) throws -> [Card] {
        let request = Card.makeFetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: Card.Attributes.name, ascending: true)]
        return try (context ?? self.context).fetch(request)
    }

    private func fetchCardsSortedByLastAccessed() throws -> [Card] {
        let request = Card.makeFetchRequest()
        request.sortDescriptors = [
            NSSortDescriptor(key: Card.Attributes.lastAccessedAt, ascending: false),
            NSSortDescriptor(key: Card.Attributes.name, ascending: true)
        ]
        return try context.fetch(request)
    }

    @discardableResult
    private func insertStoredCard(
        name: String,
        lastAccessedAt: Date,
        updatedAt: Date,
        category: CardCategory = .membership,
        notes: String? = nil,
        isFavorite: Bool = false,
        hasBackImage: Bool = false
    ) throws -> Card {
        let card = Card.insert(into: context)
        card.id = UUID()
        card.name = name
        card.category = category
        card.notes = notes
        card.hasBackImage = hasBackImage
        card.isFavorite = isFavorite
        card.createdAt = lastAccessedAt
        card.lastAccessedAt = lastAccessedAt
        card.updatedAt = updatedAt
        card.markAllMutableFieldsUpdated(at: updatedAt)

        try context.save()
        return card
    }

    private func performAndWait(
        in context: NSManagedObjectContext,
        block: () throws -> Void
    ) throws {
        var thrownError: Error?
        context.performAndWait {
            do {
                try block()
            } catch {
                thrownError = error
            }
        }
        if let thrownError {
            throw thrownError
        }
    }

    private func waitForEnhancement(
        toFinishIn state: CardImageState,
        timeout: TimeInterval = 2.0
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while state.isEnhancing && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(state.isEnhancing)
    }

    private func makeImage(width: CGFloat, height: CGFloat, color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        }
    }

    private func makeImageWithCardOnBackground(
        width: CGFloat,
        height: CGFloat,
        cardRect: CGRect,
        cardColor: UIColor = .systemBlue,
        backgroundColor: UIColor = .white
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)

        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            backgroundColor.setFill()
            context.fill(bounds)
            cardColor.setFill()
            context.fill(cardRect)
            UIColor.black.setStroke()
            context.cgContext.setLineWidth(2)
            context.cgContext.stroke(cardRect)
        }
    }

    private func makeTightlyFramedCardWithBarcode(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let barcodeRect = CGRect(
            x: width * 0.16,
            y: height * 0.62,
            width: width * 0.68,
            height: height * 0.16
        )

        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(bounds)

            UIColor.white.setFill()
            context.fill(barcodeRect)

            UIColor.black.setStroke()
            context.cgContext.setLineWidth(2)
            context.cgContext.stroke(barcodeRect)

            for index in 0..<16 {
                let x = barcodeRect.minX + CGFloat(index) * barcodeRect.width / 16
                let lineWidth: CGFloat = index.isMultiple(of: 3) ? 5 : 2
                context.cgContext.setLineWidth(lineWidth)
                context.cgContext.move(to: CGPoint(x: x, y: barcodeRect.minY + 8))
                context.cgContext.addLine(to: CGPoint(x: x, y: barcodeRect.maxY - 8))
                context.cgContext.strokePath()
            }
        }
    }

    private func makeTightlyFramedCardWithSquareCode(width: CGFloat, height: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        let codeSize = width * 0.25
        let codeRect = CGRect(
            x: (width - codeSize) / 2,
            y: (height - codeSize) / 2,
            width: codeSize,
            height: codeSize
        )

        return UIGraphicsImageRenderer(size: bounds.size, format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(bounds)

            UIColor.white.setFill()
            context.fill(codeRect)

            UIColor.black.setStroke()
            context.cgContext.setLineWidth(2)
            context.cgContext.stroke(codeRect)

            let cellSize = codeRect.width / 7
            for row in 0..<7 {
                for column in 0..<7 where (row + column).isMultiple(of: 2) || row == 0 || column == 0 {
                    let cellRect = CGRect(
                        x: codeRect.minX + CGFloat(column) * cellSize,
                        y: codeRect.minY + CGFloat(row) * cellSize,
                        width: cellSize,
                        height: cellSize
                    ).insetBy(dx: 2, dy: 2)
                    UIColor.black.setFill()
                    context.fill(cellRect)
                }
            }
        }
    }

    private func makePDFData(width: CGFloat, height: CGFloat) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            UIColor.white.setFill()
            context.fill(bounds)
            UIColor.black.setStroke()
            let insetBounds = bounds.insetBy(dx: 36, dy: 36)
            context.cgContext.stroke(insetBounds)
        }
    }

    private func makePDFDataWithCard(width: CGFloat, height: CGFloat, cardRect: CGRect) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        return UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in
            context.beginPage()
            UIColor.white.setFill()
            context.fill(bounds)
            UIColor.systemBlue.setFill()
            context.fill(cardRect)
            UIColor.black.setStroke()
            context.cgContext.setLineWidth(2)
            context.cgContext.stroke(cardRect)
        }
    }
}

final class ImageProcessingTimeoutTests: XCTestCase {
    func testTimeoutDoesNotExpireWhileWorkIsQueued() async throws {
        let queue = ImageProcessingWorkQueue(
            maxConcurrentOperationCount: 1,
            name: "wallet.tests.image-processing-timeout"
        )
        let blockerStarted = expectation(description: "blocking operation started")
        let releaseBlocker = DispatchSemaphore(value: 0)

        let blocker = Task {
            try await queue.run { _ in
                blockerStarted.fulfill()
                releaseBlocker.wait()
            }
        }
        defer {
            releaseBlocker.signal()
            blocker.cancel()
        }

        await fulfillment(of: [blockerStarted], timeout: 1.0)

        let queuedWork = Task {
            try await withImageProcessingTimeout(seconds: 0.05) { startTimeout in
                try await queue.run(onStart: startTimeout) { _ in
                    true
                }
            }
        }

        try await Task.sleep(nanoseconds: 150_000_000)
        releaseBlocker.signal()

        let queuedResult = try await queuedWork.value
        XCTAssertTrue(queuedResult)
        _ = try await blocker.value
    }
}
