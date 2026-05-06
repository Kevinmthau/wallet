import SwiftUI
import CoreData
import os

struct CardDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @Environment(CardStore.self) private var cardStore

    let card: Card

    @State private var showingBack = false
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var showingEdit = false
    @State private var showingDeleteConfirmation = false
    @State private var frontDisplayImage: UIImage?
    @State private var backDisplayImage: UIImage?

    private var cardAspectRatio: CGFloat {
        guard let image = frontDisplayImage else { return Constants.CardLayout.aspectRatio }
        let ratio = image.size.width / image.size.height
        AppLogger.ui.debug("Card aspect ratio: \(ratio) (w: \(image.size.width), h: \(image.size.height))")
        return ratio
    }

    private var isPortrait: Bool {
        cardAspectRatio < 1.0
    }

    private var displayImageLoadIdentifier: String {
        [
            CardImageRepository.shared.loadIdentifier(for: card, side: .front, variant: .display),
            CardImageRepository.shared.loadIdentifier(for: card, side: .back, variant: .display)
        ].joined(separator: "|")
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: isPortrait ? 16 : 24) {
                    // Card Image with flip animation
                    FlippableCardView(
                        frontImage: frontDisplayImage,
                        backImage: backDisplayImage,
                        hasBack: card.hasBack,
                        showingBack: $showingBack
                    )
                    .frame(maxWidth: max(0, geometry.size.width - 32))
                    .frame(maxHeight: isPortrait ? geometry.size.height * 0.6 : nil)
                    .aspectRatio(cardAspectRatio, contentMode: .fit)
                    .zoomPanGesture(scale: $scale, offset: $offset)
                    .cardFlipGesture(
                        showingBack: $showingBack,
                        isZoomed: scale > 1,
                        hasDualSides: card.hasBack
                    )

                    // Flip hint
                    if card.hasBack {
                        HStack {
                            Image(systemName: "hand.tap")
                            Text("Tap to flip")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }

                    // Card info
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label(card.category.rawValue, systemImage: card.category.icon)
                                .font(.subheadline)
                                .foregroundStyle(card.category.color)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(card.category.color.opacity(0.1))
                                .clipShape(Capsule())

                            Spacer()

                            if card.isFavorite {
                                Image(systemName: "star.fill")
                                    .foregroundStyle(.yellow)
                            }
                        }

                        if let notes = card.notes, !notes.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Notes")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)

                                Text(notes)
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                            .padding()
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(.horizontal)

                    Spacer()
                }
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(card.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    CardActionMenu(
                        card: card,
                        onEdit: { showingEdit = true },
                        onToggleFavorite: toggleFavorite,
                        onDelete: { showingDeleteConfirmation = true },
                        onCopyNotes: {
                            if let notes = card.notes {
                                UIPasteboard.general.string = notes
                            }
                        }
                    )
                }
            }
            .confirmationDialog("Delete Card", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    AppLogger.ui.info("Deleting card: \(card.name)")
                    let objectID = card.objectID
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + Constants.Animation.dismissActionDelay) {
                        AppLogger.data.info("Executing card deletion")
                        cardStore.delete(objectID: objectID)
                    }
                }
                Button("Cancel", role: .cancel) {
                    AppLogger.ui.info("Card deletion cancelled")
                }
            } message: {
                Text("Are you sure you want to delete this card? This cannot be undone.")
            }
            .sheet(isPresented: $showingEdit) {
                CardFormView(mode: .edit(card))
            }
            .task(id: displayImageLoadIdentifier) {
                await loadDisplayImages()
            }
        }
    }

    private func toggleFavorite() {
        cardStore.toggleFavorite(card)
    }

    @MainActor
    private func loadDisplayImages() async {
        let objectID = card.objectID
        frontDisplayImage = await CardImageRepository.shared.image(
            for: objectID,
            side: .front,
            variant: .display,
            in: context
        )
        backDisplayImage = await CardImageRepository.shared.image(
            for: objectID,
            side: .back,
            variant: .display,
            in: context
        )
    }
}

#Preview {
    let preview = PersistenceController.preview
    let context = preview.container.viewContext
    let cards = (try? context.fetch(Card.makeFetchRequest())) ?? []
    let card = cards.first ?? Card.insert(into: context)
    return CardDetailView(card: card)
        .environment(\.managedObjectContext, context)
        .environment(CardStore(context: preview.container.viewContext))
}
