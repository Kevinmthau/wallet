import SwiftUI
import AVFoundation
@preconcurrency import Vision

struct AutoCaptureScanner: View {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (UIImage) -> Void

    @StateObject private var camera = CameraManager()
    @State private var detectedRectangle: VNRectangleObservation?
    @State private var isCapturing = false
    @State private var captureProgress: CGFloat = 0
    @State private var showFlash = false
    @State private var stableFrameCount = 0

    private let requiredStableFrames = 10 // ~1 second at 10fps detection rate

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
            if area > 0.03 { // Very small threshold - 3% of frame
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
            stableFrameCount = max(0, stableFrameCount - 2) // Decay slowly
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
        guard !isCapturing else { return }
        isCapturing = true

        triggerFlash()

        camera.capturePhoto { image in
            if let image = image {
                let orientedImage = self.fixImageOrientation(image)
                // If we have a detected rectangle, use it for perspective correction
                if let observation = self.detectedRectangle {
                    let corrected = self.correctPerspective(image: orientedImage, observation: observation)
                    self.onCapture(corrected ?? orientedImage)
                } else {
                    // No rectangle detected, just fix orientation
                    let finalImage = self.ensureProperOrientation(orientedImage)
                    self.onCapture(finalImage)
                }
            }
            self.dismiss()
        }
    }

    private func captureImage() {
        guard let observation = detectedRectangle else { return }
        isCapturing = true

        triggerFlash()

        camera.capturePhoto { image in
            if let image = image {
                // Fix orientation first
                let orientedImage = fixImageOrientation(image)
                // Apply perspective correction
                let corrected = correctPerspective(image: orientedImage, observation: observation)
                onCapture(corrected ?? orientedImage)
            }
            dismiss()
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

    // MARK: - Image Processing

    private func fixImageOrientation(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up {
            return image
        }

        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return normalizedImage ?? image
    }

    private func correctPerspective(image: UIImage, observation: VNRectangleObservation) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return nil }

        let imageSize = ciImage.extent.size

        let topLeft = CGPoint(
            x: observation.topLeft.x * imageSize.width,
            y: observation.topLeft.y * imageSize.height
        )
        let topRight = CGPoint(
            x: observation.topRight.x * imageSize.width,
            y: observation.topRight.y * imageSize.height
        )
        let bottomLeft = CGPoint(
            x: observation.bottomLeft.x * imageSize.width,
            y: observation.bottomLeft.y * imageSize.height
        )
        let bottomRight = CGPoint(
            x: observation.bottomRight.x * imageSize.width,
            y: observation.bottomRight.y * imageSize.height
        )

        let filter = CIFilter.perspectiveCorrection()
        filter.inputImage = ciImage
        filter.topLeft = topLeft
        filter.topRight = topRight
        filter.bottomLeft = bottomLeft
        filter.bottomRight = bottomRight

        guard let output = filter.outputImage else { return nil }

        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }

        // Determine if we need to rotate based on aspect ratio
        let correctedImage = UIImage(cgImage: cgImage)
        return ensureProperOrientation(correctedImage)
    }

    private func ensureProperOrientation(_ image: UIImage) -> UIImage {
        // Use text detection to determine if text is readable
        guard let ciImage = CIImage(image: image) else { return image }

        var needsRotation = false
        let semaphore = DispatchSemaphore(value: 0)

        let request = VNRecognizeTextRequest { request, error in
            defer { semaphore.signal() }

            guard let observations = request.results as? [VNRecognizedTextObservation],
                  !observations.isEmpty else { return }

            // Analyze text bounding boxes to determine if text is sideways
            var horizontalTextCount = 0
            var verticalTextCount = 0

            for observation in observations.prefix(10) {
                let box = observation.boundingBox
                // Text blocks are wider than tall when readable horizontally
                if box.width > box.height {
                    horizontalTextCount += 1
                } else {
                    verticalTextCount += 1
                }
            }

            // If most text appears vertical (sideways), we need to rotate
            needsRotation = verticalTextCount > horizontalTextCount
        }

        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(ciImage: ciImage, options: [:])
        try? handler.perform([request])

        // Wait briefly for detection (with timeout)
        _ = semaphore.wait(timeout: .now() + 0.5)

        // Only rotate if text detection says text is sideways
        if needsRotation {
            return rotateImage(image, by: .pi / 2)
        }

        // Keep original orientation - respect portrait cards
        return image
    }

    private func rotateImage(_ image: UIImage, by radians: CGFloat) -> UIImage {
        let rotatedSize = CGSize(width: image.size.height, height: image.size.width)

        UIGraphicsBeginImageContextWithOptions(rotatedSize, false, image.scale)
        guard let context = UIGraphicsGetCurrentContext() else { return image }

        context.translateBy(x: rotatedSize.width / 2, y: rotatedSize.height / 2)
        context.rotate(by: radians)
        context.translateBy(x: -image.size.width / 2, y: -image.size.height / 2)

        image.draw(at: .zero)

        let rotatedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return rotatedImage ?? image
    }
}
