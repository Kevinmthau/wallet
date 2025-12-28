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
}
