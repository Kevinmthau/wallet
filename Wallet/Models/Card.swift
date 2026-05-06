import Foundation
import CoreData
import SwiftUI

/// Errors that can occur during card operations
enum CardError: LocalizedError {
    case imageCompressionFailed
    case cardNotFound
    case contextSaveFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .imageCompressionFailed:
            return "Failed to compress card image"
        case .cardNotFound:
            return "This card is no longer available"
        case .contextSaveFailed(let error):
            return "Failed to save card: \(error.localizedDescription)"
        }
    }
}

enum CardCategory: String, CaseIterable, Identifiable {
    case insurance = "Insurance"
    case membership = "Membership"
    case id = "ID"
    case loyalty = "Loyalty"
    case creditCard = "Credit Card"
    case other = "Other"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .insurance: return "heart.text.square"
        case .membership: return "person.crop.rectangle"
        case .id: return "person.text.rectangle"
        case .loyalty: return "star.square"
        case .creditCard: return "creditcard"
        case .other: return "rectangle.on.rectangle"
        }
    }

    var color: Color {
        switch self {
        case .insurance: return .red
        case .membership: return .blue
        case .id: return .green
        case .loyalty: return .orange
        case .creditCard: return .purple
        case .other: return .gray
        }
    }
}

@objc(Card)
public class Card: NSManagedObject, Identifiable {
    enum Attributes {
        static let entityName = "Card"
        static let id = "id"
        static let name = "name"
        static let categoryRaw = "categoryRaw"
        static let frontImageData = "frontImageData"
        static let backImageData = "backImageData"
        static let hasBackImage = "hasBackImage"
        static let notes = "notes"
        static let isFavorite = "isFavorite"
        static let createdAt = "createdAt"
        static let lastAccessedAt = "lastAccessedAt"
        static let updatedAt = "updatedAt"
        static let nameUpdatedAt = "nameUpdatedAt"
        static let categoryUpdatedAt = "categoryUpdatedAt"
        static let notesUpdatedAt = "notesUpdatedAt"
        static let isFavoriteUpdatedAt = "isFavoriteUpdatedAt"
        static let frontImageUpdatedAt = "frontImageUpdatedAt"
        static let backImageUpdatedAt = "backImageUpdatedAt"

        static let mutableFieldTimestampKeys = [
            nameUpdatedAt,
            categoryUpdatedAt,
            notesUpdatedAt,
            isFavoriteUpdatedAt,
            frontImageUpdatedAt,
            backImageUpdatedAt
        ]

        static let timestampKeyByMutableField = [
            name: nameUpdatedAt,
            categoryRaw: categoryUpdatedAt,
            notes: notesUpdatedAt,
            isFavorite: isFavoriteUpdatedAt,
            frontImageData: frontImageUpdatedAt,
            backImageData: backImageUpdatedAt
        ]
    }

    @NSManaged public var id: UUID?
    @NSManaged public var name: String
    @NSManaged public var categoryRaw: String
    @NSManaged public var frontImageData: Data?
    @NSManaged public var backImageData: Data?
    @NSManaged public var hasBackImage: Bool
    @NSManaged public var notes: String?
    @NSManaged public var isFavorite: Bool
    @NSManaged public var createdAt: Date?
    @NSManaged public var lastAccessedAt: Date?
    @NSManaged public var updatedAt: Date?
    @NSManaged public var nameUpdatedAt: Date?
    @NSManaged public var categoryUpdatedAt: Date?
    @NSManaged public var notesUpdatedAt: Date?
    @NSManaged public var isFavoriteUpdatedAt: Date?
    @NSManaged public var frontImageUpdatedAt: Date?
    @NSManaged public var backImageUpdatedAt: Date?

    static func makeFetchRequest() -> NSFetchRequest<Card> {
        NSFetchRequest<Card>(entityName: Attributes.entityName)
    }

    static func insert(into context: NSManagedObjectContext) -> Card {
        guard let entity = NSEntityDescription.entity(
            forEntityName: Attributes.entityName,
            in: context
        ) else {
            preconditionFailure("Missing \(Attributes.entityName) entity description")
        }

        return Card(entity: entity, insertInto: context)
    }

    /// Stable identifier for SwiftUI that never mutates model state during render.
    /// Falls back to Core Data object URI string if UUID is temporarily missing.
    var stableId: String {
        if let id = id {
            return id.uuidString
        }
        return objectID.uriRepresentation().absoluteString
    }

    var category: CardCategory {
        get { CardCategory(rawValue: categoryRaw) ?? .other }
        set { categoryRaw = newValue.rawValue }
    }

    var hasBack: Bool {
        hasBackImage
    }
}

extension Card {
    func updateLastAccessed(at date: Date = Date()) {
        lastAccessedAt = date
    }

    func touchUpdatedAt(_ date: Date = Date()) {
        updatedAt = date
    }

    func toggleFavorite(at date: Date = Date()) {
        isFavorite.toggle()
        markFieldUpdated(Card.Attributes.isFavorite, at: date)
        updatedAt = date
    }

    func markFieldUpdated(_ fieldKey: String, at date: Date) {
        guard let timestampKey = Card.Attributes.timestampKeyByMutableField[fieldKey],
              entity.propertiesByName[timestampKey] != nil else {
            return
        }
        setValue(date, forKey: timestampKey)
    }

    func markAllMutableFieldsUpdated(at date: Date) {
        for timestampKey in Card.Attributes.mutableFieldTimestampKeys
            where entity.propertiesByName[timestampKey] != nil {
            setValue(date, forKey: timestampKey)
        }
    }

    func backfillMissingMutableFieldTimestamps(at date: Date) {
        for timestampKey in Card.Attributes.mutableFieldTimestampKeys
            where entity.propertiesByName[timestampKey] != nil
                && value(forKey: timestampKey) == nil {
            setValue(date, forKey: timestampKey)
        }
    }
}
