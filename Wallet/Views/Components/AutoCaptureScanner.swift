import SwiftUI
import AVFoundation
@preconcurrency import Vision

struct AutoCaptureScanner: View {
    @Environment(\.dismiss) private var dismiss
    let onCapture: (UIImage) -> Void

    @StateObject private var camera = CameraModel()
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

    private func manualCapture() {
        guard !isCapturing else { return }
        isCapturing = true

        // Flash effect
        withAnimation(.easeIn(duration: 0.1)) {
            showFlash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.1)) {
                showFlash = false
            }
        }

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

        // Flash effect
        withAnimation(.easeIn(duration: 0.1)) {
            showFlash = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            withAnimation(.easeOut(duration: 0.1)) {
                showFlash = false
            }
        }

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

// MARK: - Card Overlay

struct CardOverlay: View {
    let observation: VNRectangleObservation
    let size: CGSize
    let progress: CGFloat

    var body: some View {
        ZStack {
            // Corner brackets
            CardCorners(observation: observation, size: size)
                .stroke(
                    progress > 0.5 ? Color.green : Color.white,
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )

            // Progress ring in center
            if progress > 0 {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Color.green, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 50, height: 50)
                    .rotationEffect(.degrees(-90))
                    .position(
                        x: size.width * (observation.boundingBox.midX),
                        y: size.height * (1 - observation.boundingBox.midY)
                    )
            }
        }
    }
}

struct CardCorners: Shape {
    let observation: VNRectangleObservation
    let size: CGSize

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let cornerLength: CGFloat = 30

        let topLeft = CGPoint(
            x: observation.topLeft.x * size.width,
            y: (1 - observation.topLeft.y) * size.height
        )
        let topRight = CGPoint(
            x: observation.topRight.x * size.width,
            y: (1 - observation.topRight.y) * size.height
        )
        let bottomRight = CGPoint(
            x: observation.bottomRight.x * size.width,
            y: (1 - observation.bottomRight.y) * size.height
        )
        let bottomLeft = CGPoint(
            x: observation.bottomLeft.x * size.width,
            y: (1 - observation.bottomLeft.y) * size.height
        )

        // Top-left corner
        path.move(to: CGPoint(x: topLeft.x, y: topLeft.y + cornerLength))
        path.addLine(to: topLeft)
        path.addLine(to: CGPoint(x: topLeft.x + cornerLength, y: topLeft.y))

        // Top-right corner
        path.move(to: CGPoint(x: topRight.x - cornerLength, y: topRight.y))
        path.addLine(to: topRight)
        path.addLine(to: CGPoint(x: topRight.x, y: topRight.y + cornerLength))

        // Bottom-right corner
        path.move(to: CGPoint(x: bottomRight.x, y: bottomRight.y - cornerLength))
        path.addLine(to: bottomRight)
        path.addLine(to: CGPoint(x: bottomRight.x - cornerLength, y: bottomRight.y))

        // Bottom-left corner
        path.move(to: CGPoint(x: bottomLeft.x + cornerLength, y: bottomLeft.y))
        path.addLine(to: bottomLeft)
        path.addLine(to: CGPoint(x: bottomLeft.x, y: bottomLeft.y - cornerLength))

        return path
    }
}

// MARK: - Camera Preview View

class CameraPreviewUIView: UIView {
    var previewLayer: AVCaptureVideoPreviewLayer?

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    func setup(session: AVCaptureSession) {
        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.videoGravity = .resizeAspectFill
        previewLayer.frame = bounds
        layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer
    }
}

struct CameraPreviewView: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> CameraPreviewUIView {
        let view = CameraPreviewUIView()
        view.backgroundColor = .black
        view.setup(session: session)
        return view
    }

    func updateUIView(_ uiView: CameraPreviewUIView, context: Context) {
        uiView.previewLayer?.frame = uiView.bounds
    }
}

// MARK: - Camera Model

class CameraModel: NSObject, ObservableObject {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.queue")

    var onRectangleDetected: ((VNRectangleObservation?) -> Void)?
    private var photoCaptureCompletion: ((UIImage?) -> Void)?

    private var lastDetectionTime = Date()
    private let detectionInterval: TimeInterval = 0.1

    override init() {
        super.init()
        setupSession()
    }

    private func setupSession() {
        session.beginConfiguration()
        session.sessionPreset = .photo

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else {
            session.commitConfiguration()
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        if session.canAddOutput(output) {
            session.addOutput(output)
        }

        videoOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        // Set video orientation
        if let connection = videoOutput.connection(with: .video) {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
        }

        session.commitConfiguration()
    }

    func start() {
        if !session.isRunning {
            queue.async {
                self.session.startRunning()
            }
        }
    }

    func stop() {
        if session.isRunning {
            queue.async {
                self.session.stopRunning()
            }
        }
    }

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        photoCaptureCompletion = completion

        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: self)
    }

    private func detectRectangle(in image: CVPixelBuffer) {
        let request = VNDetectRectanglesRequest { [weak self] request, error in
            guard let results = request.results as? [VNRectangleObservation],
                  let rect = results.first else {
                DispatchQueue.main.async {
                    self?.onRectangleDetected?(nil)
                }
                return
            }

            DispatchQueue.main.async {
                self?.onRectangleDetected?(rect)
            }
        }

        // More forgiving detection settings
        request.minimumAspectRatio = 0.3  // Allow more variety
        request.maximumAspectRatio = 3.0  // Allow portrait cards too
        request.minimumSize = 0.05        // Detect smaller cards (5% of frame)
        request.minimumConfidence = 0.3   // Lower confidence threshold
        request.maximumObservations = 1
        request.quadratureTolerance = 30  // Allow up to 30° angle deviation

        let handler = VNImageRequestHandler(cvPixelBuffer: image, orientation: .up, options: [:])
        try? handler.perform([request])
    }
}

extension CameraModel: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastDetectionTime) >= detectionInterval else { return }
        lastDetectionTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        detectRectangle(in: pixelBuffer)
    }
}

extension CameraModel: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            DispatchQueue.main.async {
                self.photoCaptureCompletion?(nil)
            }
            return
        }

        DispatchQueue.main.async {
            self.photoCaptureCompletion?(image)
        }
    }
}
