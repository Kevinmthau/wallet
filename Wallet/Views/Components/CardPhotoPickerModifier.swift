import SwiftUI
import PhotosUI

/// ViewModifier that adds photo picker bindings and change handlers for card images
struct CardPhotoPickerModifier: ViewModifier {
    @Bindable var imageState: CardImageState
    let isEditMode: Bool

    func body(content: Content) -> some View {
        content
            .photosPicker(
                isPresented: $imageState.showingFrontPicker,
                selection: $imageState.selectedFrontItem,
                matching: .images
            )
            .photosPicker(
                isPresented: $imageState.showingBackPicker,
                selection: $imageState.selectedBackItem,
                matching: .images
            )
            .onChange(of: imageState.selectedFrontItem) { _, item in
                imageState.loadAndEnhanceImage(from: item, for: .front, isEditMode: isEditMode)
            }
            .onChange(of: imageState.selectedBackItem) { _, item in
                imageState.loadAndEnhanceImage(from: item, for: .back, isEditMode: isEditMode)
            }
    }
}

extension View {
    func cardPhotoPickers(imageState: CardImageState, isEditMode: Bool) -> some View {
        modifier(CardPhotoPickerModifier(imageState: imageState, isEditMode: isEditMode))
    }
}
