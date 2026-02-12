import Foundation
import CoreData
import SwiftUI

/// Errors that can occur during card operations
enum CardError: LocalizedError {
    case imageCompressionFailed
    case contextSaveFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .imageCompressionFailed:
            return "Failed to compress card image"
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
    @NSManaged public var id: UUID?
    @NSManaged public var name: String
    @NSManaged public var categoryRaw: String
    @NSManaged public var frontImageData: Data?
    @NSManaged public var backImageData: Data?
    @NSManaged public var notes: String?
    @NSManaged public var isFavorite: Bool
    @NSManaged public var createdAt: Date?
    @NSManaged public var lastAccessedAt: Date?

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

    var frontImage: UIImage? {
        guard let data = frontImageData else { return nil }
        return UIImage(data: data)
    }

    var backImage: UIImage? {
        guard let data = backImageData else { return nil }
        return UIImage(data: data)
    }

    var hasBack: Bool {
        backImageData != nil
    }
}

extension Card {
    func updateLastAccessed() {
        lastAccessedAt = Date()
    }

    func toggleFavorite() {
        isFavorite.toggle()
    }
}
