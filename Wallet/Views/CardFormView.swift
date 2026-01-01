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

    // Consolidated image state
    @State private var imageState: CardImageState

    // Form fields
    @State private var name: String
    @State private var category: CardCategory
    @State private var notes: String
    @State private var showingDeleteConfirmation = false

    @FocusState private var focusedField: FormField?

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
        !name.isEmpty && imageState.frontImage != nil
    }

    init(mode: CardFormMode) {
        self.mode = mode
        switch mode {
        case .add:
            _name = State(initialValue: "")
            _category = State(initialValue: .membership)
            _notes = State(initialValue: "")
            _imageState = State(initialValue: CardImageState())
        case .edit(let card):
            _name = State(initialValue: card.name)
            _category = State(initialValue: card.category)
            _notes = State(initialValue: card.notes ?? "")
            _imageState = State(initialValue: CardImageState(
                frontImage: card.frontImage,
                backImage: card.backImage
            ))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                CardImagesSection(imageState: imageState, isEditMode: isEditMode)
                cardDetailsSection
                notesSection

                if isEditMode {
                    deleteSection
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .cardFormToolbar(
                canSave: canSave,
                onDismissKeyboard: { focusedField = nil },
                onCancel: { dismiss() },
                onSave: save
            )
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
            .cardPhotoPickers(imageState: imageState, isEditMode: isEditMode)
            .scannerOverlay(
                imageState: imageState,
                isEditMode: isEditMode,
                onScanComplete: updateNotesFromOCR
            )
        }
    }

    // MARK: - Sections

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

    private func updateNotesFromOCR() {
        guard notes.isEmpty else { return }

        let allTexts = imageState.collectOCRTexts()
        if !allTexts.isEmpty {
            notes = allTexts.joined(separator: "\n")
        }
    }

    private func save() {
        guard let frontImage = imageState.frontImage else { return }

        switch mode {
        case .add:
            cardStore.addCard(
                name: name,
                category: category,
                frontImage: frontImage,
                backImage: imageState.backImage,
                notes: notes.isEmpty ? nil : notes
            )
        case .edit(let card):
            cardStore.updateCard(
                card,
                name: name,
                category: category,
                frontImage: imageState.frontChanged ? frontImage : nil,
                backImage: imageState.backChanged ? imageState.backImage : nil,
                clearBackImage: imageState.backChanged && imageState.backImage == nil,
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
