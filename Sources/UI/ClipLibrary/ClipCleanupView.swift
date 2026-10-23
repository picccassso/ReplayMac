import SwiftUI

enum ClipCleanupAction {
    case nonFavoritesOlderThanDays(Int)
    case allNonFavorites
}

struct ClipCleanupView: View {
    let summary: ClipLibraryStorageSummary
    let onRun: (ClipCleanupAction) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var days = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("Storage Cleanup", systemImage: "externaldrive.badge.minus")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                Spacer()
            }

            HStack(spacing: 14) {
                Label("\(summary.clipCount) clips", systemImage: "film.stack")
                Label(ByteCountFormatter.string(fromByteCount: summary.totalBytes, countStyle: .file), systemImage: "internaldrive")
            }
            .foregroundStyle(AppTheme.textSecondary)

            Stepper(value: $days, in: 1...365) {
                Text("Delete non-favorites older than \(days) days")
            }

            Text("Cleanup moves matching clips to Trash and keeps favorites. Clip notes and tags for deleted files are removed.")
                .font(.system(size: 12, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)

            HStack {
                Button("Cancel") {
                    dismiss()
                }

                Spacer()

                Button("Delete All Non-Favorites", role: .destructive) {
                    onRun(.allNonFavorites)
                }
                .disabled(summary.clipCount == 0)

                Button("Run Cleanup") {
                    onRun(.nonFavoritesOlderThanDays(days))
                }
                .buttonStyle(AccentButtonStyle())
                .tint(AppTheme.danger)
                .disabled(summary.clipCount == 0)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
