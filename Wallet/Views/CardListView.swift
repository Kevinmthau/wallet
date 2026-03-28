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

struct CardStackLayout {
    let offsets: [CGFloat]
    let visibleHeights: [CGFloat]
    let contentHeight: CGFloat

    init(
        cardCount: Int,
        cardHeight: CGFloat,
        preferredSpacing: CGFloat,
        availableHeight: CGFloat,
        compressionExponent: CGFloat = Constants.CardLayout.compressedStackExponent
    ) {
        let clampedAvailableHeight = max(0, availableHeight)

        guard cardCount > 0 else {
            offsets = []
            visibleHeights = []
            contentHeight = 0
            return
        }

        guard cardCount > 1 else {
            offsets = [0]
            visibleHeights = [cardHeight]
            contentHeight = min(cardHeight, clampedAvailableHeight)
            return
        }

        let availableOffsetRange = max(0, clampedAvailableHeight - cardHeight)
        let naturalLastOffset = CGFloat(cardCount - 1) * preferredSpacing
        let computedOffsets: [CGFloat]

        if naturalLastOffset <= availableOffsetRange {
            computedOffsets = (0..<cardCount).map { CGFloat($0) * preferredSpacing }
        } else if availableOffsetRange == 0 {
            computedOffsets = Array(repeating: 0, count: cardCount)
        } else {
            let maxIndex = CGFloat(cardCount - 1)
            computedOffsets = (0..<cardCount).map { index in
                let progress = CGFloat(index) / maxIndex
                let curvedProgress = CGFloat(pow(Double(progress), Double(compressionExponent)))
                return availableOffsetRange * curvedProgress
            }
        }

        let computedVisibleHeights = (0..<cardCount).map { index in
            guard index < cardCount - 1 else { return cardHeight }
            return max(0, computedOffsets[index + 1] - computedOffsets[index])
        }

        offsets = computedOffsets
        visibleHeights = computedVisibleHeights
        contentHeight = min(clampedAvailableHeight, (computedOffsets.last ?? 0) + cardHeight)
    }

    func offset(for index: Int) -> CGFloat {
        offsets[index]
    }

    func visibleHeight(for index: Int) -> CGFloat {
        visibleHeights[index]
    }
}

struct CardListView: View {
    @Environment(CardStore.self) private var cardStore

    @FetchRequest private var cardPresenceProbe: FetchedResults<Card>
    @FetchRequest private var displayedCards: FetchedResults<Card>

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

