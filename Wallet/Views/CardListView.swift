import SwiftUI
import CoreData
import os

private enum CardListFilter: String, CaseIterable, Identifiable {
    case all
    case favorites
    case withBack
    case category

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "All Cards"
        case .favorites: return "Favorites"
        case .withBack: return "Dual-Sided"
        case .category: return "Category"
        }
    }
}

private enum CardListSort: String, CaseIterable, Identifiable {
    case recentlyUsed
    case nameAZ
    case nameZA
    case newest
    case oldest

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyUsed: return "Recently Used"
        case .nameAZ: return "Name A-Z"
        case .nameZA: return "Name Z-A"
        case .newest: return "Newest First"
        case .oldest: return "Oldest First"
        }
    }
}

struct CardListView: View {
    @Environment(CardStore.self) private var cardStore

    @FetchRequest(
        sortDescriptors: [
            NSSortDescriptor(keyPath: \Card.isFavorite, ascending: false),
            NSSortDescriptor(keyPath: \Card.lastAccessedAt, ascending: false)
        ],
        animation: .default
    )
    private var allCards: FetchedResults<Card>

    @AppStorage("cardListFilter") private var filterRawValue = CardListFilter.all.rawValue
    @AppStorage("cardListSort") private var sortRawValue = CardListSort.recentlyUsed.rawValue
    @AppStorage("cardListCategory") private var categoryRawValue = CardCategory.membership.rawValue

    @State private var selectedCard: Card?
    @State private var cardToEdit: Card?
    @State private var showingAddCard = false
    @State private var showingSearch = false
    @State private var searchText = ""
    @GestureState private var pullOffset: CGFloat = 0
    @FocusState private var isSearchFocused: Bool

    private let cardHeight = Constants.CardLayout.cardHeight
    private let cardSpacing = Constants.CardLayout.cardSpacing

    private var selectedFilter: CardListFilter {
        CardListFilter(rawValue: filterRawValue) ?? .all
    }

    private var selectedSort: CardListSort {
        CardListSort(rawValue: sortRawValue) ?? .recentlyUsed
    }

    private var selectedCategory: CardCategory {
        CardCategory(rawValue: categoryRawValue) ?? .membership
    }

    private var cards: [Card] {
        let baseCards = Array(allCards)
        let filteredCards = applyFilter(to: baseCards)
        let searchedCards = applySearch(to: filteredCards)
        return applySort(to: searchedCards)
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
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showingSearch.toggle()
                        }
                        if showingSearch {
                            DispatchQueue.main.async {
                                isSearchFocused = true
                            }
                        } else {
                            searchText = ""
                            isSearchFocused = false
                        }
                    } label: {
                        Image(systemName: "magnifyingglass")
                            .font(.body)
                            .fontWeight(.medium)
                            .frame(width: 44, height: 36)
                    }
                    .accessibilityLabel(showingSearch ? "Hide Search" : "Show Search")

                    Divider()
                        .frame(height: 20)

                    Menu {
                        Section("Filter") {
                            Picker("Filter", selection: $filterRawValue) {
                                ForEach(CardListFilter.allCases) { filter in
                                    Text(filter.title).tag(filter.rawValue)
                                }
                            }

                            if selectedFilter == .category {
                                Picker("Category", selection: $categoryRawValue) {
                                    ForEach(CardCategory.allCases) { category in
                                        Label(category.rawValue, systemImage: category.icon)
                                            .tag(category.rawValue)
                                    }
                                }
                            }
                        }

                        Section("Sort") {
                            Picker("Sort", selection: $sortRawValue) {
                                ForEach(CardListSort.allCases) { sort in
                                    Text(sort.title).tag(sort.rawValue)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.body)
                            .fontWeight(.medium)
                            .frame(width: 44, height: 36)
                    }
                    .accessibilityLabel("Filter and Sort")
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

            if showingSearch {
                searchBar
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            // Cards immediately below
            if allCards.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else if cards.isEmpty {
                Spacer()
                noResultsState
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
        .animation(.easeInOut(duration: 0.2), value: showingSearch)
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

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search name or notes", text: $searchText)
                .textInputAutocapitalization(.words)
                .disableAutocorrection(true)
                .focused($isSearchFocused)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 10))
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

    private var noResultsState: some View {
        ContentUnavailableView {
            Label("No Matching Cards", systemImage: "magnifyingglass")
        } description: {
            Text("Try adjusting search, filter, or sort settings.")
        } actions: {
            if !searchText.isEmpty {
                Button("Clear Search") {
                    searchText = ""
                }
            }
            Button("Reset Filters") {
                filterRawValue = CardListFilter.all.rawValue
                sortRawValue = CardListSort.recentlyUsed.rawValue
            }
        }
    }

    private var stackedHeight: CGFloat {
        cardHeight + CGFloat(max(0, cards.count - 1)) * cardSpacing
    }

    private func applySearch(to cards: [Card]) -> [Card] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return cards }

        return cards.filter { card in
            card.name.localizedCaseInsensitiveContains(query)
                || (card.notes?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }

    private func applyFilter(to cards: [Card]) -> [Card] {
        switch selectedFilter {
        case .all:
            return cards
        case .favorites:
            return cards.filter { $0.isFavorite }
        case .withBack:
            return cards.filter { $0.hasBack }
        case .category:
            return cards.filter { $0.category == selectedCategory }
        }
    }

    private func applySort(to cards: [Card]) -> [Card] {
        switch selectedSort {
        case .recentlyUsed:
            return cards.sorted {
                ($0.lastAccessedAt ?? .distantPast) > ($1.lastAccessedAt ?? .distantPast)
            }
        case .nameAZ:
            return cards.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        case .nameZA:
            return cards.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedDescending
            }
        case .newest:
            return cards.sorted {
                ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
            }
        case .oldest:
            return cards.sorted {
                ($0.createdAt ?? .distantFuture) < ($1.createdAt ?? .distantFuture)
            }
        }
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
