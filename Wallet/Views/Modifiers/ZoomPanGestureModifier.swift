import SwiftUI

/// View modifier that adds zoom (pinch) and pan (drag) gesture support
/// Includes double-tap to toggle zoom and automatic snap-back behavior
struct ZoomPanGestureModifier: ViewModifier {
    @Binding var scale: CGFloat
    @Binding var offset: CGSize

    // Internal state for drag tracking
    @State private var lastOffset: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .scaleEffect(scale)
            .offset(offset)
            .gesture(magnificationGesture)
            .simultaneousGesture(dragGesture)
            .onTapGesture(count: 2, perform: handleDoubleTap)
    }

    // MARK: - Gestures

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = max(1, min(value, Constants.Gestures.maxZoomScale))
            }
            .onEnded { _ in
                withAnimation(.spring()) {
                    if scale < Constants.Gestures.snapToNormalThreshold {
                        scale = 1
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
    }

    private var dragGesture: some Gesture {
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
    }

    private func handleDoubleTap() {
        withAnimation(.spring()) {
            if scale > 1 {
                scale = 1
                offset = .zero
                lastOffset = .zero
            } else {
                scale = Constants.Gestures.doubleTapZoomScale
            }
        }
    }
}

extension View {
    /// Adds zoom and pan gesture support to a view
    func zoomPanGesture(scale: Binding<CGFloat>, offset: Binding<CGSize>) -> some View {
        modifier(ZoomPanGestureModifier(scale: scale, offset: offset))
    }
}
