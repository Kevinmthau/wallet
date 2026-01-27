import SwiftUI

struct FlippableCardView: View {
    let frontImage: UIImage?
    let backImage: UIImage?
    let hasBack: Bool
    @Binding var showingBack: Bool
    var showPlaceholders: Bool = true

    var body: some View {
        ZStack {
            // Front of card - both sides must render simultaneously for flip animation
            cardSide(image: frontImage, placeholder: "Front")
                .opacity(showingBack ? 0 : 1)
                .rotation3DEffect(
                    .degrees(showingBack ? 180 : 0),
                    axis: (x: 0, y: 1, z: 0)
                )

            // Back of card
            if hasBack {
                cardSide(image: backImage, placeholder: "Back")
                    .opacity(showingBack ? 1 : 0)
                    .rotation3DEffect(
                        .degrees(showingBack ? 0 : -180),
                        axis: (x: 0, y: 1, z: 0)
                    )
            }
        }
    }

    @ViewBuilder
    private func cardSide(image: UIImage?, placeholder: String) -> some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else if showPlaceholders {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemBackground))
                    .overlay {
                        Text(placeholder)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
    }
}
