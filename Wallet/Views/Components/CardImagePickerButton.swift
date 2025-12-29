import SwiftUI

struct CardImagePickerButton: View {
    let image: UIImage?
    let placeholder: String
    let onScan: () -> Void
    var onLibrary: (() -> Void)? = nil
    let onEnhance: () -> Void
    let onRemove: () -> Void

    var body: some View {
        if let image = image {
            imagePreview(image)
        } else {
            emptyState
        }
    }

    private func imagePreview(_ image: UIImage) -> some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                }
                .offset(x: 8, y: -8)
            }

            HStack(spacing: 12) {
                Button {
                    onScan()
                } label: {
                    Label("Rescan", systemImage: "doc.viewfinder")
                        .font(.caption)
                }
                .buttonStyle(.bordered)

                Button {
                    onEnhance()
                } label: {
                    Label("Enhance", systemImage: "wand.and.stars")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let onLibrary = onLibrary {
            Menu {
                Button {
                    onScan()
                } label: {
                    Label("Scan Card", systemImage: "doc.viewfinder")
                }

                Button {
                    onLibrary()
                } label: {
                    Label("Choose from Library", systemImage: "photo.on.rectangle")
                }
            } label: {
                placeholderLabel
            }
            .buttonStyle(.plain)
        } else {
            Button {
                onScan()
            } label: {
                placeholderLabel
            }
            .buttonStyle(.plain)
        }
    }

    private var placeholderLabel: some View {
        HStack {
            Image(systemName: "doc.viewfinder")
            Text(placeholder)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 100)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
    }
}
