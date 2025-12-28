import SwiftUI
import PhotosUI
import VisionKit

struct EditCardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CardStore.self) private var cardStore

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

                        CardImagePickerButton(
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

                        CardImagePickerButton(
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
        ImageEnhancer.shared.enhanceAsDocumentAsync(image) { enhanced in
            completion(enhanced)
            isEnhancing = false
        }
    }

    private func saveChanges() {
        cardStore.updateCard(
            card,
            name: name,
            category: category,
            frontImage: frontChanged ? frontImage : nil,
            backImage: backChanged ? backImage : nil,
            clearBackImage: backChanged && backImage == nil,
            notes: notes.isEmpty ? nil : notes
        )
        dismiss()
    }
}
