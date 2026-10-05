import SwiftUI
import AVKit

/// Put the crop inside AVPlayerView's documented overlay layer, below its controls.
struct TrimPlayerView: NSViewRepresentable {
    let player: AVPlayer
    let cropEnabled: Bool
    @Binding var cropRect: CGRect
    let videoSize: CGSize
    let isBusy: Bool
    let onManualChange: () -> Void

    func makeNSView(context: Context) -> TrimNativePlayerView {
        let view = TrimNativePlayerView(frame: .zero)
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: TrimNativePlayerView, context: Context) {
        view.player = player
        view.videoDisplaySize = videoSize
        view.cropHost.isHidden = !cropEnabled
        view.cropHost.rootView = AnyView(
            VideoCropSelectionView(selection: $cropRect, videoSize: videoSize,
                                   onManualChange: onManualChange)
                .allowsHitTesting(!isBusy)
        )
        view.needsLayout = true
    }

    static func dismantleNSView(_ view: TrimNativePlayerView, coordinator: ()) {
        view.player = nil
    }
}

final class TrimNativePlayerView: AVPlayerView {
    let cropHost = NSHostingView(rootView: AnyView(EmptyView()))
    var videoDisplaySize = CGSize(width: 16, height: 9)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        contentOverlayView?.addSubview(cropHost)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard let overlay = contentOverlayView else { return }
        let displayedBounds = videoBounds.isEmpty
            ? VideoCropSelectionMath.aspectFitRect(contentSize: videoDisplaySize, in: bounds)
            : videoBounds
        cropHost.frame = overlay.convert(displayedBounds, from: self)
    }
}
