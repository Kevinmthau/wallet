import SwiftUI
import os

struct FullScreenCardView: View {
    @Environment(\.dismiss) private var dismiss
    let card: Card
    let onViewed: () -> Void
    let onDelete: (Card) -> Void

    @State private var showingBack = false
    @State private var brightness: CGFloat = UIScreen.main.brightness
    @State private var dragOffset: CGFloat = 0
    @State private var showingEditSheet = false
    @State private var showingShareSheet = false
    @State private var showingNotes = false
    @State private var showingDeleteConfirmation = false
    @State private var hasRecordedView = false
    @State private var frontDisplayImage: UIImage?
    @State private var backDisplayImage: UIImage?
    @State private var shareItems: [UIImage] = []
    @State private var isPreparingShare = false

    private var displayImageLoadIdentifier: String {
        [
            CardImageRepository.shared.loadIdentifier(for: card, side: .front, variant: .display),
            CardImageRepository.shared.loadIdentifier(for: card, side: .back, variant: .display)
        ].joined(separator: "|")
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Black background
                Color.black
                    .ignoresSafeArea()
                    .onTapGesture {
                        dismiss()
                    }

                VStack(spacing: 0) {
                    // Card display area
                    FlippableCardView(
                        frontImage: frontDisplayImage,
                        backImage: backDisplayImage,
                        hasBack: card.hasBack,
                        showingBack: $showingBack,
                        showPlaceholders: false
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(20)
                    .onTapGesture {
                        if card.hasBack {
                            withAnimation(.spring(response: 0.5, dampingFraction: 0.8)) {
                                showingBack.toggle()
                            }
                        }
                    }

                    // Card name and flip hint
                    VStack(spacing: 8) {
                        Text(card.name)
                            .font(.headline)
                            .foregroundStyle(.white)

                        if card.hasBack {
                            HStack(spacing: 4) {
                                Image(systemName: "hand.tap")
                                Text(showingBack ? "Tap for front" : "Tap for back")
                            }
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.6))
                        }

                    }
                    .padding(.bottom, 40)
                }
                .offset(y: dragOffset)
                .simultaneousGesture(
                    DragGesture(minimumDistance: Constants.Gestures.swipeMinimumDistance)
                        .onChanged { value in
                            if value.translation.height > 0 {
                                dragOffset = value.translation.height
                            } else if value.translation.height < 0 && card.notes != nil && !card.notes!.isEmpty {
                                dragOffset = value.translation.height * 0.3
                            }
                        }
                        .onEnded { value in
                            if value.translation.height > Constants.Gestures.swipeDismissThreshold {
                                AppLogger.ui.info("Swipe down to dismiss - offset: \(value.translation.height)")
                                dismiss()
                            } else if value.translation.height < -Constants.Gestures.swipeDismissThreshold && card.notes != nil && !card.notes!.isEmpty {
                                AppLogger.ui.info("Swipe up to show notes - offset: \(value.translation.height)")
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    dragOffset = 0
                                }
                                showingNotes = true
                            } else {
                                AppLogger.ui.debug("Swipe cancelled - offset: \(value.translation.height)")
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                                    dragOffset = 0
                                }
                            }
                        }
                )

                // Top bar with menu
                VStack {
                    HStack {
                        Spacer()

                        Menu {
                            Button {
                                showingEditSheet = true
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }

                            Button {
                                prepareShareItems()
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            .disabled(isPreparingShare)

                            Divider()

                            Button(role: .destructive) {
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete Card", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle.fill")
                                .font(.title)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        .padding()
                    }
                    Spacer()
                }
            }
        }
        .onAppear {
            // Save current brightness and increase for better card visibility
            brightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1.0

            if !hasRecordedView {
                hasRecordedView = true
                onViewed()
            }
        }
        .onDisappear {
            // Restore brightness to what it was before viewing the card
            UIScreen.main.brightness = brightness
            if !showingShareSheet {
                clearShareItems()
            }
        }
        .statusBarHidden()
        .sheet(isPresented: $showingEditSheet) {
            CardFormView(mode: .edit(card))
        }
        .sheet(isPresented: $showingShareSheet, onDismiss: clearShareItems) {
            ShareSheet(items: shareItems)
        }
        .sheet(isPresented: $showingNotes) {
            NotesSheet(notes: card.notes ?? "", cardName: card.name)
        }
        .confirmationDialog("Delete Card", isPresented: $showingDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                onDelete(card)
            }
        } message: {
            Text("Are you sure you want to delete \"\(card.name)\"? This cannot be undone.")
        }
        .task(id: displayImageLoadIdentifier) {
            await loadDisplayImages()
        }
    }

    @MainActor
    private func loadDisplayImages() async {
        frontDisplayImage = await CardImageRepository.shared.image(
            for: card,
            side: .front,
            variant: .display
        )
        backDisplayImage = await CardImageRepository.shared.image(
            for: card,
            side: .back,
            variant: .display
        )
    }

    @MainActor
    private func prepareShareItems() {
        guard !isPreparingShare else { return }
        isPreparingShare = true

        Task { @MainActor in
            let frontImage = await CardImageRepository.shared.image(
                for: card,
                side: .front,
                variant: .full
            )
            let backImage = await CardImageRepository.shared.image(
                for: card,
                side: .back,
                variant: .full
            )

            var images: [UIImage] = []
            if let front = frontImage {
                images.append(front)
            }
            if let back = backImage {
                images.append(back)
            }

            shareItems = images
            isPreparingShare = false
            showingShareSheet = !images.isEmpty
            if images.isEmpty {
                clearShareItems()
            }
        }
    }

    @MainActor
    private func clearShareItems() {
        shareItems.removeAll(keepingCapacity: false)
    }
}

struct NotesSheet: View {
    let notes: String
    let cardName: String

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(notes)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            .navigationTitle("\(cardName) Notes")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
