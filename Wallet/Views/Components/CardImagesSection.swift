import SwiftUI

struct CardImagesSection: View {
    @Bindable var imageState: CardImageState
    let isEditMode: Bool

    var body: some View {
        Section {
            // Front image
            VStack(alignment: .leading, spacing: 8) {
                Text("Front of Card")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                CardImagePickerButton(
                    image: imageState.frontImage,
                    placeholder: "Scan front of card",
                    onScan: {
                        imageState.scannerTarget = .front
                        imageState.showingScanner = true
                    },
                    onLibrary: isEditMode ? { imageState.showingFrontPicker = true } : nil,
                    onEnhance: {
                        imageState.enhanceImage(for: .front, isEditMode: isEditMode)
                    },
                    onRemove: {
                        imageState.removeImage(for: .front, isEditMode: isEditMode)
                    }
                )
            }
            .padding(.vertical, 4)

            // Back image
            VStack(alignment: .leading, spacing: 8) {
                Text("Back of Card (Optional)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                CardImagePickerButton(
                    image: imageState.backImage,
                    placeholder: "Scan back of card",
                    onScan: {
                        imageState.scannerTarget = .back
                        imageState.showingScanner = true
                    },
                    onLibrary: isEditMode ? { imageState.showingBackPicker = true } : nil,
                    onEnhance: {
                        imageState.enhanceImage(for: .back, isEditMode: isEditMode)
                    },
                    onRemove: {
                        imageState.removeImage(for: .back, isEditMode: isEditMode)
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
}
