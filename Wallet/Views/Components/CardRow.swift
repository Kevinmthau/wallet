import SwiftUI

struct CardRow: View {
    let card: Card
    var onFavoriteToggle: (() -> Void)?

    var body: some View {
        HStack(spacing: 16) {
            // Card thumbnail
            Group {
                if let image = card.frontImage {
                    Image(uiImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Rectangle()
                        .fill(card.category.color.opacity(0.2))
                        .overlay {
                            Image(systemName: card.category.icon)
                                .font(.title2)
                                .foregroundStyle(card.category.color)
                        }
                }
            }
            .frame(width: 80, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)

            // Card info
            VStack(alignment: .leading, spacing: 4) {
                Text(card.name)
                    .font(.headline)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Image(systemName: card.category.icon)
                        .font(.caption)
                    Text(card.category.rawValue)
                        .font(.caption)
                }
                .foregroundStyle(.secondary)
            }

            Spacer()

            // Favorite indicator
            if card.isFavorite {
                Image(systemName: "star.fill")
                    .foregroundStyle(.yellow)
                    .font(.subheadline)
            }

            // Has back indicator
            if card.hasBack {
                Image(systemName: "rectangle.on.rectangle.angled")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .swipeActions(edge: .leading) {
            Button {
                onFavoriteToggle?()
            } label: {
                Label(
                    card.isFavorite ? "Unfavorite" : "Favorite",
                    systemImage: card.isFavorite ? "star.slash" : "star.fill"
                )
            }
            .tint(.yellow)
        }
    }
}

#Preview {
    List {
        CardRow(card: Card())
    }
}
