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

    /// Lock for thread-safe stableId access when id is nil
    private static let stableIdLock = NSLock()

    /// Stable identifier for SwiftUI - id is optional for CloudKit but always set in create()
    /// If id is nil (e.g., from CloudKit sync edge case), generates and persists a new UUID
    var stableId: UUID {
        if let id = id {
            return id
        }
        // Thread-safe fallback: generate UUID and persist to Core Data
        Self.stableIdLock.lock()
        defer { Self.stableIdLock.unlock() }
        // Double-check after acquiring lock
        if let id = id {
            return id
        }
        let newId = UUID()
        self.id = newId
        return newId
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
    /// Compresses image to JPEG, falling back to PNG if JPEG fails
    private static func compressImage(_ image: UIImage) throws -> Data {
        // Try JPEG first
        if let jpegData = image.jpegData(compressionQuality: Constants.jpegCompressionQuality) {
            return jpegData
        }
        // Fallback to PNG
        if let pngData = image.pngData() {
            AppLogger.data.warning("Card: JPEG compression failed, using PNG fallback")
            return pngData
        }
        throw CardError.imageCompressionFailed
    }

    static func create(
        in context: NSManagedObjectContext,
        name: String,
        category: CardCategory,
        frontImage: UIImage,
        backImage: UIImage? = nil,
        notes: String? = nil
    ) throws -> Card {
        let card = Card(context: context)
        card.id = UUID()
        card.name = name
        card.category = category
        card.frontImageData = try compressImage(frontImage)
        if let backImage = backImage {
            card.backImageData = try compressImage(backImage)
        }
        card.notes = notes
        card.isFavorite = false
        card.createdAt = Date()
        card.lastAccessedAt = Date()
        return card
    }

    func updateLastAccessed() {
        lastAccessedAt = Date()
    }

    func toggleFavorite() {
        isFavorite.toggle()
    }
}
