import Foundation

enum Constants {
    // MARK: - Image Compression

    /// JPEG compression quality for card images (0.0 - 1.0)
    static let jpegCompressionQuality: CGFloat = 0.8

    // MARK: - Card Layout

    enum CardLayout {
        /// Height of card in the stacked list view
        static let cardHeight: CGFloat = 200

        /// Vertical spacing between stacked cards (collapsed)
        static let cardSpacing: CGFloat = 70

        /// Vertical spacing when a card is expanded
        static let expandedSpacing: CGFloat = 220

        /// Standard credit card aspect ratio (width:height = 1.586:1)
        static let aspectRatio: CGFloat = 1.586

        /// Corner radius for card images
        static let cornerRadius: CGFloat = 16
    }

    // MARK: - Scanner

    enum Scanner {
        /// Number of stable frames required before auto-capture (~1 second at 10fps)
        static let requiredStableFrames = 10

        /// Minimum card area as ratio of frame (3% of frame)
        static let minimumCardAreaRatio: CGFloat = 0.03

        /// Rate at which detection count decays when unstable
        static let detectionDecayRate = 2

        /// Interval between rectangle detection attempts (seconds)
        static let detectionInterval: TimeInterval = 0.1

        /// Timeout for text orientation detection (seconds)
        static let textDetectionTimeout: TimeInterval = 0.5

        /// Maximum text blocks to analyze for orientation
        static let maxTextBlocksForOrientation = 10

        // Rectangle detection parameters
        static let minimumAspectRatio: Float = 0.3
        static let maximumAspectRatio: Float = 3.0
        static let minimumSize: Float = 0.05
        static let minimumConfidence: Float = 0.3
        static let quadratureTolerance: Float = 30
    }

    // MARK: - Gestures

    enum Gestures {
        /// Minimum distance for swipe gesture recognition
        static let swipeMinimumDistance: CGFloat = 20

        /// Vertical distance threshold to dismiss view
        static let swipeDismissThreshold: CGFloat = 100

        /// Zoom scale when double-tapping
        static let doubleTapZoomScale: CGFloat = 2.0

        /// Maximum allowed zoom scale
        static let maxZoomScale: CGFloat = 3.0

        /// Threshold below which zoom snaps back to 1.0
        static let snapToNormalThreshold: CGFloat = 1.2
    }

    // MARK: - Animation

    enum Animation {
        /// Duration of card flip animation
        static let flipDuration: TimeInterval = 0.5

        /// Quick spring response time
        static let quickSpringResponse: TimeInterval = 0.3

        /// Spring damping fraction
        static let springDamping: CGFloat = 0.8

        /// Camera flash effect duration
        static let flashDuration: TimeInterval = 0.15

        /// Progress bar update animation duration
        static let progressUpdateDuration: TimeInterval = 0.1

        enum ElasticStack {
            /// Resistance factor for rubber-band effect (higher = more resistance)
            static let resistance: CGFloat = 0.012

            /// Maximum stretch distance in points
            static let maxStretch: CGFloat = 120

            /// How much extra offset each successive card gets when fanning (multiplier)
            static let fanMultiplier: CGFloat = 0.15
        }
    }

    // MARK: - Image Enhancement

    enum Enhancement {
        /// Default sharpening intensity
        static let defaultSharpness: Float = 0.5

        /// Sharpening for document mode
        static let documentSharpness: Float = 0.8

        /// Contrast for document mode
        static let documentContrast: Float = 1.2

        /// Contrast for black & white mode
        static let bwContrast: Float = 1.3

        /// Unsharp mask radius
        static let unsharpMaskRadius: Float = 2.5

        /// Unsharp mask intensity
        static let unsharpMaskIntensity: Float = 0.5

        /// Noise reduction level
        static let noiseLevel: Float = 0.02

        /// Noise filter sharpness
        static let noiseSharpness: Float = 0.4

        /// Color saturation adjustment
        static let saturation: Float = 1.1
    }

    // MARK: - UI

    enum UI {
        /// Small corner radius (buttons, cards)
        static let smallCornerRadius: CGFloat = 12

        /// Standard horizontal padding
        static let standardPadding: CGFloat = 16

        /// Standard button height
        static let buttonHeight: CGFloat = 44

        /// Manual capture button outer diameter
        static let captureButtonSize: CGFloat = 70

        /// Manual capture button inner diameter
        static let captureButtonInnerSize: CGFloat = 58
    }
}
