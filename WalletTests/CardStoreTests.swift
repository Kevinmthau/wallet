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

    func testAddCardStoresImagesAndMetadata() throws {
        let front = makeImage(width: 3000, height: 1500, color: .blue)
        let back = makeImage(width: 1000, height: 600, color: .red)

        let success = store.addCard(
            name: "Gym Membership",
            category: .membership,
            frontImage: front,
            backImage: back,
            notes: "Member #123"
        )

        XCTAssertTrue(success)
        XCTAssertEqual(store.allCards.count, 1)

        let card = try XCTUnwrap(store.allCards.first)
        XCTAssertNotNil(card.id)
        XCTAssertEqual(card.name, "Gym Membership")
        XCTAssertEqual(card.category, .membership)
        XCTAssertEqual(card.notes, "Member #123")
        XCTAssertNotNil(card.createdAt)
        XCTAssertNotNil(card.lastAccessedAt)
        XCTAssertNotNil(card.frontImageData)
        XCTAssertNotNil(card.backImageData)

        let savedFrontImage = try XCTUnwrap(card.frontImage)
        XCTAssertLessThanOrEqual(max(savedFrontImage.size.width, savedFrontImage.size.height), 2048.0)
    }

    func testUpdateCardCanClearBackImage() throws {
        let front = makeImage(width: 600, height: 400, color: .green)
        let back = makeImage(width: 600, height: 400, color: .yellow)

        XCTAssertTrue(
            store.addCard(
                name: "Library Card",
                category: .loyalty,
                frontImage: front,
                backImage: back
            )
        )

        let card = try XCTUnwrap(store.allCards.first)
        XCTAssertNotNil(card.backImageData)

        XCTAssertTrue(
            store.updateCard(
                card,
                clearBackImage: true
            )
        )

        XCTAssertNil(card.backImageData)
    }

    func testBackfillsMissingIDsOnInit() throws {
        let card = Card(context: context)
        card.id = nil
        card.name = "Legacy Card"
        card.category = .other
        card.isFavorite = false
        card.createdAt = Date()
        card.lastAccessedAt = Date()

        try context.save()

        let freshStore = CardStore(context: context)
        let refreshedCard = try XCTUnwrap(freshStore.allCards.first(where: { $0.name == "Legacy Card" }))
        XCTAssertNotNil(refreshedCard.id)
    }

    private func makeImage(width: CGFloat, height: CGFloat, color: UIColor) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height))
        return renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(origin: .zero, size: CGSize(width: width, height: height)))
        }
    }
}
