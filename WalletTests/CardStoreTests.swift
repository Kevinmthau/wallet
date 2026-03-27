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

        let savedFrontImage = try XCTUnwrap(card.frontImage)
        XCTAssertLessThanOrEqual(max(savedFrontImage.size.width, savedFrontImage.size.height), 2048.0)
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

    func testMarkAccessedIsBatchedUntilAnotherSave() async throws {
        let addSuccess = await store.addCard(
            name: "Access Test",
            category: .membership,
            frontImage: makeImage(width: 600, height: 400, color: .orange)
        )
        XCTAssertTrue(addSuccess)

        let card = try XCTUnwrap(fetchCards().first)
        let originalAccessDate = try XCTUnwrap(card.lastAccessedAt)

        store.markAccessed(card)

        XCTAssertEqual(card.lastAccessedAt, originalAccessDate)

        XCTAssertTrue(store.toggleFavorite(card))
        XCTAssertTrue(card.isFavorite)
        XCTAssertGreaterThan(try XCTUnwrap(card.lastAccessedAt), originalAccessDate)
    }

    func testBackfillsMissingIDsAndUpdatedAtOnInit() throws {
        let originalAccessDate = Date().addingTimeInterval(-120)
        let card = Card(context: context)
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
        let objectID = try seedConflictTestCard()

        let newerContext = persistence.makeBackgroundContext()
        let olderContext = persistence.makeBackgroundContext()
        let newerTimestamp = Date().addingTimeInterval(20)
        let olderTimestamp = Date().addingTimeInterval(10)

        try performAndWait(in: newerContext) {
            let card = try XCTUnwrap(try newerContext.existingObject(with: objectID) as? Card)
            card.name = "Store Wins"
            card.updatedAt = newerTimestamp
            try newerContext.save()
        }

        try performAndWait(in: olderContext) {
            let card = try XCTUnwrap(try olderContext.existingObject(with: objectID) as? Card)
            card.name = "Stale Update"
            card.updatedAt = olderTimestamp
            try olderContext.save()
        }

        let verificationContext = persistence.makeBackgroundContext()
        try performAndWait(in: verificationContext) {
            let card = try XCTUnwrap(try verificationContext.existingObject(with: objectID) as? Card)
            XCTAssertEqual(card.name, "Store Wins")
            XCTAssertEqual(try XCTUnwrap(card.updatedAt), newerTimestamp)
        }
    }

    func testTimestampMergePolicyPrefersNewerLocalVersion() throws {
        let objectID = try seedConflictTestCard()

        let olderContext = persistence.makeBackgroundContext()
        let newerContext = persistence.makeBackgroundContext()
        let olderTimestamp = Date().addingTimeInterval(10)
        let newerTimestamp = Date().addingTimeInterval(20)

        try performAndWait(in: olderContext) {
            let card = try XCTUnwrap(try olderContext.existingObject(with: objectID) as? Card)
            card.name = "Older Update"
            card.updatedAt = olderTimestamp
            try olderContext.save()
        }

        try performAndWait(in: newerContext) {
            let card = try XCTUnwrap(try newerContext.existingObject(with: objectID) as? Card)
            card.name = "Local Wins"
            card.updatedAt = newerTimestamp
            try newerContext.save()
        }

        let verificationContext = persistence.makeBackgroundContext()
        try performAndWait(in: verificationContext) {
            let card = try XCTUnwrap(try verificationContext.existingObject(with: objectID) as? Card)
            XCTAssertEqual(card.name, "Local Wins")
            XCTAssertEqual(try XCTUnwrap(card.updatedAt), newerTimestamp)
        }
    }

    private func seedConflictTestCard() throws -> NSManagedObjectID {
        let timestamp = Date()
        let card = Card(context: context)
        card.id = UUID()
        card.name = "Conflict Card"
        card.category = .membership
        card.isFavorite = false
        card.createdAt = timestamp
        card.lastAccessedAt = timestamp
        card.updatedAt = timestamp

        try context.save()
        return card.objectID
    }

    private func fetchCards(in context: NSManagedObjectContext? = nil) throws -> [Card] {
        let request = Card.makeFetchRequest()
        request.sortDescriptors = [NSSortDescriptor(key: Card.Attributes.name, ascending: true)]
        return try (context ?? self.context).fetch(request)
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
