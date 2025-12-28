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
    @State private var isStackExpanded = false
    @State private var searchText = ""

    private let cardHeight = Constants.CardLayout.cardHeight
    private let cardSpacing = Constants.CardLayout.cardSpacing
    private let expandedSpacing = Constants.CardLayout.expandedSpacing

    private var filteredCards: [Card] {
        if searchText.isEmpty {
            return Array(allCards)
        }
        return allCards.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                // Background gradient like Apple Wallet
                LinearGradient(
                    colors: [Color(.systemBackground), Color(.systemGray6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                if allCards.isEmpty {
                    emptyState
                } else {
                    cardStack
                }
            }
            .navigationTitle("Wallet")
            .searchable(text: $searchText, prompt: "Search")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingAddCard = true
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                    }
                }
            }
            .sheet(isPresented: $showingAddCard) {
                AddCardView()
            }
            .sheet(item: $cardToEdit) { card in
                EditCardView(card: card)
            }
            .fullScreenCover(item: $selectedCard) { card in
                FullScreenCardView(card: card)
            }
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

    private var cardStack: some View {
        ScrollView {
            LazyVStack(spacing: isStackExpanded ? 8 : 0) {
                ForEach(Array(filteredCards.enumerated()), id: \.element.id) { index, card in
                    CardStackItem(
                        card: card,
                        index: index,
                        totalCards: filteredCards.count,
                        cardHeight: cardHeight,
                        isStackExpanded: isStackExpanded,
                        onTap: {
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                                if isStackExpanded {
                                    AppLogger.ui.info("Card tapped: \(card.name) - opening full screen")
                                    selectedCard = card
                                    cardStore.markAccessed(card)
                                } else {
                                    AppLogger.ui.info("Stack tapped - expanding cards")
                                    isStackExpanded = true
                                }
                            }
                        },
                        onLongPress: {
                            AppLogger.ui.info("Card long-pressed: \(card.name) - opening edit")
                            cardToEdit = card
                        },
                        onFavoriteToggle: {
                            withAnimation {
                                cardStore.toggleFavorite(card)
                            }
                        },
                        onDelete: {
                            withAnimation {
                                cardStore.delete(card)
                            }
                        }
                    )
                    .zIndex(Double(filteredCards.count - index))
                }
            }
            .padding(.top, 20)
            .padding(.bottom, 100)
        }
        .scrollIndicators(.hidden)
        .background {
            if isStackExpanded {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                            isStackExpanded = false
                        }
                    }
            }
        }
    }
}

struct CardStackItem: View {
    let card: Card
    let index: Int
    let totalCards: Int
    let cardHeight: CGFloat
    let isStackExpanded: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onFavoriteToggle: () -> Void
    let onDelete: () -> Void

    private var cardSpacing: CGFloat { Constants.CardLayout.cardSpacing }

    var body: some View {
        WalletCardView(card: card)
            .frame(height: cardHeight)
            .padding(.horizontal, 16)
            .contentShape(VisibleCardShape(isTopCard: index == 0, isExpanded: isStackExpanded, cardSpacing: cardSpacing))
            .onTapGesture {
                onTap()
            }
            .onLongPressGesture {
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                onLongPress()
            }
            .offset(y: isStackExpanded ? 0 : -CGFloat(index) * (cardHeight - cardSpacing))
            .shadow(
                color: .black.opacity(0.15),
                radius: 8,
                x: 0,
                y: 4
            )
    }
}

struct VisibleCardShape: Shape {
    let isTopCard: Bool
    let isExpanded: Bool
    let cardSpacing: CGFloat

    func path(in rect: CGRect) -> Path {
        if isTopCard || isExpanded {
            return Path(rect)
        } else {
            // Only the bottom strip (visible portion) is tappable
            let visibleRect = CGRect(
                x: rect.minX,
                y: rect.maxY - cardSpacing,
                width: rect.width,
                height: cardSpacing
            )
            return Path(visibleRect)
        }
    }
}

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

                // Overlay with card info
                VStack {
                    HStack {
                        Spacer()

                        // Favorite indicator
                        if card.isFavorite {
                            Image(systemName: "star.fill")
                                .foregroundStyle(.yellow)
                                .font(.title3)
                                .padding(8)
                                .background(.ultraThinMaterial)
                                .clipShape(Circle())
                        }
                    }
                    .padding(12)

                    Spacer()

                    // Card name at bottom
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.name)
                                .font(.headline)
                                .fontWeight(.semibold)
                                .foregroundStyle(.white)
                                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)

                            Text(card.category.rawValue)
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        Spacer()

                        if card.hasBack {
                            Image(systemName: "rectangle.on.rectangle.angled")
                                .font(.caption)
                                .foregroundStyle(.white.opacity(0.7))
                        }
                    }
                    .padding(12)
                    .background(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.5)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
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

#Preview {
    CardListView()
        .environment(\.managedObjectContext, PersistenceController.preview.container.viewContext)
}
