import Foundation
import CoreData
import SwiftUI
import os

@Observable
class CardStore {
    private let context: NSManagedObjectContext

    var searchText: String = ""

    init(context: NSManagedObjectContext) {
        self.context = context
    }

    // MARK: - Fetch Requests

    private func fetch(
        predicate: NSPredicate? = nil,
        sortDescriptors: [NSSortDescriptor] = [NSSortDescriptor(keyPath: \Card.name, ascending: true)],
        fetchLimit: Int? = nil
    ) -> [Card] {
        let request = Card.fetchRequest() as! NSFetchRequest<Card>
        request.predicate = predicate
        request.sortDescriptors = sortDescriptors
        if let limit = fetchLimit {
            request.fetchLimit = limit
        }
        do {
            return try context.fetch(request)
        } catch {
            AppLogger.data.error("CardStore.fetch failed: \(error.localizedDescription)")
            return []
        }
    }

    var favoriteCards: [Card] {
        fetch(predicate: NSPredicate(format: "isFavorite == YES"))
    }

    var recentCards: [Card] {
        fetch(
            sortDescriptors: [NSSortDescriptor(keyPath: \Card.lastAccessedAt, ascending: false)],
            fetchLimit: 5
        )
    }

    var allCards: [Card] {
        fetch()
    }

    func cards(for category: CardCategory) -> [Card] {
        fetch(predicate: NSPredicate(format: "categoryRaw == %@", category.rawValue))
    }

    func filteredCards(searchText: String) -> [Card] {
        guard !searchText.isEmpty else { return allCards }
        return fetch(predicate: NSPredicate(format: "name CONTAINS[cd] %@", searchText))
    }

    var cardsByCategory: [(category: CardCategory, cards: [Card])] {
        CardCategory.allCases.compactMap { category in
            let categoryCards = cards(for: category)
            return categoryCards.isEmpty ? nil : (category, categoryCards)
        }
    }

    // MARK: - Actions

    func addCard(
        name: String,
        category: CardCategory,
        frontImage: UIImage,
        backImage: UIImage? = nil,
        notes: String? = nil
    ) {
        _ = Card.create(
            in: context,
            name: name,
            category: category,
            frontImage: frontImage,
            backImage: backImage,
            notes: notes
        )
        save()
    }

    func delete(_ card: Card) {
        AppLogger.data.info("CardStore.delete: \(card.name)")
        context.delete(card)
        save()
    }

    func toggleFavorite(_ card: Card) {
        card.toggleFavorite()
        save()
    }

    func markAccessed(_ card: Card) {
        card.updateLastAccessed()
        save()
    }

    func updateCard(
        _ card: Card,
        name: String? = nil,
        category: CardCategory? = nil,
        frontImage: UIImage? = nil,
        backImage: UIImage? = nil,
        clearBackImage: Bool = false,
        notes: String? = nil
    ) {
        if let name = name { card.name = name }
        if let category = category { card.category = category }
        if let frontImage = frontImage {
            card.frontImageData = frontImage.jpegData(compressionQuality: Constants.jpegCompressionQuality)
        }
        if clearBackImage {
            card.backImageData = nil
        } else if let backImage = backImage {
            card.backImageData = backImage.jpegData(compressionQuality: Constants.jpegCompressionQuality)
        }
        if let notes = notes { card.notes = notes }
        save()
    }

    private func save() {
        if context.hasChanges {
            do {
                try context.save()
                AppLogger.data.info("CardStore.save: success")
            } catch {
                AppLogger.data.error("CardStore.save failed: \(error.localizedDescription)")
            }
        }
    }
}
