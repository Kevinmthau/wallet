import SwiftUI

/// Reusable menu actions for card views
/// Can be used with Menu or contextMenu
struct CardActionMenu: View {
    let card: Card
    let onEdit: () -> Void
    let onToggleFavorite: () -> Void
    let onDelete: () -> Void
    var onShare: (() -> Void)? = nil
    var onCopyNotes: (() -> Void)? = nil

    var body: some View {
        Menu {
            CardActionMenuContent(
                card: card,
                onEdit: onEdit,
                onToggleFavorite: onToggleFavorite,
                onDelete: onDelete,
                onShare: onShare,
                onCopyNotes: onCopyNotes
            )
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}

/// Menu content that can be used in both Menu and contextMenu
struct CardActionMenuContent: View {
    let card: Card
    let onEdit: () -> Void
    let onToggleFavorite: () -> Void
    let onDelete: () -> Void
    var onShare: (() -> Void)? = nil
    var onCopyNotes: (() -> Void)? = nil

    var body: some View {
        Button(action: onEdit) {
            Label("Edit Card", systemImage: "pencil")
        }

        Button(action: onToggleFavorite) {
            Label(
                card.isFavorite ? "Remove from Favorites" : "Add to Favorites",
                systemImage: card.isFavorite ? "star.slash" : "star"
            )
        }

        if let share = onShare {
            Button(action: share) {
                Label("Share", systemImage: "square.and.arrow.up")
            }
        }

        if let copyNotes = onCopyNotes, let notes = card.notes, !notes.isEmpty {
            Button(action: copyNotes) {
                Label("Copy Notes", systemImage: "doc.on.doc")
            }
        }

        Divider()

        Button(role: .destructive, action: onDelete) {
            Label("Delete Card", systemImage: "trash")
        }
    }
}
