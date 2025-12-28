import SwiftUI

struct CardDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var viewContext

    let card: Card

    @State private var showingBack = false
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var showingEdit = false

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 24) {
                    // Card Image with flip animation
                    ZStack {
                        // Front of card
                        cardImage(card.frontImage, placeholder: "Front")
                            .opacity(showingBack ? 0 : 1)
                            .rotation3DEffect(
                                .degrees(showingBack ? 180 : 0),
                                axis: (x: 0, y: 1, z: 0)
                            )

                        // Back of card
                        if card.hasBack {
                            cardImage(card.backImage, placeholder: "Back")
                                .opacity(showingBack ? 1 : 0)
                                .rotation3DEffect(
                                    .degrees(showingBack ? 0 : -180),
                                    axis: (x: 0, y: 1, z: 0)
                                )
                        }
                    }
                    .frame(maxWidth: geometry.size.width - 32)
                    .aspectRatio(1.586, contentMode: .fit) // Standard card ratio
                    .scaleEffect(scale)
                    .offset(offset)
                    .gesture(
                        MagnificationGesture()
                            .onChanged { value in
                                scale = max(1, min(value, 3))
                            }
                            .onEnded { _ in
                                withAnimation(.spring()) {
                                    if scale < 1.2 {
                                        scale = 1
                                        offset = .zero
                                    }
                                }
                            }
                    )
                    .simultaneousGesture(
                        DragGesture()
                            .onChanged { value in
                                if scale > 1 {
                                    offset = CGSize(
                                        width: lastOffset.width + value.translation.width,
                                        height: lastOffset.height + value.translation.height
                                    )
                                }
                            }
                            .onEnded { _ in
                                lastOffset = offset
                            }
                    )
                    .onTapGesture(count: 2) {
                        withAnimation(.spring()) {
                            if scale > 1 {
                                scale = 1
                                offset = .zero
                                lastOffset = .zero
                            } else {
                                scale = 2
                            }
                        }
                    }
                    .onTapGesture {
                        if card.hasBack && scale == 1 {
                            withAnimation(.spring(duration: 0.5)) {
                                showingBack.toggle()
                            }
                        }
                    }

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
                    Menu {
                        Button {
                            showingEdit = true
                        } label: {
                            Label("Edit Card", systemImage: "pencil")
                        }

                        Button {
                            toggleFavorite()
                        } label: {
                            Label(
                                card.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                                systemImage: card.isFavorite ? "star.slash" : "star"
                            )
                        }

                        if let notes = card.notes, !notes.isEmpty {
                            Button {
                                UIPasteboard.general.string = notes
                            } label: {
                                Label("Copy Notes", systemImage: "doc.on.doc")
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showingEdit) {
                EditCardView(card: card)
            }
        }
    }

    @ViewBuilder
    private func cardImage(_ image: UIImage?, placeholder: String) -> some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .fill(Color(.secondarySystemBackground))
                    .overlay {
                        Text(placeholder)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.2), radius: 10, x: 0, y: 5)
    }

    private func toggleFavorite() {
        card.isFavorite.toggle()
        try? viewContext.save()
    }
}

#Preview {
    CardDetailView(card: Card())
}
