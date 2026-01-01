import SwiftUI

struct WalletCardView: View {
    let card: Card

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Card background
                RoundedRectangle(cornerRadius: 16)
                    .fill(cardGradient)

                // Card image if available
                if let image = card.frontImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                }

                // Overlay with card info - Apple Wallet style (label at top-left)
                VStack {
                    HStack(alignment: .top) {
                        // Card name at top-left
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.name)
                                .font(.headline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)

                            Text(card.category.rawValue)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.9))
                                .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 1)
                        }

                        Spacer()

                        // Favorite indicator at top-right
                        if card.isFavorite {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                                .font(.title3)
                                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        }

                        // Back card indicator
                        if card.hasBack {
                            Image(systemName: "rectangle.on.rectangle.angled")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                        }
                    }
                    .padding(12)

                    Spacer()
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 16))
        }
    }

    private var cardGradient: LinearGradient {
        LinearGradient(
            colors: [card.category.color, card.category.color.opacity(0.7)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }
}
