import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

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
            .fileImporter(
                isPresented: $imageState.showingFileImporter,
                allowedContentTypes: CardFileImageImporter.allowedContentTypes
            ) { result in
                handleFileImport(result, for: imageState.fileImporterTarget)
            }
            .onChange(of: imageState.selectedFrontItem) { _, item in
                imageState.loadAndEnhanceImage(from: item, for: .front, isEditMode: isEditMode)
            }
            .onChange(of: imageState.selectedBackItem) { _, item in
                imageState.loadAndEnhanceImage(from: item, for: .back, isEditMode: isEditMode)
            }
    }

    private func handleFileImport(_ result: Result<URL, Error>, for target: CardImageState.ScanTarget) {
        imageState.showingFileImporter = false

        switch result {
        case .success(let url):
            imageState.loadAndEnhanceImage(fromFileAt: url, for: target, isEditMode: isEditMode)
        case .failure(let error):
            guard !isUserCancelled(error) else { return }
            imageState.importErrorMessage = error.localizedDescription
            AppLogger.ui.error("CardPhotoPickerModifier: File import failed: \(error.localizedDescription)")
        }
    }

    private func isUserCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }
}

extension View {
    func cardPhotoPickers(imageState: CardImageState, isEditMode: Bool) -> some View {
        modifier(CardPhotoPickerModifier(imageState: imageState, isEditMode: isEditMode))
    }
}
