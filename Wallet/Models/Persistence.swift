import CoreData
import Combine

struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer

    /// Publisher for remote CloudKit changes - subscribe to refresh UI when other devices sync
    let remoteChangePublisher = PassthroughSubject<Void, Never>()

    /// Stored observer token for CloudKit remote change notifications
    private let remoteChangeObserver: NSObjectProtocol

    init(inMemory: Bool = false) {
        // Create the managed object model programmatically
        let model = NSManagedObjectModel()

        // Define Card entity
        let cardEntity = NSEntityDescription()
        cardEntity.name = "Card"
        cardEntity.managedObjectClassName = "Card"

        // Define attributes
        // Note: id is set dynamically when adding cards - not here
        // Setting UUID() here would create ONE UUID shared by all cards (evaluated once at model init)
        let idAttribute = NSAttributeDescription()
        idAttribute.name = "id"
        idAttribute.attributeType = .UUIDAttributeType
        idAttribute.isOptional = true  // CloudKit requires optional or default; we always set in create()

        let nameAttribute = NSAttributeDescription()
        nameAttribute.name = "name"
        nameAttribute.attributeType = .stringAttributeType
        nameAttribute.isOptional = false
        nameAttribute.defaultValue = ""

        let categoryAttribute = NSAttributeDescription()
        categoryAttribute.name = "categoryRaw"
        categoryAttribute.attributeType = .stringAttributeType
        categoryAttribute.isOptional = false
        categoryAttribute.defaultValue = "Other"

        let frontImageAttribute = NSAttributeDescription()
        frontImageAttribute.name = "frontImageData"
        frontImageAttribute.attributeType = .binaryDataAttributeType
        frontImageAttribute.isOptional = true
        frontImageAttribute.allowsExternalBinaryDataStorage = true

        let backImageAttribute = NSAttributeDescription()
        backImageAttribute.name = "backImageData"
        backImageAttribute.attributeType = .binaryDataAttributeType
        backImageAttribute.isOptional = true
        backImageAttribute.allowsExternalBinaryDataStorage = true

        let notesAttribute = NSAttributeDescription()
        notesAttribute.name = "notes"
        notesAttribute.attributeType = .stringAttributeType
        notesAttribute.isOptional = true

        let isFavoriteAttribute = NSAttributeDescription()
        isFavoriteAttribute.name = "isFavorite"
        isFavoriteAttribute.attributeType = .booleanAttributeType
        isFavoriteAttribute.isOptional = false
        isFavoriteAttribute.defaultValue = false

        // Note: createdAt is set dynamically when adding cards - not here
        // Setting Date() here would create ONE Date shared by all cards (evaluated once at model init)
        let createdAtAttribute = NSAttributeDescription()
        createdAtAttribute.name = "createdAt"
        createdAtAttribute.attributeType = .dateAttributeType
        createdAtAttribute.isOptional = true  // CloudKit requires optional or default; we always set in create()

        // Note: lastAccessedAt is set dynamically when adding cards - not here
        let lastAccessedAttribute = NSAttributeDescription()
        lastAccessedAttribute.name = "lastAccessedAt"
        lastAccessedAttribute.attributeType = .dateAttributeType
        lastAccessedAttribute.isOptional = true  // CloudKit requires optional or default; we always set in create()

        cardEntity.properties = [
            idAttribute,
            nameAttribute,
            categoryAttribute,
            frontImageAttribute,
            backImageAttribute,
            notesAttribute,
            isFavoriteAttribute,
            createdAtAttribute,
            lastAccessedAttribute
        ]

        model.entities = [cardEntity]

        container = NSPersistentCloudKitContainer(name: "Wallet", managedObjectModel: model)

        if inMemory {
            container.persistentStoreDescriptions.first?.url = URL(fileURLWithPath: "/dev/null")
        }

        // Configure for CloudKit sync
        if let description = container.persistentStoreDescriptions.first {
            description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(
                containerIdentifier: "iCloud.com.kevinthau.wallet"
            )
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
            description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        } else {
            AppLogger.data.error("PersistenceController: No persistent store description found - CloudKit sync may not work")
        }

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                AppLogger.data.error("PersistenceController: Failed to load persistent store: \(error.localizedDescription), \(error.userInfo)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        // Use store-trump policy for "last write wins" semantics with CloudKit
        // Remote changes take precedence over in-memory changes during merge
        container.viewContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy

        // Observe remote CloudKit changes and notify subscribers
        // Store the observer token to maintain the subscription
        remoteChangeObserver = NotificationCenter.default.addObserver(
            forName: .NSPersistentStoreRemoteChange,
            object: container.persistentStoreCoordinator,
            queue: .main
        ) { [remoteChangePublisher] _ in
            AppLogger.data.info("PersistenceController: Received remote CloudKit change notification")
            remoteChangePublisher.send()
        }
    }

    // Preview helper
    static var preview: PersistenceController = {
        let controller = PersistenceController(inMemory: true)
        let context = controller.container.viewContext

        // Create sample cards for preview
        let sampleCategories: [CardCategory] = [.insurance, .membership, .id, .loyalty]
        let sampleNames = [
            "Blue Cross Insurance",
            "Science Museum",
            "Driver's License",
            "Coffee Rewards"
        ]

        for (index, name) in sampleNames.enumerated() {
            let card = Card(context: context)
            card.id = UUID()
            card.name = name
            card.category = sampleCategories[index]
            card.isFavorite = index == 0
            card.createdAt = Date()
            card.lastAccessedAt = Date().addingTimeInterval(TimeInterval(-index * 3600))
        }

        try? context.save()
        return controller
    }()

    func save() {
        let context = container.viewContext
        if context.hasChanges {
            do {
                try context.save()
            } catch {
                AppLogger.data.error("PersistenceController.save failed: \(error.localizedDescription)")
            }
        }
    }
}
