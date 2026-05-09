import SwiftUI

struct CardImagesSection: View {
    @Bindable var imageState: CardImageState
    let isEditMode: Bool
    let onEnhance: (CardImageState.ScanTarget) -> Void

    var body: some View {
        Section {
            imagePickerSection(
                label: "Front of Card",
                image: imageState.frontImage,
                target: .front,
                placeholder: "Add front of card"
            )

            imagePickerSection(
                label: "Back of Card (Optional)",
                image: imageState.backImage,
                target: .back,
                placeholder: "Add back of card"
            )
        } header: {
            Text("Card Images")
        } footer: {
            Text(isEditMode
                 ? "Scan, choose a photo, or import an image/PDF file. Tap Enhance to improve clarity."
                 : "Scan, choose a photo, or import an image/PDF file. Images are automatically enhanced for clarity.")
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
                onLibrary: {
                    switch target {
                    case .front: imageState.showingFrontPicker = true
                    case .back: imageState.showingBackPicker = true
                    }
                },
                onFile: {
                    imageState.showFileImporter(for: target)
                },
                onEnhance: {
                    onEnhance(target)
                },
                onRemove: {
                    imageState.removeImage(for: target, isEditMode: isEditMode)
                }
            )
        }
        .padding(.vertical, 4)
    }
}
