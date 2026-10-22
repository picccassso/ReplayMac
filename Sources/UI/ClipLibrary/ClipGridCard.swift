import SwiftUI
import AppKit
@preconcurrency import AVFoundation
import Defaults

enum ClipLibraryLayout: String, CaseIterable, Identifiable, Defaults.Serializable {
    case list
    case grid

    var id: String { rawValue }

    var title: String {
        switch self {
        case .list: return "List"
        case .grid: return "Grid"
        }
    }

    var systemImage: String {
        switch self {
        case .list: return "list.bullet"
        case .grid: return "square.grid.2x2"
        }
    }
}

extension Defaults.Keys {
    static let clipLibraryLayout = Key<ClipLibraryLayout>("clipLibraryLayout", default: .list)
    /// Smallest width a grid card may shrink to; cards stretch to fill each row.
    static let clipLibraryGridCardWidth = Key<Double>("clipLibraryGridCardWidth", default: 240)
}

enum ClipGridMetrics {
    static let cardWidthRange: ClosedRange<Double> = 180...380
    static let spacing: CGFloat = 14
    static let padding: CGFloat = 16
}

/// Actions a grid card can trigger directly from its hover controls.
struct ClipGridCardActions {
    var toggleFavorite: () -> Void
    var preview: () -> Void
    var trim: () -> Void
    var editInfo: () -> Void
    var copyFile: () -> Void
    var delete: () -> Void
}

/// One clip in the library grid: a 16:9 poster that skims through the clip as
/// the pointer moves across it, with the title and details underneath.
struct ClipGridCard: View {
    let row: ClipRow
    let isSelected: Bool
    let isProtected: Bool
    let thumbnailWidth: CGFloat
    let actions: ClipGridCardActions

