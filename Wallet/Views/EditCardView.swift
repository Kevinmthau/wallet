import SwiftUI
import PhotosUI
import VisionKit

struct EditCardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    let card: Card

    @State private var name: String
    @State private var category: CardCategory
    @State private var notes: String

    @State private var frontImage: UIImage?
    @State private var backImage: UIImage?
    @State private var frontChanged = false
    @State private var backChanged = false

    @State private var showingFrontPicker = false
    @State private var showingBackPicker = false
    @State private var showingScanner = false
    @State private var scannerTarget: ScanTarget = .front

    @State private var selectedFrontItem: PhotosPickerItem?
    @State private var selectedBackItem: PhotosPickerItem?

    @State private var isEnhancing = false

    enum ScanTarget {
        case front, back
    }

    init(card: Card) {
        self.card = card
        _name = State(initialValue: card.name)
        _category = State(initialValue: card.category)
        _notes = State(initialValue: card.notes ?? "")
        _frontImage = State(initialValue: card.frontImage)
        _backImage = State(initialValue: card.backImage)
    }

    private var canSave: Bool {
        !name.isEmpty && frontImage != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Front of Card")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        imagePickerButton(
                            image: frontImage,
                            placeholder: "Scan front of card",
                            onScan: {
                                scannerTarget = .front
                                showingScanner = true
                            },
                            onLibrary: { showingFrontPicker = true },
                            onEnhance: {
                                if let img = frontImage {
                                    enhanceImage(img) { enhanced in
                                        frontImage = enhanced
                                        frontChanged = true
                                    }
                                }
                            },
                            onRemove: {
                                frontImage = nil
                                frontChanged = true
                            }
                        )
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Back of Card (Optional)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        imagePickerButton(
                            image: backImage,
                            placeholder: "Scan back of card",
                            onScan: {
                                scannerTarget = .back
                                showingScanner = true
                            },
                            onLibrary: { showingBackPicker = true },
                            onEnhance: {
                                if let img = backImage {
                                    enhanceImage(img) { enhanced in
                                        backImage = enhanced
                                        backChanged = true
                                    }
                                }
                            },
                            onRemove: {
                                backImage = nil
                                backChanged = true
                            }
                        )
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Card Images")
                } footer: {
                    Text("Use Scan for best results. Tap Enhance to improve clarity.")
                }

                Section {
                    TextField("Card Name", text: $name)
                        .textContentType(.organizationName)

                    Picker("Category", selection: $category) {
                        ForEach(CardCategory.allCases) { cat in
                            Label(cat.rawValue, systemImage: cat.icon)
                                .tag(cat)
                        }
                    }
                } header: {
                    Text("Details")
                }

                Section {
                    TextField("Member number, expiry date, etc.", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Notes")
                }
            }
            .navigationTitle("Edit Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveChanges()
                    }
                    .disabled(!canSave)
                }
            }
            .photosPicker(
                isPresented: $showingFrontPicker,
                selection: $selectedFrontItem,
                matching: .images
            )
            .photosPicker(
                isPresented: $showingBackPicker,
                selection: $selectedBackItem,
                matching: .images
            )
            .onChange(of: selectedFrontItem) { _, item in
                loadAndEnhanceImage(from: item) { image in
                    frontImage = image
                    frontChanged = true
                }
            }
            .onChange(of: selectedBackItem) { _, item in
                loadAndEnhanceImage(from: item) { image in
                    backImage = image
                    backChanged = true
                }
            }
            .fullScreenCover(isPresented: $showingScanner) {
                AutoCaptureScanner { scannedImage in
                    let enhanced = ImageEnhancer.shared.enhance(scannedImage)
                    switch scannerTarget {
                    case .front:
                        frontImage = enhanced
                        frontChanged = true
                    case .back:
                        backImage = enhanced
                        backChanged = true
                    }
                }
            }
            .overlay {
                if isEnhancing {
                    ZStack {
                        Color.black.opacity(0.3)
                        ProgressView("Enhancing...")
                            .padding()
                            .background(.regularMaterial)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                    }
                    .ignoresSafeArea()
                }
            }
        }
    }

    @ViewBuilder
    private func imagePickerButton(
        image: UIImage?,
        placeholder: String,
        onScan: @escaping () -> Void,
        onLibrary: @escaping () -> Void,
        onEnhance: @escaping () -> Void,
        onRemove: @escaping () -> Void
    ) -> some View {
        if let image = image {
            VStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxHeight: 150)
                        .clipShape(RoundedRectangle(cornerRadius: 12))

                    Button {
                        onRemove()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                    }
                    .offset(x: 8, y: -8)
                }

                HStack(spacing: 12) {
                    Button {
                        onScan()
                    } label: {
                        Label("Rescan", systemImage: "doc.viewfinder")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)

                    Button {
                        onEnhance()
                    } label: {
                        Label("Enhance", systemImage: "wand.and.stars")
                            .font(.caption)
                    }
                    .buttonStyle(.bordered)
                }
            }
        } else {
            Menu {
                Button {
                    onScan()
                } label: {
                    Label("Scan Card", systemImage: "doc.viewfinder")
                }

                Button {
                    onLibrary()
                } label: {
                    Label("Choose from Library", systemImage: "photo.on.rectangle")
                }
            } label: {
                HStack {
                    Image(systemName: "doc.viewfinder")
                    Text(placeholder)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
    }

    private func loadAndEnhanceImage(from item: PhotosPickerItem?, completion: @escaping (UIImage?) -> Void) {
        guard let item = item else { return }

        isEnhancing = true
        item.loadTransferable(type: Data.self) { result in
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    if let data = data, let image = UIImage(data: data) {
                        let enhanced = ImageEnhancer.shared.enhance(image)
                        completion(enhanced)
                    }
                case .failure:
                    completion(nil)
                }
                isEnhancing = false
            }
        }
    }

    private func enhanceImage(_ image: UIImage, completion: @escaping (UIImage) -> Void) {
        isEnhancing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let enhanced = ImageEnhancer.shared.enhanceAsDocument(image)
            DispatchQueue.main.async {
                completion(enhanced)
                isEnhancing = false
            }
        }
    }

    private func saveChanges() {
        card.name = name
        card.category = category
        card.notes = notes.isEmpty ? nil : notes

        if frontChanged, let frontImage = frontImage {
            card.frontImageData = frontImage.jpegData(compressionQuality: 0.8)
        }

        if backChanged {
            card.backImageData = backImage?.jpegData(compressionQuality: 0.8)
        }

        try? viewContext.save()
        dismiss()
    }
}
