import Foundation
import CoreData
import SwiftUI
import os

@MainActor
@Observable
class CardStore {
    private let context: NSManagedObjectContext

    var searchText: String = ""
    var lastError: Error?

    /// Maximum image dimension before resizing (2048px)
    private nonisolated static let maxImageDimension: CGFloat = 2048

    init(context: NSManagedObjectContext) {
        self.context = context
        backfillMissingCardIDs()
    }

    // MARK: - Image Validation

    private nonisolated static func processImageInBackground(_ image: UIImage) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                autoreleasepool {
                    do {
                        let data = try Self.validateAndCompressImage(image)
                        continuation.resume(returning: data)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    /// Resizes image if it exceeds max dimension, then compresses to JPEG/PNG
    private nonisolated static func validateAndCompressImage(_ image: UIImage) throws -> Data {
        let resizedImage = resizeImageIfNeeded(image, maxDimension: maxImageDimension)
        return try compressImage(resizedImage)
    }

    private nonisolated static func resizeImageIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        guard size.width > maxDimension || size.height > maxDimension else {
            return image
        }

        let scale: CGFloat
        if size.width > size.height {
            scale = maxDimension / size.width
        } else {
            scale = maxDimension / size.height
        }

        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        UIGraphicsBeginImageContextWithOptions(newSize, false, 1.0)
        defer { UIGraphicsEndImageContext() }

        image.draw(in: CGRect(origin: .zero, size: newSize))

        return UIGraphicsGetImageFromCurrentImageContext() ?? image
    }

    private nonisolated static func compressImage(_ image: UIImage) throws -> Data {
        // Try JPEG first
        if let jpegData = image.jpegData(compressionQuality: Constants.jpegCompressionQuality) {
            return jpegData
        }
        // Fallback to PNG
        if let pngData = image.pngData() {
            AppLogger.data.warning("CardStore: JPEG compression failed, using PNG fallback")
            return pngData
        }
        throw CardError.imageCompressionFailed
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

    @discardableResult
    func addCard(
        name: String,
        category: CardCategory,
        frontImage: UIImage,
        backImage: UIImage? = nil,
        notes: String? = nil
    ) async -> Bool {
        do {
            let processedFrontImage = try await Self.processImageInBackground(frontImage)
            var processedBackImage: Data?
            if let backImage {
                processedBackImage = try await Self.processImageInBackground(backImage)
            }

            let card = Card(context: context)
            card.id = UUID()
            card.name = name
            card.category = category
            card.frontImageData = processedFrontImage
            card.backImageData = processedBackImage
            card.notes = notes
            card.isFavorite = false
            card.createdAt = Date()
            card.lastAccessedAt = Date()
            return save()
        } catch {
            lastError = error
            AppLogger.data.error("CardStore.addCard failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func delete(_ card: Card) -> Bool {
        AppLogger.data.info("CardStore.delete: \(card.name)")
        context.delete(card)
        return save()
    }

    @discardableResult
    func toggleFavorite(_ card: Card) -> Bool {
        card.toggleFavorite()
        return save()
    }

    @discardableResult
    func markAccessed(_ card: Card) -> Bool {
        card.updateLastAccessed()
        return save()
    }

    @discardableResult
    func updateCard(
        _ card: Card,
        name: String? = nil,
        category: CardCategory? = nil,
        frontImage: UIImage? = nil,
        backImage: UIImage? = nil,
        clearBackImage: Bool = false,
        notes: String? = nil
    ) async -> Bool {
        do {
            var processedFrontImage: Data?
            if let frontImage {
                processedFrontImage = try await Self.processImageInBackground(frontImage)
            }

            var processedBackImage: Data?
            if !clearBackImage, let backImage {
                processedBackImage = try await Self.processImageInBackground(backImage)
            }

            if let name = name { card.name = name }
            if let category = category { card.category = category }
            if let processedFrontImage {
                card.frontImageData = processedFrontImage
            }
            if clearBackImage {
                card.backImageData = nil
            } else if let processedBackImage {
                card.backImageData = processedBackImage
            }
            if let notes = notes { card.notes = notes }
            return save()
        } catch {
            lastError = error
            AppLogger.data.error("CardStore.updateCard failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    private func save() -> Bool {
        if context.hasChanges {
            do {
                try context.save()
                AppLogger.data.info("CardStore.save: success")
                return true
            } catch {
                lastError = CardError.contextSaveFailed(underlying: error)
                AppLogger.data.error("CardStore.save failed: \(error.localizedDescription)")
                return false
            }
        }
        return true
    }

    /// Backfills IDs for legacy/synced records where UUID is nil.
    /// This keeps SwiftUI identity stable without mutating during view rendering.
    private func backfillMissingCardIDs() {
        let request = Card.fetchRequest() as! NSFetchRequest<Card>
        request.predicate = NSPredicate(format: "id == nil")

        do {
            let cardsMissingID = try context.fetch(request)
            guard !cardsMissingID.isEmpty else { return }

            for card in cardsMissingID {
                card.id = UUID()
            }

            AppLogger.data.info("CardStore: Backfilling IDs for \(cardsMissingID.count) cards")
            _ = save()
        } catch {
            AppLogger.data.error("CardStore.backfillMissingCardIDs failed: \(error.localizedDescription)")
        }
    }

    func clearError() {
        lastError = nil
    }
}
