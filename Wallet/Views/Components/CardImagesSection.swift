import SwiftUI

struct CardImagesSection: View {
    @Bindable var imageState: CardImageState
    let isEditMode: Bool

    var body: some View {
        Section {
            imagePickerSection(
                label: "Front of Card",
                image: imageState.frontImage,
                target: .front,
                placeholder: "Scan front of card"
            )

            imagePickerSection(
                label: "Back of Card (Optional)",
                image: imageState.backImage,
                target: .back,
                placeholder: "Scan back of card"
            )
        } header: {
            Text("Card Images")
        } footer: {
            Text(isEditMode
                 ? "Use Scan for best results. Tap Enhance to improve clarity."
                 : "Use Scan for best results. Images are automatically enhanced for clarity.")
        }
    }

    // MARK: - Private Helpers

    @ViewBuilder
    private func imagePickerSection(
        label: String,
        image: UIImage?,
        target: CardImageState.ScanTarget,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            CardImagePickerButton(
                image: image,
                placeholder: placeholder,
                onScan: {
                    imageState.scannerTarget = target
                    imageState.showingScanner = true
                },
                onLibrary: isEditMode ? {
                    switch target {
                    case .front: imageState.showingFrontPicker = true
                    case .back: imageState.showingBackPicker = true
                    }
                } : nil,
                onEnhance: {
                    imageState.enhanceImage(for: target, isEditMode: isEditMode)
                },
                onRemove: {
                    imageState.removeImage(for: target, isEditMode: isEditMode)
                }
            )
        }
        .padding(.vertical, 4)
    }
}
