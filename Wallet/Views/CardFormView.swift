import SwiftUI
import PhotosUI

enum CardFormMode {
    case add
    case edit(Card)
}

struct CardFormView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CardStore.self) private var cardStore

    let mode: CardFormMode

    @State private var name: String
    @State private var category: CardCategory
    @State private var notes: String
    @State private var frontImage: UIImage?
    @State private var backImage: UIImage?
    @State private var frontChanged = false
    @State private var backChanged = false

    @State private var showingScanner = false
    @State private var scannerTarget: ScanTarget = .front

    @State private var showingFrontPicker = false
    @State private var showingBackPicker = false
    @State private var selectedFrontItem: PhotosPickerItem?
    @State private var selectedBackItem: PhotosPickerItem?

    @State private var isEnhancing = false
    @State private var showingDeleteConfirmation = false

    @FocusState private var focusedField: FormField?

    private enum ScanTarget {
        case front, back
    }

    private enum FormField {
        case name, notes
    }

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var cardToEdit: Card? {
        if case .edit(let card) = mode { return card }
        return nil
    }

    private var navigationTitle: String {
        isEditMode ? "Edit Card" : "Add Card"
    }

    private var canSave: Bool {
        !name.isEmpty && frontImage != nil
    }

    init(mode: CardFormMode) {
        self.mode = mode
        switch mode {
        case .add:
            _name = State(initialValue: "")
            _category = State(initialValue: .membership)
            _notes = State(initialValue: "")
            _frontImage = State(initialValue: nil)
            _backImage = State(initialValue: nil)
        case .edit(let card):
            _name = State(initialValue: card.name)
            _category = State(initialValue: card.category)
            _notes = State(initialValue: card.notes ?? "")
            _frontImage = State(initialValue: card.frontImage)
            _backImage = State(initialValue: card.backImage)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                cardImagesSection
                cardDetailsSection
                notesSection

                if isEditMode {
                    deleteSection
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
            .confirmationDialog("Delete Card", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    if let card = cardToEdit {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                            cardStore.delete(card)
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Are you sure you want to delete this card? This cannot be undone.")
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save()
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
                        if isEditMode { frontChanged = true }
                    case .back:
                        backImage = enhanced
                        if isEditMode { backChanged = true }
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

    // MARK: - Sections

    private var cardImagesSection: some View {
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
                    onLibrary: isEditMode ? { showingFrontPicker = true } : nil,
                    onEnhance: {
                        if let img = frontImage {
                            enhanceImage(img) { enhanced in
                                frontImage = enhanced
                                if isEditMode { frontChanged = true }
                            }
                        }
                    },
                    onRemove: {
                        frontImage = nil
                        if isEditMode { frontChanged = true }
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
                    onLibrary: isEditMode ? { showingBackPicker = true } : nil,
                    onEnhance: {
                        if let img = backImage {
                            enhanceImage(img) { enhanced in
                                backImage = enhanced
                                if isEditMode { backChanged = true }
                            }
                        }
                    },
                    onRemove: {
                        backImage = nil
                        if isEditMode { backChanged = true }
                    }
                )
            }
            .padding(.vertical, 4)
        } header: {
            Text("Card Images")
        } footer: {
            Text(isEditMode
                 ? "Use Scan for best results. Tap Enhance to improve clarity."
                 : "Use Scan for best results. Images are automatically enhanced for clarity.")
        }
    }

    private var cardDetailsSection: some View {
        Section {
            TextField("Card Name", text: $name)
                .textContentType(.organizationName)
                .focused($focusedField, equals: .name)

            Picker("Category", selection: $category) {
                ForEach(CardCategory.allCases) { cat in
                    Label(cat.rawValue, systemImage: cat.icon)
                        .tag(cat)
                }
            }
        } header: {
            Text("Details")
        }
    }

    private var notesSection: some View {
        Section {
            TextField("Member number, expiry date, etc.", text: $notes, axis: .vertical)
                .lineLimit(3...6)
                .focused($focusedField, equals: .notes)
        } header: {
            Text("Notes")
        } footer: {
            if !isEditMode {
                Text("Add any important information you want to remember about this card.")
            }
        }
    }

    private var deleteSection: some View {
        Section {
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                HStack {
                    Spacer()
                    Text("Delete Card")
                    Spacer()
                }
            }
        }
    }

    // MARK: - Actions

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

    private func save() {
        guard let frontImage = frontImage else { return }

        switch mode {
        case .add:
            cardStore.addCard(
                name: name,
                category: category,
                frontImage: frontImage,
                backImage: backImage,
                notes: notes.isEmpty ? nil : notes
            )
        case .edit(let card):
            cardStore.updateCard(
                card,
                name: name,
                category: category,
                frontImage: frontChanged ? frontImage : nil,
                backImage: backChanged ? backImage : nil,
                clearBackImage: backChanged && backImage == nil,
                notes: notes.isEmpty ? nil : notes
            )
        }
        dismiss()
    }
}

#Preview("Add Mode") {
    CardFormView(mode: .add)
        .environment(CardStore(context: PersistenceController.preview.container.viewContext))
}
