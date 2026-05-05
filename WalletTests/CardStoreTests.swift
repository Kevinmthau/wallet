import XCTest
import UIKit
import CoreData
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

        let savedFrontData = try XCTUnwrap(card.frontImageData)
        let savedFrontImage = try XCTUnwrap(UIImage(data: savedFrontData))
        XCTAssertLessThanOrEqual(max(savedFrontImage.size.width, savedFrontImage.size.height), 3072.0)
        XCTAssertGreaterThan(max(savedFrontImage.size.width, savedFrontImage.size.height), 2048.0)
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

        let updateSuccess = await store.updateCard(card, clearBackImage: true)
        XCTAssertTrue(updateSuccess)

        XCTAssertNil(card.backImageData)
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
    }

    func testInMemoryPersistenceDisablesCloudKit() {
        XCTAssertNil(persistence.container.persistentStoreDescriptions.first?.cloudKitContainerOptions)
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
            }

            try performAndWait(in: olderContext) {
                let card = try XCTUnwrap(try olderContext.existingObject(with: olderObjectID) as? Card)
                card.name = "Stale Update"
                card.updatedAt = olderTimestamp
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
            }

            try performAndWait(in: newerContext) {
                let card = try XCTUnwrap(try newerContext.existingObject(with: newerObjectID) as? Card)
                card.name = "Local Wins"
                card.updatedAt = newerTimestamp
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
            }

            try performAndWait(in: favoriteContext) {
                let card = try XCTUnwrap(try favoriteContext.existingObject(with: favoriteObjectID) as? Card)
                card.isFavorite = true
                card.updatedAt = favoriteTimestamp
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
            }

            try performAndWait(in: backContext) {
                let card = try XCTUnwrap(try backContext.existingObject(with: backObjectID) as? Card)
                card.backImageData = Data([0x04])
                card.updatedAt = backTimestamp
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
            }

            try performAndWait(in: localImageContext) {
                let card = try XCTUnwrap(try localImageContext.existingObject(with: localImageObjectID) as? Card)
                card.frontImageData = Data([0x05])
                card.updatedAt = localImageTimestamp
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
                XCTAssertEqual(try XCTUnwrap(card.updatedAt), localImageTimestamp)
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
        card.isFavorite = false
        card.createdAt = timestamp
        card.lastAccessedAt = timestamp
        card.updatedAt = timestamp

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
        updatedAt: Date
    ) throws -> Card {
        let card = Card.insert(into: context)
        card.id = UUID()
        card.name = name
        card.category = .membership
        card.isFavorite = false
        card.createdAt = lastAccessedAt
        card.lastAccessedAt = lastAccessedAt
        card.updatedAt = updatedAt

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

    private func makeImage(width: CGFloat, height: CGFloat, color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        }
    }
}
