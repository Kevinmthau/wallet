import Foundation
import CoreData
import SwiftUI
import ImageIO

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
    enum Attributes {
        static let entityName = "Card"
        static let id = "id"
        static let name = "name"
        static let categoryRaw = "categoryRaw"
        static let frontImageData = "frontImageData"
        static let backImageData = "backImageData"
        static let notes = "notes"
        static let isFavorite = "isFavorite"
        static let createdAt = "createdAt"
        static let lastAccessedAt = "lastAccessedAt"
        static let updatedAt = "updatedAt"
    }

    private static let fullImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    private static let displayImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    private static let thumbnailImageCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    @NSManaged public var id: UUID?
    @NSManaged public var name: String
    @NSManaged public var categoryRaw: String
    @NSManaged public var frontImageData: Data?
    @NSManaged public var backImageData: Data?
    @NSManaged public var notes: String?
    @NSManaged public var isFavorite: Bool
    @NSManaged public var createdAt: Date?
    @NSManaged public var lastAccessedAt: Date?
    @NSManaged public var updatedAt: Date?

    static func makeFetchRequest() -> NSFetchRequest<Card> {
        NSFetchRequest<Card>(entityName: Attributes.entityName)
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

    var frontImage: UIImage? {
        cachedImage(
            from: frontImageData,
            variant: "front-full",
            cache: Self.fullImageCache
        ) { data in
            UIImage(data: data)
        }
    }

    var backImage: UIImage? {
        cachedImage(
            from: backImageData,
            variant: "back-full",
            cache: Self.fullImageCache
        ) { data in
            UIImage(data: data)
        }
    }

    var frontThumbnail: UIImage? {
        cachedImage(
            from: frontImageData,
            variant: "front-thumb",
            cache: Self.thumbnailImageCache
        ) { data in
            Self.makeThumbnail(
                from: data,
                maxPixelSize: Constants.CardLayout.listThumbnailMaxDimension
            )
        }
    }

    var frontDisplayImage: UIImage? {
        cachedImage(
            from: frontImageData,
            variant: "front-display",
            cache: Self.displayImageCache
        ) { data in
            Self.makeThumbnail(
                from: data,
                maxPixelSize: Constants.CardLayout.displayImageMaxDimension
            )
        }
    }

    var backDisplayImage: UIImage? {
        cachedImage(
            from: backImageData,
            variant: "back-display",
            cache: Self.displayImageCache
        ) { data in
            Self.makeThumbnail(
                from: data,
                maxPixelSize: Constants.CardLayout.displayImageMaxDimension
            )
        }
    }

    var hasBack: Bool {
        backImageData != nil
    }

    private func cachedImage(
        from data: Data?,
        variant: String,
        cache: NSCache<NSString, UIImage>,
        decoder: (Data) -> UIImage?
    ) -> UIImage? {
        guard let data else { return nil }
        let key = cacheKey(for: data, variant: variant)

        if let cached = cache.object(forKey: key) {
            return cached
        }

        guard let image = decoder(data) else { return nil }
        cache.setObject(image, forKey: key, cost: Self.imageCost(image))
        return image
    }

    private func cacheKey(for data: Data, variant: String) -> NSString {
        "\(stableId)-\(variant)-\(Self.dataFingerprint(for: data))" as NSString
    }

    private static func dataFingerprint(for data: Data) -> String {
        let prefix = data.prefix(16).map { String(format: "%02x", $0) }.joined()
        let suffix = data.suffix(16).map { String(format: "%02x", $0) }.joined()
        return "\(data.count)-\(prefix)-\(suffix)"
    }

    private static func imageCost(_ image: UIImage) -> Int {
        let pixelCount = image.size.width * image.size.height * image.scale * image.scale
        return max(1, Int(pixelCount * 4))
    }

    private static func makeThumbnail(from data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return UIImage(data: data)
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxPixelSize))
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            return UIImage(data: data)
        }

        return UIImage(cgImage: cgImage)
    }
}

extension Card {
    func updateLastAccessed(at date: Date = Date()) {
        lastAccessedAt = date
        updatedAt = date
    }

    func touchUpdatedAt(_ date: Date = Date()) {
        updatedAt = date
    }

    func toggleFavorite(at date: Date = Date()) {
        isFavorite.toggle()
        updatedAt = date
    }
}