    @StateObject private var skimmer = ClipSkimmer()
    @State private var isHovering = false
    @State private var hoverEntryX: CGFloat?
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityShowBorders) private var showBorders
    @Environment(\.displayScale) private var displayScale

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppTheme.cornerRadiusLarge, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thumbnail
            details
        }
        .padding(6)
        .background(cardFill, in: cardShape)
        .overlay {
            if isSelected {
                cardShape.strokeBorder(AppTheme.accent, lineWidth: 2)
            } else if showBorders {
                cardShape.strokeBorder(Color.primary, lineWidth: 1)
            }
        }
        .contentShape(cardShape)
        .onHover { hovering in
            isHovering = hovering
            if !hovering {
                hoverEntryX = nil
                skimmer.end()
            }
        }
        .onDisappear {
            hoverEntryX = nil
            skimmer.end()
        }
    }

    private var cardFill: Color {
        if isSelected { return AppTheme.accent.opacity(contrast == .increased ? 0.25 : 0.14) }
        return isHovering ? AppTheme.backgroundSecondary : Color.clear
    }

    // MARK: Thumbnail

    private var thumbnail: some View {
        let shape = RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous)
        return Color.black
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay { poster }
            .overlay(alignment: .leading) { playhead }
            .overlay(alignment: .topLeading) {
                if row.userMetadata.isFavorite || isHovering {
                    favoriteButton.padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isHovering {
                    hoverActions.padding(8)
                }
            }
            .overlay(alignment: .bottom) { bottomBadges.padding(8) }
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    guard thumbnailWidth > 0 else { return }
                    if let entryX = hoverEntryX {
                        // Ignore purely vertical relative motion (cards scrolling
                        // under a stationary pointer) until the pointer moves horizontally.
                        guard skimmer.fraction != nil || abs(location.x - entryX) >= 3 else { return }
                    } else {
                        hoverEntryX = location.x
                        return
                    }
                    skimmer.skim(
                        url: row.info.fileURL,
                        duration: row.info.duration,
                        fraction: location.x / thumbnailWidth,
                        maxPixelWidth: min(thumbnailWidth * displayScale, 960)
                    )
                case .ended:
                    hoverEntryX = nil
                    skimmer.end()
                }
            }
    }

    @ViewBuilder
    private var poster: some View {
        if let image = skimmer.frame ?? row.thumbnail {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                LinearGradient(
                    colors: [AppTheme.accent.opacity(0.35), AppTheme.accent.opacity(0.1)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Image(systemName: "film")
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    /// A thin line marking where the pointer is skimming.
    @ViewBuilder
    private var playhead: some View {
        if let fraction = skimmer.fraction {
            Rectangle()
                .fill(.white)
                .frame(width: 2)
                .shadow(color: .black.opacity(0.5), radius: 2)
                .offset(x: fraction * max(thumbnailWidth - 2, 0))
                .allowsHitTesting(false)
        }
    }

    private var favoriteButton: some View {
        Button(action: actions.toggleFavorite) {
            ThumbnailChromeLabel(
                icon: row.userMetadata.isFavorite ? "star.fill" : "star",
                tint: row.userMetadata.isFavorite ? .yellow : .white
            )
        }
        .buttonStyle(.plain)
        .help(row.userMetadata.isFavorite ? "Remove favorite" : "Mark favorite")
    }

    private var hoverActions: some View {
        HStack(spacing: 6) {
            Button(action: actions.preview) {
                ThumbnailChromeLabel(icon: "play.fill")
            }
            .buttonStyle(.plain)
            .help("Quick preview")

            Button(action: actions.trim) {
                ThumbnailChromeLabel(icon: "scissors")
            }
            .buttonStyle(.plain)
            .help("Trim & Export")

            Menu {
                Button("Edit Info…", systemImage: "info.circle", action: actions.editInfo)
                Button("Copy File", systemImage: "doc.on.doc", action: actions.copyFile)
                Button("Show in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([row.info.fileURL])
                }
                Divider()
                Button("Delete Clip", systemImage: "trash", role: .destructive, action: actions.delete)
                    .disabled(isProtected)
            } label: {
                ThumbnailChromeLabel(icon: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More clip actions")
        }
    }

    private var bottomBadges: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(row.userMetadata.tags.prefix(2), id: \.self) { tag in
                ThumbnailBadge(text: tag)
            }
            if row.userMetadata.tags.count > 2 {
                ThumbnailBadge(text: "+\(row.userMetadata.tags.count - 2)")
                    .fixedSize()
            }
            Spacer(minLength: 4)
            ThumbnailBadge(text: durationText, monospaced: true)
                .fixedSize()
        }
        .allowsHitTesting(false)
    }

    private var durationText: String {
        if let fraction = skimmer.fraction, row.info.duration.isFinite {
            return MenuBarState.formattedDuration(fraction * row.info.duration)
        }
        return row.durationLabel
    }

    // MARK: Details

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(row.displayTitle)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(row.gridSubtitleLabel)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 4)
        .padding(.bottom, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Round control drawn over a thumbnail. A dark scrim keeps it legible on any
/// frame, bright or dark.
private struct ThumbnailChromeLabel: View {
    let icon: String
    var tint: Color = .white

    @Environment(\.colorSchemeContrast) private var contrast
    @State private var isHovering = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(.black.opacity(isHovering || contrast == .increased ? 0.75 : 0.5), in: Circle())
            .contentShape(Circle())
            .onHover { isHovering = $0 }
    }
}

private struct ThumbnailBadge: View {
    let text: String
    var monospaced = false

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .monospacedDigit(monospaced)
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(.black.opacity(contrast == .increased ? 0.75 : 0.55), in: Capsule())
    }
}

private extension Text {
    func monospacedDigit(_ enabled: Bool) -> Text {
        enabled ? monospacedDigit() : self
    }
}

/// Pulls frames from a clip as the pointer skims across its card. Only one
/// frame request is in flight at a time; newer positions replace queued ones,
/// so fast pointer moves never pile up decode work.
@MainActor
final class ClipSkimmer: ObservableObject {
    @Published private(set) var frame: NSImage?
    @Published private(set) var fraction: Double?

    private var generator: AVAssetImageGenerator?
    private var isGenerating = false
    private var pendingSeconds: Double?
    /// Bumped on `end()` so frames from a finished skim are dropped.
    private var session = 0

    func skim(url: URL, duration: Double, fraction: Double, maxPixelWidth: CGFloat) {
        guard duration.isFinite, duration > 0 else { return }
        let fraction = min(max(fraction, 0), 1)
        self.fraction = fraction

        if generator == nil {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: maxPixelWidth, height: maxPixelWidth * 9 / 16)
            // A little slack lets the decoder return a nearby frame instead of
            // decoding forward from the previous keyframe on every move.
            let tolerance = CMTime(seconds: 0.15, preferredTimescale: 600)
            generator.requestedTimeToleranceBefore = tolerance
            generator.requestedTimeToleranceAfter = tolerance
            self.generator = generator
        }

        pendingSeconds = fraction * duration
        requestNextFrame()
    }

    func end() {
        session += 1
        generator?.cancelAllCGImageGeneration()
        generator = nil
        isGenerating = false
        pendingSeconds = nil
        frame = nil
        fraction = nil
    }

    private func requestNextFrame() {
        guard !isGenerating, let generator, let seconds = pendingSeconds else { return }
        pendingSeconds = nil
        isGenerating = true
        let session = self.session
        generator.generateCGImageAsynchronously(for: CMTime(seconds: seconds, preferredTimescale: 600)) { [weak self] image, _, _ in
            let box = SkimFrameBox(image: image)
            Task { @MainActor in
                self?.deliver(box, session: session)
            }
        }
    }

    private func deliver(_ box: SkimFrameBox, session: Int) {
        guard session == self.session else { return }
        isGenerating = false
        if let image = box.image {
            frame = NSImage(cgImage: image, size: .zero)
        }
        requestNextFrame()
    }
}

/// Carries a decoded frame from the image generator's callback queue back to
/// the main actor.
private final class SkimFrameBox: @unchecked Sendable {
    let image: CGImage?
    init(image: CGImage?) { self.image = image }
}
