import SwiftUI
import VisionKit

struct AddCardView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(CardStore.self) private var cardStore

    @State private var name = ""
    @State private var category: CardCategory = .membership
    @State private var notes = ""

    @State private var frontImage: UIImage?
    @State private var backImage: UIImage?

    @State private var showingScanner = false
    @State private var scannerTarget: ScanTarget = .front

    @State private var isEnhancing = false

    enum ScanTarget {
        case front, back
    }

    private var canSave: Bool {
        !name.isEmpty && frontImage != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                // Card Images Section
                Section {
                    // Front Image
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
                            onEnhance: {
                                if let img = frontImage {
                                    enhanceImage(img) { enhanced in
                                        frontImage = enhanced
                                    }
                                }
                            },
                            onRemove: { frontImage = nil }
                        )
                    }
                    .padding(.vertical, 4)

                    // Back Image (Optional)
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
                            onEnhance: {
                                if let img = backImage {
                                    enhanceImage(img) { enhanced in
                                        backImage = enhanced
                                    }
                                }
                            },
                            onRemove: { backImage = nil }
                        )
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Card Images")
                } footer: {
                    Text("Use Scan for best results. Images are automatically enhanced for clarity.")
                }

                // Card Details Section
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

                // Notes Section
                Section {
                    TextField("Member number, expiry date, etc.", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("Notes")
                } footer: {
                    Text("Add any important information you want to remember about this card.")
                }
            }
            .navigationTitle("Add Card")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saveCard()
                    }
                    .disabled(!canSave)
                }
            }
            .fullScreenCover(isPresented: $showingScanner) {
                AutoCaptureScanner { scannedImage in
                    // Enhance the captured image
                    let enhanced = ImageEnhancer.shared.enhance(scannedImage)
                    switch scannerTarget {
                    case .front:
                        frontImage = enhanced
                    case .back:
                        backImage = enhanced
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

    private func enhanceImage(_ image: UIImage, completion: @escaping (UIImage) -> Void) {
        isEnhancing = true
        ImageEnhancer.shared.enhanceAsDocumentAsync(image) { enhanced in
            completion(enhanced)
            isEnhancing = false
        }
    }

    private func saveCard() {
        guard let frontImage = frontImage else { return }

        cardStore.addCard(
            name: name,
            category: category,
            frontImage: frontImage,
            backImage: backImage,
            notes: notes.isEmpty ? nil : notes
        )
        dismiss()
    }
}

#Preview {
    AddCardView()
}
