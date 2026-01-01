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
                            }
                        }
                        .onEnded { value in
                            if value.translation.height > Constants.Gestures.swipeDismissThreshold {
                                AppLogger.ui.info("Swipe down to dismiss - offset: \(value.translation.height)")
                                dismiss()
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
            // Increase brightness for better visibility
            brightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1.0
        }
        .onDisappear {
            // Restore original brightness
            UIScreen.main.brightness = brightness
        }
        .statusBarHidden()
        .sheet(isPresented: $showingEditSheet) {
            CardFormView(mode: .edit(card))
        }
        .sheet(isPresented: $showingShareSheet) {
            ShareSheet(items: imagesToShare)
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
