import SwiftUI

/// View modifier that adds tap-to-flip gesture for dual-sided cards
/// Only triggers when not zoomed (scale == 1)
struct CardFlipGestureModifier: ViewModifier {
    @Binding var showingBack: Bool
    let isZoomed: Bool
    let hasDualSides: Bool

    func body(content: Content) -> some View {
        content
            .onTapGesture {
                if hasDualSides && !isZoomed {
                    withAnimation(.spring(duration: Constants.Animation.flipDuration)) {
                        showingBack.toggle()
                    }
                }
            }
    }
}

extension View {
    /// Adds tap-to-flip gesture for dual-sided cards
    /// - Parameters:
    ///   - showingBack: Binding to control which side is shown
    ///   - isZoomed: Whether the view is currently zoomed (disables flip when true)
    ///   - hasDualSides: Whether the card has a back side
    func cardFlipGesture(
        showingBack: Binding<Bool>,
        isZoomed: Bool,
        hasDualSides: Bool
    ) -> some View {
        modifier(CardFlipGestureModifier(
            showingBack: showingBack,
            isZoomed: isZoomed,
            hasDualSides: hasDualSides
        ))
    }
}