    init() {
        let probeRequest = Card.makeFetchRequest()
        probeRequest.sortDescriptors = [NSSortDescriptor(key: Card.Attributes.name, ascending: true)]
        probeRequest.fetchLimit = 1
        probeRequest.includesPropertyValues = false
        probeRequest.returnsObjectsAsFaults = true
        _cardPresenceProbe = FetchRequest(fetchRequest: probeRequest, animation: .default)

        let request = Card.makeFetchRequest()
        request.fetchBatchSize = 40
        request.sortDescriptors = Self.sortDescriptors(for: .recentlyUsed)
        _displayedCards = FetchRequest(fetchRequest: request, animation: .default)
    }

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
        Array(displayedCards)
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
            if cardPresenceProbe.isEmpty {
                Spacer()
                emptyState
                Spacer()
            } else if cards.isEmpty {
                Spacer()
                noResultsState
                Spacer()
            } else {
                cardStack
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
        .onAppear(perform: refreshDisplayedCardsFetch)
        .onChange(of: filterRawValue) { _, _ in
            refreshDisplayedCardsFetch()
        }
        .onChange(of: sortRawValue) { _, _ in
            refreshDisplayedCardsFetch()
        }
        .onChange(of: categoryRawValue) { _, _ in
            refreshDisplayedCardsFetch()
        }
        .onChange(of: searchText) { _, _ in
            refreshDisplayedCardsFetch()
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

    private static func sortDescriptors(for sort: CardListSort) -> [NSSortDescriptor] {
        let nameAscending = NSSortDescriptor(
            key: Card.Attributes.name,
            ascending: true,
            selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
        )
        let nameDescending = NSSortDescriptor(
            key: Card.Attributes.name,
            ascending: false,
            selector: #selector(NSString.localizedCaseInsensitiveCompare(_:))
        )

        switch sort {
        case .recentlyUsed:
            return [
                NSSortDescriptor(key: Card.Attributes.lastAccessedAt, ascending: false),
                nameAscending
            ]
        case .nameAZ:
            return [nameAscending]
        case .nameZA:
            return [nameDescending]
        case .newest:
            return [
                NSSortDescriptor(key: Card.Attributes.createdAt, ascending: false),
                nameAscending
            ]
        case .oldest:
            return [
                NSSortDescriptor(key: Card.Attributes.createdAt, ascending: true),
                nameAscending
            ]
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func makeFetchPredicate() -> NSPredicate? {
        var predicates: [NSPredicate] = []

        switch selectedFilter {
        case .all:
            break
        case .favorites:
            predicates.append(NSPredicate(format: "\(Card.Attributes.isFavorite) == YES"))
        case .withBack:
            predicates.append(NSPredicate(format: "\(Card.Attributes.backImageData) != nil"))
        case .category:
            predicates.append(NSPredicate(format: "\(Card.Attributes.categoryRaw) == %@", selectedCategory.rawValue))
        }

        if !trimmedSearchText.isEmpty {
            predicates.append(NSPredicate(
                format: "(\(Card.Attributes.name) CONTAINS[cd] %@) OR (\(Card.Attributes.notes) CONTAINS[cd] %@)",
                trimmedSearchText,
                trimmedSearchText
            ))
        }

        switch predicates.count {
        case 0:
            return nil
        case 1:
            return predicates[0]
        default:
            return NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }
    }

    private func refreshDisplayedCardsFetch() {
        displayedCards.nsPredicate = makeFetchPredicate()
        displayedCards.nsSortDescriptors = Self.sortDescriptors(for: selectedSort)
    }

    private func elasticOffset(_ drag: CGFloat) -> CGFloat {
        guard drag > 0 else { return 0 }
        return Constants.Animation.ElasticStack.maxStretch * tanh(drag * Constants.Animation.ElasticStack.resistance)
    }

    private var cardStack: some View {
        GeometryReader { geometry in
            let fanMultiplier = Constants.Animation.ElasticStack.fanMultiplier
            let layout = CardStackLayout(
                cardCount: cards.count,
                cardHeight: cardHeight,
                preferredSpacing: cardSpacing,
                availableHeight: geometry.size.height
            )

            ZStack(alignment: .top) {
                ForEach(Array(cards.enumerated()), id: \.element.stableId) { index, card in
                    let isFrontCard = index == cards.count - 1
                    let baseOffset = layout.offset(for: index)
                    let elasticFanOffset = elasticOffset(pullOffset) * (1 + CGFloat(index) * fanMultiplier)

                    CardStackItem(
                        card: card,
                        cardHeight: cardHeight,
                        visibleHeight: layout.visibleHeight(for: index),
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
                        }
                    )
                    .offset(y: baseOffset + elasticFanOffset)
                    .zIndex(Double(index))
                }
            }
            .frame(height: layout.contentHeight, alignment: .top)
            .frame(maxWidth: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .updating($pullOffset) { value, state, _ in
                        state = value.translation.height
                    }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.5), value: pullOffset)
        }
    }
}

struct CardStackItem: View {
    let card: Card
    let cardHeight: CGFloat
    let visibleHeight: CGFloat
    var isFrontCard: Bool = false
    let onTap: () -> Void
    let onLongPress: () -> Void
    let onFavoriteToggle: () -> Void

    var body: some View {
        WalletCardView(card: card)
            .frame(height: cardHeight)
            .padding(.horizontal, 16)
            .contentShape(VisibleCardShape(isFrontCard: isFrontCard, visibleHeight: visibleHeight))
            .onTapGesture {
                onTap()
            }
            .contextMenu {
                Button(action: onLongPress) {
                    Label("Edit Card", systemImage: "pencil")
                }
                Button(action: onFavoriteToggle) {
                    Label(
                        card.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                        systemImage: card.isFavorite ? "star.slash" : "star"
                    )
                }
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
    let visibleHeight: CGFloat

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
                height: max(1, visibleHeight)
            )
            return Path(visibleRect)
        }
    }
}

#Preview {
    let preview = PersistenceController.preview
    CardListView()
        .environment(\.managedObjectContext, preview.container.viewContext)
        .environment(CardStore(context: preview.container.viewContext))
}
