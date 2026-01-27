import SwiftUI
import os

struct FullScreenCardView: View {
    @Environment(\.dismiss) private var dismiss
    let card: Card

    @State private var showingBack = false
    @State private var brightness: CGFloat = UIScreen.main.brightness
    @State private var dragOffset: CGFloat = 0
    @State private var showingEditSheet = false
    @State private var showingShareSheet = false
    @State private var showingNotes = false

    private var imagesToShare: [UIImage] {
        var images: [UIImage] = []
        if let front = card.frontImage { images.append(front) }
        if let back = card.backImage { images.append(back) }
        return images
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
                        frontImage: card.frontImage,
                        backImage: card.backImage,
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
                                showingShareSheet = true
                            } label: {
                                Label("Share", systemImage: "square.and.arrow.up")
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
        }
        .onDisappear {
            // Restore brightness to what it was before viewing the card
            UIScreen.main.brightness = brightness
        }
        .statusBarHidden()
        .sheet(isPresented: $showingEditSheet) {
            CardFormView(mode: .edit(card))
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(items: imagesToShare)
        }
        .sheet(isPresented: $showingNotes) {
            NotesSheet(notes: card.notes ?? "", cardName: card.name)
        }
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
