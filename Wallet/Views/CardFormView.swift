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
    @State private var showingErrorAlert = false
    @State private var isSaving = false

    @FocusState private var focusedField: FormField?

    private enum FormField {
        case name, notes
    }

    private var isEditMode: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var navigationTitle: String {
        isEditMode ? "Edit Card" : "Add Card"
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        !trimmedName.isEmpty && imageState.frontImage != nil && !isSaving
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
            }
            .disabled(isSaving)
            .scrollDismissesKeyboard(.interactively)
            .cardFormToolbar(
                canSave: canSave,
                onDismissKeyboard: { focusedField = nil },
                onCancel: { dismiss() },
                onSave: save
            )
            .alert("Error", isPresented: $showingErrorAlert) {
                Button("OK") {
                    cardStore.clearError()
                }
            } message: {
                Text(cardStore.lastError?.localizedDescription ?? "An unexpected error occurred.")
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .cardPhotoPickers(imageState: imageState, isEditMode: isEditMode)
            .scannerOverlay(
                imageState: imageState,
                isEditMode: isEditMode,
                onScanComplete: updateNotesFromOCR
            )
            .onDisappear {
                imageState.cancelPendingTasks()
            }
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
                .lineLimit(1...)
                .focused($focusedField, equals: .notes)
        } header: {
            Text("Notes")
        } footer: {
            if !isEditMode {
                Text("Add any important information you want to remember about this card.")
            }
        }
    }

    // MARK: - Actions

    private func updateNotesFromOCR() {
        let allTexts = imageState.collectOCRTexts()
        guard !allTexts.isEmpty else { return }

        let newNotes = allTexts.joined(separator: "\n")

        // Update notes if empty OR if notes match previous OCR output (user hasn't manually edited)
        if notes.isEmpty || notes == imageState.lastOCRNotes {
            notes = newNotes
            imageState.lastOCRNotes = newNotes
        }
    }

    private func save() {
        guard let frontImage = imageState.frontImage, !isSaving else { return }
        isSaving = true

        Task { @MainActor in
            let success: Bool
            switch mode {
            case .add:
                success = await cardStore.addCard(
                    name: trimmedName,
                    category: category,
                    frontImage: frontImage,
                    backImage: imageState.backImage,
                    notes: notes.isEmpty ? nil : notes
                )
            case .edit(let card):
                success = await cardStore.updateCard(
                    card,
                    name: trimmedName,
                    category: category,
                    frontImage: imageState.frontChanged ? frontImage : nil,
                    backImage: imageState.backChanged ? imageState.backImage : nil,
                    clearBackImage: imageState.backChanged && imageState.backImage == nil,
                    notes: notes.isEmpty ? nil : notes,
                    clearNotes: notes.isEmpty
                )
            }

            isSaving = false
            if success {
                dismiss()
            } else {
                showingErrorAlert = true
            }
        }
    }
}

#Preview("Add Mode") {
    CardFormView(mode: .add)
        .environment(CardStore(context: PersistenceController.preview.container.viewContext))
}
