import Foundation
import CoreData
import SwiftUI
import os

@MainActor
@Observable
class CardStore {
    private let context: NSManagedObjectContext

    var lastError: Error?

    /// Maximum image dimension before resizing (2048px)
    private nonisolated static let maxImageDimension: CGFloat = 2048

    private var pendingAccessUpdates: [NSManagedObjectID: Date] = [:]
    private var pendingAccessSaveTask: Task<Void, Never>?

    init(context: NSManagedObjectContext) {
        self.context = context
        backfillLegacyMetadata()
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
        if let jpegData = image.jpegData(compressionQuality: Constants.jpegCompressionQuality) {
            return jpegData
        }

        if let pngData = image.pngData() {
            AppLogger.data.warning("CardStore: JPEG compression failed, using PNG fallback")
            return pngData
        }

        throw CardError.imageCompressionFailed
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
        prepareForImmediateSave()

        do {
            async let processedFrontImage = Self.processImageInBackground(frontImage)
            async let processedBackImage: Data? = {
                guard let backImage else { return nil }
                return try await Self.processImageInBackground(backImage)
            }()

            let mutationDate = Date()
            let card = Card(context: context)
            card.id = UUID()
            card.name = name
            card.category = category
            card.frontImageData = try await processedFrontImage
            card.backImageData = try await processedBackImage
            card.notes = notes
            card.isFavorite = false
            card.createdAt = mutationDate
            card.lastAccessedAt = mutationDate
            card.updatedAt = mutationDate
            return save()
        } catch {
            lastError = error
            AppLogger.data.error("CardStore.addCard failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func delete(_ card: Card) -> Bool {
        prepareForImmediateSave()
        AppLogger.data.info("CardStore.delete: \(card.name)")
        context.delete(card)
        return save()
    }

    @discardableResult
    func toggleFavorite(_ card: Card) -> Bool {
        prepareForImmediateSave()
        card.toggleFavorite()
        return save()
    }

    func markAccessed(_ card: Card) {
        pendingAccessUpdates[card.objectID] = Date()
        scheduleAccessSave()
    }

    @discardableResult
    func updateCard(
        _ card: Card,
        name: String? = nil,
        category: CardCategory? = nil,
        frontImage: UIImage? = nil,
        backImage: UIImage? = nil,
        clearBackImage: Bool = false,
        notes: String? = nil,
        clearNotes: Bool = false
    ) async -> Bool {
        prepareForImmediateSave()

        do {
            async let processedFrontImage: Data? = {
                guard let frontImage else { return nil }
                return try await Self.processImageInBackground(frontImage)
            }()

            async let processedBackImage: Data? = {
                guard !clearBackImage, let backImage else { return nil }
                return try await Self.processImageInBackground(backImage)
            }()

            let mutationDate = Date()

            if let name {
                card.name = name
            }
            if let category {
                card.category = category
            }
            if let processedFrontImage = try await processedFrontImage {
                card.frontImageData = processedFrontImage
            }
            if clearBackImage {
                card.backImageData = nil
            } else if let processedBackImage = try await processedBackImage {
                card.backImageData = processedBackImage
            }
            if clearNotes {
                card.notes = nil
            } else if let notes {
                card.notes = notes
            }

            card.touchUpdatedAt(mutationDate)
            return save()
        } catch {
            lastError = error
            AppLogger.data.error("CardStore.updateCard failed: \(error.localizedDescription)")
            return false
        }
    }

    func clearError() {
        lastError = nil
    }

    // MARK: - Persistence

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

    private func scheduleAccessSave() {
        pendingAccessSaveTask?.cancel()
        pendingAccessSaveTask = Task { [weak self] in
            let delay = UInt64(Constants.Persistence.accessSaveDebounceInterval * 1_000_000_000)
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            self?.flushPendingAccessUpdates()
        }
    }

    private func prepareForImmediateSave() {
        pendingAccessSaveTask?.cancel()
        pendingAccessSaveTask = nil
        flushPendingAccessUpdates()
    }

    private func applyPendingAccessUpdates() {
        guard !pendingAccessUpdates.isEmpty else { return }

        let updates = pendingAccessUpdates
        pendingAccessUpdates.removeAll()

        for (objectID, accessedAt) in updates {
            guard let card = try? context.existingObject(with: objectID) as? Card,
                  !card.isDeleted else {
                continue
            }
            card.updateLastAccessed(at: accessedAt)
        }
    }

    private func flushPendingAccessUpdates() {
        pendingAccessSaveTask = nil
        guard !pendingAccessUpdates.isEmpty else { return }
        applyPendingAccessUpdates()
        _ = save()
    }

    /// Backfills IDs/timestamps for legacy records so identity and conflict resolution stay stable.
    private func backfillLegacyMetadata() {
        let request = Card.makeFetchRequest()
        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "\(Card.Attributes.id) == nil"),
            NSPredicate(format: "\(Card.Attributes.updatedAt) == nil")
        ])

        do {
            let legacyCards = try context.fetch(request)
            guard !legacyCards.isEmpty else { return }

            for card in legacyCards {
                if card.id == nil {
                    card.id = UUID()
                }
                if card.updatedAt == nil {
                    card.updatedAt = card.lastAccessedAt ?? card.createdAt ?? Date()
                }
            }

            AppLogger.data.info("CardStore: Backfilling metadata for \(legacyCards.count) cards")
            _ = save()
        } catch {
            AppLogger.data.error("CardStore.backfillLegacyMetadata failed: \(error.localizedDescription)")
        }
    }
}
