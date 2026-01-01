import SwiftUI

/// ViewModifier that adds keyboard Done button and Cancel/Save toolbar items
struct CardFormToolbar: ViewModifier {
    let canSave: Bool
    let onDismissKeyboard: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done", action: onDismissKeyboard)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: onSave)
                        .disabled(!canSave)
                }
            }
    }
}

extension View {
    func cardFormToolbar(
        canSave: Bool,
        onDismissKeyboard: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onSave: @escaping () -> Void
    ) -> some View {
        modifier(CardFormToolbar(
            canSave: canSave,
            onDismissKeyboard: onDismissKeyboard,
            onCancel: onCancel,
            onSave: onSave
        ))
    }
}
