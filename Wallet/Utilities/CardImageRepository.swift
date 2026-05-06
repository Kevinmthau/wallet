import UIKit
import ImageIO
import CoreData
@preconcurrency import Dispatch

enum CardImageSide: String, Sendable {
    case front
    case back
}

enum CardImageVariant: String, Sendable {
    case thumbnail
    case display
    case full

    var maxPixelSize: CGFloat? {
        switch self {
        case .thumbnail:
            return Constants.CardLayout.listThumbnailMaxDimension
        case .display:
            return Constants.CardLayout.displayImageMaxDimension
        case .full:
            return nil
        }
    }
}

final class CardImageRepository: @unchecked Sendable {
    static let shared = CardImageRepository()

    private struct LoadedImageData: Sendable {
        let data: Data
        let cacheIdentity: String
        let dataFingerprint: String
    }

    private let displayImageCache = ImageCache(costLimit: 96 * 1024 * 1024)
    private let thumbnailImageCache = ImageCache(costLimit: 48 * 1024 * 1024)

    private let queue = DispatchQueue(
        label: "card.image.repository.queue",
        qos: .userInitiated,
        attributes: .concurrent
    )

    private init() {}

    @MainActor
    func image(
        for card: Card,
        side: CardImageSide,
        variant: CardImageVariant
    ) async -> UIImage? {
        guard let data = card.imageData(for: side) else { return nil }
        return await image(
            from: data,
            cacheIdentity: card.stableId,
            side: side,
            variant: variant
        )
    }

    @MainActor
    func image(
        for objectID: NSManagedObjectID,
        side: CardImageSide,
        variant: CardImageVariant,
        in sourceContext: NSManagedObjectContext
    ) async -> UIImage? {
        guard let persistentStoreCoordinator = sourceContext.persistentStoreCoordinator,
              let loadedImageData = await loadImageData(
                for: objectID,
                side: side,
                persistentStoreCoordinator: persistentStoreCoordinator
              ) else {
            return nil
        }

        return await image(
            from: loadedImageData.data,
            cacheIdentity: loadedImageData.cacheIdentity,
            side: side,
            variant: variant,
            dataFingerprint: loadedImageData.dataFingerprint
        )
    }

    func loadIdentifier(
        for card: Card,
        side: CardImageSide,
        variant: CardImageVariant
    ) -> String {
        let imageVersion = card.imageUpdatedAt(for: side)?.timeIntervalSinceReferenceDate
        let fallbackVersion = card.updatedAt?.timeIntervalSinceReferenceDate ?? 0
        let imageIdentity = imageVersion.map { String($0) } ?? "fallback-\(fallbackVersion)"
        return "\(card.stableId)-\(card.objectID.uriRepresentation().absoluteString)-\(side.rawValue)-\(variant.rawValue)-\(imageIdentity)"
    }

    func image(
        from data: Data,
        cacheIdentity: String,
        side: CardImageSide,
        variant: CardImageVariant
    ) async -> UIImage? {
        await image(
            from: data,
            cacheIdentity: cacheIdentity,
            side: side,
            variant: variant,
            dataFingerprint: Self.dataFingerprint(for: data)
        )
    }

    private func image(
        from data: Data,
        cacheIdentity: String,
        side: CardImageSide,
        variant: CardImageVariant,
        dataFingerprint: String
    ) async -> UIImage? {
        let cache = cache(for: variant)
        let key = cache == nil
            ? nil
            : cacheKey(
                cacheIdentity: cacheIdentity,
                side: side,
                variant: variant,
                dataFingerprint: dataFingerprint
            )

        if let cache, let key, let cachedImage = cache.image(forKey: key) {
            return cachedImage
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            queue.async {
                autoreleasepool {
                    guard let image = Self.decode(data, variant: variant) else {
                        continuation.resume(returning: nil)
                        return
                    }

                    if let cache, let key {
                        cache.setImage(image, forKey: key, cost: Self.imageCost(image))
                    }
                    continuation.resume(returning: image)
                }
            }
        }
    }

    static func resizeIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let pixelSize = image.pixelSize
        guard pixelSize.width > maxDimension || pixelSize.height > maxDimension else {
            return image
        }

