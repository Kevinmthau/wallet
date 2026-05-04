import SwiftUI
import VisionKit

struct DocumentScannerView: View {
    static var isSupported: Bool {
        VNDocumentCameraViewController.isSupported
    }

    @Environment(\.dismiss) private var dismiss
    @State private var isProcessingOCR = false

    let onCapture: (ScanResult) -> Void

    var body: some View {
        ZStack {
            DocumentCameraController(
                onScan: handleScan,
                onCancel: {
                    dismiss()
                },
                onFailure: { error in
                    AppLogger.scanner.error("DocumentScannerView: Scan failed: \(error.localizedDescription)")
                    dismiss()
                }
            )
            .ignoresSafeArea()

            if isProcessingOCR {
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(1.5)
                        .tint(.white)
                    Text("Extracting text...")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                }
                .padding(24)
                .background(.black.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    private func handleScan(_ scan: VNDocumentCameraScan) {
        guard scan.pageCount > 0 else {
            dismiss()
            return
        }

        let image = scan.imageOfPage(at: 0)
        isProcessingOCR = true

        Task {
            let ocrResult = await OCRExtractor.shared.extractText(from: image)

            await MainActor.run {
                isProcessingOCR = false
                onCapture(ScanResult(image: image, extractedText: ocrResult))
                dismiss()
            }
        }
    }
}

private struct DocumentCameraController: UIViewControllerRepresentable {
    let onScan: @MainActor (VNDocumentCameraScan) -> Void
    let onCancel: @MainActor () -> Void
    let onFailure: @MainActor (Error) -> Void

    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onScan: onScan,
            onCancel: onCancel,
            onFailure: onFailure
        )
    }

    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        private let onScan: @MainActor (VNDocumentCameraScan) -> Void
        private let onCancel: @MainActor () -> Void
        private let onFailure: @MainActor (Error) -> Void

        init(
            onScan: @MainActor @escaping (VNDocumentCameraScan) -> Void,
            onCancel: @MainActor @escaping () -> Void,
            onFailure: @MainActor @escaping (Error) -> Void
        ) {
            self.onScan = onScan
            self.onCancel = onCancel
            self.onFailure = onFailure
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFinishWith scan: VNDocumentCameraScan
        ) {
            Task { @MainActor in
                onScan(scan)
            }
        }

        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) {
            Task { @MainActor in
                onCancel()
            }
        }

        func documentCameraViewController(
            _ controller: VNDocumentCameraViewController,
            didFailWithError error: Error
        ) {
            Task { @MainActor in
                onFailure(error)
            }
        }
    }
}

struct ScannerUnavailableView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 50))
                    .foregroundStyle(.white.opacity(0.6))

                Text("Scanner Unavailable")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)

                Text("Document scanning requires a device with a supported camera.")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)

                Button {
                    dismiss()
                } label: {
                    Text("Close")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 24)
                        .padding(.vertical, 12)
                        .background(.blue)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
            .padding(32)
        }
    }
}
