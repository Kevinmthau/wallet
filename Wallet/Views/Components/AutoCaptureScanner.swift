import SwiftUI
import AVFoundation
@preconcurrency import Vision

/// Result from card scanning containing image and optional OCR data
struct ScanResult {
    let image: UIImage
    let extractedText: OCRExtractionResult?

    init(image: UIImage, extractedText: OCRExtractionResult? = nil) {
        self.image = image
        self.extractedText = extractedText
    }
}

struct AutoCaptureScanner: View {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (ScanResult) -> Void

    @StateObject private var camera = CameraManager()
    @State private var detectedRectangle: VNRectangleObservation?
    @State private var isCapturing = false
    @State private var isProcessingOCR = false
    @State private var captureProgress: CGFloat = 0
    @State private var showFlash = false
    @State private var stableFrameCount = 0

    private let requiredStableFrames = Constants.Scanner.requiredStableFrames

    var body: some View {
        ZStack {
            // Camera preview
            CameraPreviewView(session: camera.session)
                .ignoresSafeArea()

            // Detection overlay
            GeometryReader { geometry in
                if let rect = detectedRectangle {
                    CardOverlay(
                        observation: rect,
                        size: geometry.size,
                        progress: captureProgress
                    )
                }
            }

            // Flash effect
            if showFlash {
                Color.white
                    .ignoresSafeArea()
                    .transition(.opacity)
            }

            // OCR processing indicator
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

            // UI overlay
            VStack {
                // Top bar
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.5))
                            .clipShape(Circle())
                    }
                    Spacer()
                }
                .padding()

                Spacer()

                // Instructions and manual capture
                VStack(spacing: 16) {
                    VStack(spacing: 8) {
                        if detectedRectangle != nil {
                            if captureProgress > 0 {
                                Text("Hold steady...")
                                    .font(.headline)
                            } else {
                                Text("Card detected")
                                    .font(.headline)
                            }
                        } else {
                            Text("Position card in frame")
                                .font(.headline)
                        }
                        Text("Auto-captures when steady")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .foregroundStyle(.white)
                    .padding()
                    .background(.black.opacity(0.6))
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                    // Manual capture button
                    Button {
                        manualCapture()
                    } label: {
                        ZStack {
                            Circle()
                                .stroke(.white, lineWidth: 4)
                                .frame(width: 70, height: 70)
                            Circle()
                                .fill(.white)
                                .frame(width: 58, height: 58)
                        }
                    }
                }
                .padding(.bottom, 30)
            }
        }
        .onAppear {
            camera.start()
            camera.onRectangleDetected = { observation in
                handleRectangleDetection(observation)
            }
        }
        .onDisappear {
            camera.stop()
        }
    }

    // MARK: - Detection Handling

    private func handleRectangleDetection(_ observation: VNRectangleObservation?) {
        guard !isCapturing else { return }

        if let observation = observation {
            let area = observation.boundingBox.width * observation.boundingBox.height
            if area > Constants.Scanner.minimumCardAreaRatio {
                detectedRectangle = observation
                stableFrameCount += 1

                // Update progress
                let progress = min(CGFloat(stableFrameCount) / CGFloat(requiredStableFrames), 1.0)
                withAnimation(.linear(duration: 0.1)) {
                    captureProgress = progress
                }

                // Capture when stable enough
                if stableFrameCount >= requiredStableFrames {
                    captureImage()
                }
            } else {
                resetDetection()
            }
        } else {
            resetDetection()
        }
    }

    private func resetDetection() {
        if stableFrameCount > 0 {
            stableFrameCount = max(0, stableFrameCount - Constants.Scanner.detectionDecayRate)
            let progress = CGFloat(stableFrameCount) / CGFloat(requiredStableFrames)
            withAnimation(.linear(duration: 0.1)) {
                captureProgress = progress
            }
            if stableFrameCount == 0 {
                detectedRectangle = nil
            }
        }
    }

    // MARK: - Capture

    private func manualCapture() {
        performCapture(with: detectedRectangle)
    }

    private func captureImage() {
        guard detectedRectangle != nil else { return }
        performCapture(with: detectedRectangle)
    }

    /// Unified capture method that handles both auto and manual capture
    private func performCapture(with observation: VNRectangleObservation?) {
        guard !isCapturing else { return }
        isCapturing = true

        triggerFlash()

        camera.capturePhoto { image in
            guard let image = image else {
                self.dismiss()
                return
            }

            Task {
                let finalImage = await self.processCapture(image: image, observation: observation)

                self.isProcessingOCR = true
                let ocrResult = await OCRExtractor.shared.extractText(from: finalImage)

                await MainActor.run {
                    self.isProcessingOCR = false
                    self.onCapture(ScanResult(image: finalImage, extractedText: ocrResult))
                    self.dismiss()
                }
            }
        }
    }

    /// Processes captured image with perspective correction and orientation fix
    private func processCapture(image: UIImage, observation: VNRectangleObservation?) async -> UIImage {
        let orientedImage = CardImageProcessor.shared.fixImageOrientation(image)

        if let observation = observation {
            // Use async perspective correction (includes orientation check)
            return await CardImageProcessor.shared.correctPerspectiveAsync(
                image: orientedImage,
                observation: observation
            ) ?? orientedImage
        } else {
            // No rectangle detected - use async orientation check
            return await CardImageProcessor.shared.ensureProperOrientationAsync(orientedImage)
        }
    }

    private func triggerFlash() {
        withAnimation(.easeIn(duration: 0.1)) {
            showFlash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.1)) {
                showFlash = false
            }
        }
    }
}
