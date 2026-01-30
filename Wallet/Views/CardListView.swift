import SwiftUI
import CoreData
import os

struct CardListView: View {
    @Environment(\.managedObjectContext) private var viewContext
    @Environment(CardStore.self) private var cardStore

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Card.isFavorite, ascending: false),
            NSSortDescriptor(keyPath: \Card.lastAccessedAt, ascending: false)
        ],
        animation: .default
    )
    private var allCards: FetchedResults<Card>

    @State private var selectedCard: Card?
    @State private var cardToEdit: Card?
    @State private var showingAddCard = false
    @GestureState private var pullOffset: CGFloat = 0

    private let cardHeight = Constants.CardLayout.cardHeight
    private let cardSpacing = Constants.CardLayout.cardSpacing

    private var cards: [Card] {
        Array(allCards)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Apple Wallet style header
            HStack {
                Text("Wallet")
                    .font(.largeTitle)
                    .fontWeight(.bold)

                Spacer()

                // Button group in white pill
                HStack(spacing: 0) {
                    Button {
                        showingAddCard = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.body)
                            .fontWeight(.medium)
                            .frame(width: 44, height: 36)
                    }

                    Divider()
                        .frame(height: 20)

                    Button {
                        // Search action (placeholder)
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.body)
                            .fontWeight(.medium)
                            .frame(width: 44, height: 36)
                    }

                    Divider()
                        .frame(height: 20)

                    Button {
                        // More action (placeholder)
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body)
                            .fontWeight(.medium)
                            .frame(width: 44, height: 36)
                    }
                }
                .foregroundStyle(.primary)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.systemBackground))
                        .shadow(color: .black.opacity(0.08), radius: 2, x: 0, y: 1)
                )
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)

            // Cards immediately below
            if allCards.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else {
                cardStack
                Spacer(minLength: 0)
            }
        }
        .background(
            LinearGradient(
                colors: [Color(.systemBackground), Color(.systemGray6)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .sheet(isPresented: $showingAddCard) {
            CardFormView(mode: .add)
        }
        .sheet(item: $cardToEdit) { card in
            CardFormView(mode: .edit(card))
        }
        .fullScreenCover(item: $selectedCard) { card in
            FullScreenCardView(card: card)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Cards", systemImage: "wallet.pass")
        } description: {
            Text("Add your membership cards, IDs, and more")
        } actions: {
            Button("Add Card") {
                showingAddCard = true
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var stackedHeight: CGFloat {
        cardHeight + CGFloat(max(0, cards.count - 1)) * cardSpacing
    }

    private func elasticOffset(_ drag: CGFloat) -> CGFloat {
        guard drag > 0 else { return 0 }
        return Constants.Animation.ElasticStack.maxStretch * tanh(drag * Constants.Animation.ElasticStack.resistance)
    }

    private var cardStack: some View {
        let fanMultiplier = Constants.Animation.ElasticStack.fanMultiplier

        return ZStack(alignment: .top) {
            ForEach(Array(cards.enumerated()), id: \.element.stableId) { index, card in
                let isFrontCard = index == cards.count - 1
                let baseOffset = CGFloat(index) * cardSpacing
                let elasticFanOffset = elasticOffset(pullOffset) * (1 + CGFloat(index) * fanMultiplier)

                CardStackItem(
                    card: card,
                    index: index,
                    totalCards: cards.count,
                    cardHeight: cardHeight,
                    isFrontCard: isFrontCard,
                    onTap: {
                        AppLogger.ui.info("Card tapped: \(card.name) - opening full screen")
                        selectedCard = card
                        cardStore.markAccessed(card)
                    },
                    onLongPress: {
                        cardToEdit = card
                    },
                    onFavoriteToggle: {
                        withAnimation {
                            _ = cardStore.toggleFavorite(card)
                        }
                    },
                    onDelete: {
                        withAnimation {
                            _ = cardStore.delete(card)
                        }
                    }
                )
                .offset(y: baseOffset + elasticFanOffset)
                .zIndex(Double(index))
            }
        }
        .frame(height: stackedHeight, alignment: .top)
        .gesture(
            DragGesture()
                .updating($pullOffset) { value, state, _ in
                    state = value.translation.height
                }
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.5), value: pullOffset)
    }
}

struct CardStackItem: View {
    let card: Card
    let index: Int
    let totalCards: Int
    let cardHeight: CGFloat
    var isFrontCard: Bool = false
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onFavoriteToggle: () -> Void
    let onDelete: () -> Void

    private var cardSpacing: CGFloat { Constants.CardLayout.cardSpacing }

    var body: some View {
        WalletCardView(card: card)
            .frame(height: cardHeight)
            .padding(.horizontal, 16)
            .contentShape(VisibleCardShape(isFrontCard: isFrontCard, cardSpacing: cardSpacing))
            .onTapGesture {
                onTap()
            }
            .contextMenu {
                CardActionMenuContent(
                    card: card,
                    onEdit: onLongPress,
                    onToggleFavorite: onFavoriteToggle,
                    onDelete: onDelete
                )
            }
            .shadow(
                color: .black.opacity(0.15),
                radius: 8,
                x: 0,
                y: 4
            )
    }
}

struct VisibleCardShape: Shape {
    let isFrontCard: Bool
    let cardSpacing: CGFloat

    func path(in rect: CGRect) -> Path {
        if isFrontCard {
            // Front card: entire card is tappable
            return Path(rect)
        } else {
            // Back cards: only the TOP strip (visible portion with label) is tappable
            let visibleRect = CGRect(
                x: rect.minX,
                y: rect.minY,
                width: rect.width,
                height: cardSpacing
            )
            return Path(visibleRect)
        }
    }
}

#Preview {
    CardListView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
