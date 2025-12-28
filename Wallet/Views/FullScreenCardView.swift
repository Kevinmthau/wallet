import SwiftUI

struct FullScreenCardView: View {
    @Environment(\.dismiss) private var dismiss
    let card: Card

    @State private var showingBack = false
    @State private var brightness: CGFloat = UIScreen.main.brightness

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
                    ZStack {
                        // Front of card
                        if let frontImage = card.frontImage {
                            Image(uiImage: frontImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .opacity(showingBack ? 0 : 1)
                                .rotation3DEffect(
                                    .degrees(showingBack ? 180 : 0),
                                    axis: (x: 0, y: 1, z: 0)
                                )
                        }

                        // Back of card
                        if card.hasBack, let backImage = card.backImage {
                            Image(uiImage: backImage)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .opacity(showingBack ? 1 : 0)
                                .rotation3DEffect(
                                    .degrees(showingBack ? 0 : -180),
                                    axis: (x: 0, y: 1, z: 0)
                                )
                        }
                    }
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

                // Close button
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
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
    }
}
