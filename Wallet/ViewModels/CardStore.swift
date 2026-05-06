import Foundation
import Combine
import CoreData
import SwiftUI
import os

@MainActor
@Observable
class CardStore {
    private let context: NSManagedObjectContext

    var lastError: Error?

    private var pendingAccessUpdates: [NSManagedObjectID: Date] = [:]
    private var pendingAccessSaveTask: Task<Void, Never>?
    private var remoteChangeCancellable: AnyCancellable?

    init(context: NSManagedObjectContext) {
        self.context = context
        backfillLegacyMetadata()
        repairBackImagePresence()
        observeRemoteChanges()
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
            async let processedFrontImage = CardImageProcessor.shared.prepareForStorage(frontImage)
            async let processedBackImage: Data? = {
                guard let backImage else { return nil }
                return try await CardImageProcessor.shared.prepareForStorage(backImage)
            }()

            let frontImageData = try await processedFrontImage
            let backImageData = try await processedBackImage
            let mutationDate = Date()
            let card = Card.insert(into: context)
            card.id = UUID()
            card.name = name
            card.category = category
            card.frontImageData = frontImageData
            card.backImageData = backImageData
            card.hasBackImage = backImageData != nil
            card.notes = notes
            card.isFavorite = false
            card.createdAt = mutationDate
            card.lastAccessedAt = mutationDate
            card.updatedAt = mutationDate
            card.markAllMutableFieldsUpdated(at: mutationDate)
            return save()
        } catch {
            lastError = error
            AppLogger.data.error("CardStore.addCard failed: \(error.localizedDescription)")
            return false
        }
    }

    @discardableResult
    func delete(_ card: Card) -> Bool {
        delete(objectID: card.objectID)
    }

    @discardableResult
    func delete(objectID: NSManagedObjectID) -> Bool {
        prepareForImmediateSave()

        guard let card = existingCard(for: objectID) else {
            AppLogger.data.info("CardStore.delete: card already missing")
            return true
        }

        AppLogger.data.info("CardStore.delete: \(card.name)")
        card.touchUpdatedAt()
        context.delete(card)
        return save()
    }

    @discardableResult
    func toggleFavorite(_ card: Card) -> Bool {
        toggleFavorite(objectID: card.objectID)
    }

    @discardableResult
    func toggleFavorite(objectID: NSManagedObjectID) -> Bool {
        prepareForImmediateSave()

        guard let card = existingCard(for: objectID) else {
            lastError = CardError.cardNotFound
            AppLogger.data.error("CardStore.toggleFavorite failed: card not found")
            return false
        }

        card.toggleFavorite()
        return save()
    }

    func markAccessed(_ card: Card) {
        markAccessed(objectID: card.objectID)
    }

    func markAccessed(objectID: NSManagedObjectID) {
        let accessedAt = Date()
        existingCard(for: objectID)?.updateLastAccessed(at: accessedAt)
        pendingAccessUpdates[objectID] = accessedAt
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
        let objectID = card.objectID
        prepareForImmediateSave()

        do {
            async let processedFrontImage: Data? = {
                guard let frontImage else { return nil }
                return try await CardImageProcessor.shared.prepareForStorage(frontImage)
            }()

            async let processedBackImage: Data? = {
                guard !clearBackImage, let backImage else { return nil }
                return try await CardImageProcessor.shared.prepareForStorage(backImage)
            }()

            let frontImageData = try await processedFrontImage
            let backImageData = try await processedBackImage
            let mutationDate = Date()
            guard let card = existingCard(for: objectID) else {
                lastError = CardError.cardNotFound
                AppLogger.data.error("CardStore.updateCard failed: card not found")
                return false
            }

            if let name {
                card.name = name
                card.markFieldUpdated(Card.Attributes.name, at: mutationDate)
            }
            if let category {
                card.category = category
                card.markFieldUpdated(Card.Attributes.categoryRaw, at: mutationDate)
            }
            if let frontImageData {
                card.frontImageData = frontImageData
                card.markFieldUpdated(Card.Attributes.frontImageData, at: mutationDate)
            }
            if clearBackImage {
                card.backImageData = nil
                card.hasBackImage = false
                card.markFieldUpdated(Card.Attributes.backImageData, at: mutationDate)
            } else if let backImageData {
                card.backImageData = backImageData
                card.hasBackImage = true
                card.markFieldUpdated(Card.Attributes.backImageData, at: mutationDate)
            }
            if clearNotes {
                card.notes = nil
                card.markFieldUpdated(Card.Attributes.notes, at: mutationDate)
            } else if let notes {
                card.notes = notes
                card.markFieldUpdated(Card.Attributes.notes, at: mutationDate)
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

    private func existingCard(for objectID: NSManagedObjectID) -> Card? {
        guard !objectID.isTemporaryID else { return nil }

        do {
            guard let card = try context.existingObject(with: objectID) as? Card,
                  !card.isDeleted else {
                return nil
            }
            return card
        } catch {
            return nil
        }
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
        let missingFieldTimestampPredicates = Card.Attributes.mutableFieldTimestampKeys.map {
            NSPredicate(format: "\($0) == nil")
        }
        request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: [
            NSPredicate(format: "\(Card.Attributes.id) == nil"),
            NSPredicate(format: "\(Card.Attributes.updatedAt) == nil")
        ] + missingFieldTimestampPredicates)

        do {
            let legacyCards = try context.fetch(request)
            guard !legacyCards.isEmpty else { return }

            for card in legacyCards {
                let referenceDate = card.updatedAt ?? card.lastAccessedAt ?? card.createdAt ?? Date()
                if card.id == nil {
                    card.id = UUID()
                }
                if card.updatedAt == nil {
                    card.updatedAt = referenceDate
                }
                card.backfillMissingMutableFieldTimestamps(at: referenceDate)
            }

            AppLogger.data.info("CardStore: Backfilling metadata for \(legacyCards.count) cards")
            _ = save()
        } catch {
            AppLogger.data.error("CardStore.backfillLegacyMetadata failed: \(error.localizedDescription)")
        }
    }

    @discardableResult
    private func repairBackImagePresence() -> Int {
        do {
            let repairedCount = try repairBackImagePresence(
                hasBackImage: true,
                predicate: NSPredicate(
                    format: "\(Card.Attributes.backImageData) != nil AND \(Card.Attributes.hasBackImage) == NO"
                )
            ) + repairBackImagePresence(
                hasBackImage: false,
                predicate: NSPredicate(
                    format: "\(Card.Attributes.backImageData) == nil AND \(Card.Attributes.hasBackImage) == YES"
                )
            )
            guard repairedCount > 0 else { return 0 }

            AppLogger.data.info("CardStore: Repairing back image metadata for \(repairedCount) cards")
            return repairedCount
        } catch {
            AppLogger.data.error("CardStore.repairBackImagePresence failed: \(error.localizedDescription)")
            return 0
        }
    }

    private func repairBackImagePresence(
        hasBackImage: Bool,
        predicate: NSPredicate
    ) throws -> Int {
        let request = NSBatchUpdateRequest(entityName: Card.Attributes.entityName)
        request.predicate = predicate
        request.propertiesToUpdate = [Card.Attributes.hasBackImage: hasBackImage]
        request.resultType = .updatedObjectIDsResultType

        guard let result = try context.execute(request) as? NSBatchUpdateResult,
              let objectIDs = result.result as? [NSManagedObjectID] else {
            return 0
        }

        NSManagedObjectContext.mergeChanges(
            fromRemoteContextSave: [NSUpdatedObjectsKey: objectIDs],
            into: [context]
        )
        return objectIDs.count
    }

    private func observeRemoteChanges() {
        guard let coordinator = context.persistentStoreCoordinator else { return }

        remoteChangeCancellable = NotificationCenter.default.publisher(
            for: .NSPersistentStoreRemoteChange,
            object: coordinator
        )
        .sink { [weak self] _ in
            Task { @MainActor in
                self?.repairBackImagePresence()
            }
        }
    }
}
