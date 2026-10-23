import SwiftUI
import AppKit
@preconcurrency import AVFoundation

@MainActor
final class SavedClipCardModel: ObservableObject {
    @Published private(set) var url: URL?
    @Published private(set) var poster: NSImage?
    @Published private(set) var duration: Double?
    @Published var isHovered = false
    @Published var showsCopied = false
    private var loadTask: Task<Void, Never>?

    func load(_ url: URL) {
        loadTask?.cancel()
        self.url = url
        poster = nil
        duration = nil
        showsCopied = false
        loadTask = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let loaded = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
            let seconds = loaded.isFinite ? max(loaded, 0) : 0
            guard !Task.isCancelled else { return }
            self?.duration = seconds > 0 ? seconds : nil

            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 520, height: 520)
            // Replay saves end on the moment that was clipped, so show a frame near the end.
            let time = CMTime(seconds: max(0, seconds - 1), preferredTimescale: 600)
            guard let image = try? await generator.image(at: time).image, !Task.isCancelled else { return }
            self?.poster = NSImage(cgImage: image, size: .zero)
        }
    }

    func reset() {
        loadTask?.cancel()
        url = nil
        poster = nil
        duration = nil
        isHovered = false
        showsCopied = false
    }
}

struct SavedClipCard: View {
    @ObservedObject var model: SavedClipCardModel
    let onClose: () -> Void
    let onReveal: (URL) -> Void
    let onCopy: (URL) -> Void
    let onTrim: (URL) -> Void

    private let shape = RoundedRectangle(cornerRadius: AppTheme.cornerRadiusLarge, style: .continuous)

    var body: some View {
        ZStack {
            poster
            if model.isHovered || model.showsCopied {
                Color.black.opacity(0.35)
                centerActions
            }
        }
        .overlay(alignment: .topLeading) {
            if model.isHovered {
                cornerButton("xmark", help: "Close", action: onClose)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.isHovered, let url = model.url {
                cornerButton("folder", help: "Show in Finder") { onReveal(url) }
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let duration = model.duration {
                Text(MenuBarState.formattedDuration(duration))
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(8)
            }
        }
        .frame(width: ClipThumbnailPanelController.cardSize.width,
               height: ClipThumbnailPanelController.cardSize.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(AppTheme.cardBorderColor, lineWidth: 1))
        .animation(.easeOut(duration: 0.15), value: model.isHovered)
        .onDrag {
            guard let url = model.url else { return NSItemProvider() }
            return NSItemProvider(contentsOf: url) ?? NSItemProvider()
        }
    }

    @ViewBuilder
    private var poster: some View {
        if let image = model.poster {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: ClipThumbnailPanelController.cardSize.width,
                       height: ClipThumbnailPanelController.cardSize.height)
        } else {
            ZStack {
                AppTheme.backgroundSecondary
                Image(systemName: "film")
                    .font(.system(size: 28))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var centerActions: some View {
        if model.showsCopied {
            Label("Copied", systemImage: "checkmark")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
        } else if let url = model.url {
            VStack(spacing: 8) {
                pillButton("Copy") { onCopy(url) }
                pillButton("Trim") { onTrim(url) }
            }
        }
    }

    private func pillButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .frame(minWidth: 64)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func cornerButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .frame(width: 24, height: 24)
                .background(.regularMaterial, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .padding(8)
    }
}
