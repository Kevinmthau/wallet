import SwiftUI

/// ViewModifier that adds scanner fullscreen cover and enhancement progress overlay
struct ScannerOverlayModifier: ViewModifier {
    @Bindable var imageState: CardImageState
    let isEditMode: Bool
    let onScanComplete: () -> Void

    func body(content: Content) -> some View {
        content
            .fullScreenCover(isPresented: $imageState.showingScanner) {
                AutoCaptureScanner { scanResult in
                    imageState.handleScanResult(scanResult, isEditMode: isEditMode)
                    onScanComplete()
                }
            }
            .overlay {
                if imageState.isEnhancing {
                    EnhancingOverlay()
                }
            }
    }
}

/// Overlay shown while image enhancement is in progress
private struct EnhancingOverlay: View {
    var body: some View {
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

extension View {
    func scannerOverlay(
        imageState: CardImageState,
        isEditMode: Bool,
        onScanComplete: @escaping () -> Void
    ) -> some View {
        modifier(ScannerOverlayModifier(
            imageState: imageState,
            isEditMode: isEditMode,
            onScanComplete: onScanComplete
        ))
    }
}
