import UIKit
import AVFoundation
@preconcurrency import Vision

enum CameraPermissionState {
    case notDetermined
    case authorized
    case denied
    case restricted
}

class CameraManager: NSObject {
    let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "camera.queue")

    var onRectangleDetected: ((VNRectangleObservation?) -> Void)?
    private var photoCaptureCompletion: ((UIImage?) -> Void)?
    private let completionLock = NSLock()

    private(set) var permissionState: CameraPermissionState = .notDetermined

    private var lastDetectionTime = Date()
    private let detectionInterval: TimeInterval = Constants.Scanner.detectionInterval

    override init() {
        super.init()
        updatePermissionState()
    }

    private func updatePermissionState() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            permissionState = .notDetermined
        case .authorized:
            permissionState = .authorized
        case .denied:
            permissionState = .denied
        case .restricted:
            permissionState = .restricted
        @unknown default:
            permissionState = .denied
        }
    }

    func checkPermission() async -> CameraPermissionState {
        updatePermissionState()

        if permissionState == .notDetermined {
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permissionState = granted ? .authorized : .denied
        }

        if permissionState == .authorized {
            setupSession()
        }

        return permissionState
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
        completionLock.lock()
        photoCaptureCompletion = nil
        completionLock.unlock()

        if session.isRunning {
            queue.async {
                self.session.stopRunning()
            }
        }
    }

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        completionLock.lock()
        photoCaptureCompletion = completion
        completionLock.unlock()

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

        // Detection settings from constants
        request.minimumAspectRatio = Constants.Scanner.minimumAspectRatio
        request.maximumAspectRatio = Constants.Scanner.maximumAspectRatio
        request.minimumSize = Constants.Scanner.minimumSize
        request.minimumConfidence = Constants.Scanner.minimumConfidence
        request.maximumObservations = 1
        request.quadratureTolerance = Constants.Scanner.quadratureTolerance

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
        // Capture and clear completion atomically to prevent stale callbacks
        completionLock.lock()
        let completion = photoCaptureCompletion
        photoCaptureCompletion = nil
        completionLock.unlock()

        if let error = error {
            AppLogger.scanner.error("CameraManager: Photo capture error: \(error.localizedDescription)")
        }

        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            AppLogger.scanner.warning("CameraManager: Failed to get image from photo capture")
            DispatchQueue.main.async {
                completion?(nil)
            }
            return
        }

        DispatchQueue.main.async {
            completion?(image)
        }
    }
}
