import UIKit
import AVFoundation
@preconcurrency import Vision

class CameraManager: NSObject, ObservableObject {
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

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            AppLogger.scanner.error("CameraManager: No back camera available")
            session.commitConfiguration()
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
            }
        } catch {
            AppLogger.scanner.error("CameraManager: Failed to create camera input: \(error.localizedDescription)")
            session.commitConfiguration()
            return
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
            if let error = error {
                AppLogger.scanner.error("CameraManager: Rectangle detection callback error: \(error.localizedDescription)")
            }

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
        do {
            try handler.perform([request])
        } catch {
            AppLogger.scanner.error("CameraManager: Rectangle detection failed: \(error.localizedDescription)")
        }
    }
}

extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = Date()
        guard now.timeIntervalSince(lastDetectionTime) >= detectionInterval else { return }
        lastDetectionTime = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        detectRectangle(in: pixelBuffer)
    }
}

extension CameraManager: AVCapturePhotoCaptureDelegate {
    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error = error {
            AppLogger.scanner.error("CameraManager: Photo capture error: \(error.localizedDescription)")
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            AppLogger.scanner.warning("CameraManager: Failed to get image from photo capture")
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