        let resizeScale = pixelSize.width > pixelSize.height
            ? maxDimension / pixelSize.width
            : maxDimension / pixelSize.height
        let newSize = CGSize(width: pixelSize.width * resizeScale, height: pixelSize.height * resizeScale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1.0

        return UIGraphicsImageRenderer(size: newSize, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    static func redraw(_ image: UIImage, size: CGSize? = nil, actions: ((CGContext, CGSize) -> Void)? = nil) -> UIImage {
        let renderSize = size ?? image.size
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = image.scale

        return UIGraphicsImageRenderer(size: renderSize, format: format).image { rendererContext in
            if let actions {
                actions(rendererContext.cgContext, renderSize)
            } else {
                image.draw(in: CGRect(origin: .zero, size: renderSize))
            }
        }
    }

    private func cache(for variant: CardImageVariant) -> ImageCache? {
        switch variant {
        case .thumbnail:
            return thumbnailImageCache
        case .display:
            return displayImageCache
        case .full:
            return nil
        }
    }

    private func cacheKey(
        cacheIdentity: String,
        side: CardImageSide,
        variant: CardImageVariant,
        dataFingerprint: String
    ) -> String {
        "\(cacheIdentity)-\(side.rawValue)-\(variant.rawValue)-\(dataFingerprint)"
    }

    private func loadImageData(
        for objectID: NSManagedObjectID,
        side: CardImageSide,
        persistentStoreCoordinator: NSPersistentStoreCoordinator
    ) async -> LoadedImageData? {
        await withCheckedContinuation { continuation in
            let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
            context.persistentStoreCoordinator = persistentStoreCoordinator
            context.undoManager = nil
            context.mergePolicy = NSMergePolicy(merge: .mergeByPropertyStoreTrumpMergePolicyType)

            context.perform {
                autoreleasepool {
                    do {
                        guard let card = try context.existingObject(with: objectID) as? Card,
                              !card.isDeleted,
                              let data = card.imageData(for: side) else {
                            continuation.resume(returning: nil)
                            return
                        }

                        continuation.resume(returning: LoadedImageData(
                            data: data,
                            cacheIdentity: card.stableId,
                            dataFingerprint: Self.dataFingerprint(for: data)
                        ))
                    } catch {
                        AppLogger.data.error("CardImageRepository.loadImageData failed: \(error.localizedDescription)")
                        continuation.resume(returning: nil)
                    }
                }
            }
        }
    }

    private static func decode(_ data: Data, variant: CardImageVariant) -> UIImage? {
        guard let maxPixelSize = variant.maxPixelSize else {
            return UIImage(data: data)
        }

        return downsample(data, maxPixelSize: maxPixelSize)
    }

    private static func downsample(_ data: Data, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
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

    static func dataFingerprint(for data: Data) -> String {
        let prefix = data.prefix(16).map { String(format: "%02x", $0) }.joined()
        let suffix = data.suffix(16).map { String(format: "%02x", $0) }.joined()
        return "\(data.count)-\(prefix)-\(suffix)"
    }

    private static func imageCost(_ image: UIImage) -> Int {
        let pixelCount = image.size.width * image.size.height * image.scale * image.scale
        return max(1, Int(pixelCount * 4))
    }
}

private final class ImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, UIImage>()

    init(costLimit: Int) {
        cache.totalCostLimit = costLimit
    }

    func image(forKey key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func setImage(_ image: UIImage, forKey key: String, cost: Int) {
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

extension Card {
    func imageData(for side: CardImageSide) -> Data? {
        switch side {
        case .front:
            return frontImageData
        case .back:
            return backImageData
        }
    }

    func imageUpdatedAt(for side: CardImageSide) -> Date? {
        switch side {
        case .front:
            return frontImageUpdatedAt
        case .back:
            return backImageUpdatedAt
        }
    }
}

extension UIImage {
    var pixelSize: CGSize {
        if let cgImage {
            return CGSize(width: cgImage.width, height: cgImage.height)
        }

        return CGSize(width: size.width * scale, height: size.height * scale)
    }
}
