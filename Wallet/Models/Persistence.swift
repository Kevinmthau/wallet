import CoreData

struct PersistenceController {
    static let shared = PersistenceController()

    let container: NSPersistentCloudKitContainer

    init(inMemory: Bool = false) {
        // Create the managed object model programmatically
        let model = NSManagedObjectModel()

        // Define Card entity
        let cardEntity = NSEntityDescription()
        cardEntity.name = "Card"
        cardEntity.managedObjectClassName = "Card"

        // Define attributes
        let idAttribute = NSAttributeDescription()
        idAttribute.name = "id"
        idAttribute.attributeType = .UUIDAttributeType
        idAttribute.isOptional = false
        idAttribute.defaultValue = UUID()

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

        let createdAtAttribute = NSAttributeDescription()
        createdAtAttribute.name = "createdAt"
        createdAtAttribute.attributeType = .dateAttributeType
        createdAtAttribute.isOptional = false
        createdAtAttribute.defaultValue = Date()

        let lastAccessedAttribute = NSAttributeDescription()
        lastAccessedAttribute.name = "lastAccessedAt"
        lastAccessedAttribute.attributeType = .dateAttributeType
        lastAccessedAttribute.isOptional = false
        lastAccessedAttribute.defaultValue = Date()

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
        guard let description = container.persistentStoreDescriptions.first else {
            fatalError("No persistent store description found")
        }

        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)

        container.loadPersistentStores { _, error in
            if let error = error as NSError? {
                fatalError("Unresolved error \(error), \(error.userInfo)")
            }
        }

        container.viewContext.automaticallyMergesChangesFromParent = true
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
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
                print("Error saving context: \(error)")
            }
        }
    }
}
