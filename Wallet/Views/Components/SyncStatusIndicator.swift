import SwiftUI

/// A subtle iCloud sync status indicator shown in the card list header.
struct SyncStatusIndicator: View {
    let status: SyncStatusMonitor.SyncStatus

    var body: some View {
        Group {
            switch status {
            case .idle:
                EmptyView()
            case .syncing:
                Image(systemName: "icloud.and.arrow.up")
                    .symbolEffect(.pulse, isActive: true)
                    .foregroundStyle(.secondary)
            case .synced:
                Image(systemName: "checkmark.icloud")
                    .foregroundStyle(.green)
                    .transition(.opacity)
            case .noAccount:
                Image(systemName: "icloud.slash")
                    .foregroundStyle(.orange)
            case .error:
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(.red)
            }
        }
        .font(.body)
        .animation(.easeInOut(duration: 0.3), value: status)
    }
}
