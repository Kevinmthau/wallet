import Foundation
import CoreData
import SwiftUI

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
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var categoryRaw: String
    @NSManaged public var frontImageData: Data?
    @NSManaged public var backImageData: Data?
    @NSManaged public var notes: String?
    @NSManaged public var isFavorite: Bool
    @NSManaged public var createdAt: Date
    @NSManaged public var lastAccessedAt: Date

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
    static func create(
        in context: NSManagedObjectContext,
        name: String,
        category: CardCategory,
        frontImage: UIImage,
        backImage: UIImage? = nil,
        notes: String? = nil
    ) -> Card {
        let card = Card(context: context)
        card.id = UUID()
        card.name = name
        card.category = category
        card.frontImageData = frontImage.jpegData(compressionQuality: 0.8)
        card.backImageData = backImage?.jpegData(compressionQuality: 0.8)
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
