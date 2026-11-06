import SwiftUI
import Charts
import CoreGraphics

/// Output settings the explainer works from, taken when it opens.
struct BitrateExplainerContext {
    let width: Int
    let height: Int
    let frameRate: Int
    let guide: BitrateGuide
}

/// Optional sheet behind "What does bitrate do?" in Settings → Video. Lets
/// people try bitrates against their own size and frame rate before saving.
struct BitrateExplainerSheet: View {
    let context: BitrateExplainerContext
    let apply: (Double) -> Void

    static let sheetWidth: CGFloat = 560
    static let padding: CGFloat = 24
    static let columnSpacing: CGFloat = 16
    /// Preview and chart share the row equally.
    static let columnWidth = (sheetWidth - padding * 2 - columnSpacing) / 2

    @Environment(\.dismiss) private var dismiss
    @State private var mbps: Double
    @State private var sceneImage: CGImage?
    private let initialMbps: Double

    init(context: BitrateExplainerContext, initialMbps: Double, apply: @escaping (Double) -> Void) {
        self.context = context
        self.apply = apply
        self.initialMbps = initialMbps
        _mbps = State(initialValue: initialMbps)
    }

    private var guide: BitrateGuide { context.guide }
    private var quality: Double { guide.illustrativeQuality(at: mbps) }

    /// Starts the chart just under the slider minimum so the curve fills it.
    private var qualityAxisFloor: Double {
        max(guide.illustrativeQuality(at: BitrateGuide.sliderRange.lowerBound) - 0.1, 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 22))
                    .foregroundStyle(AppTheme.accent)
                Text("What bitrate does")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
            }

            Text("Bitrate is how much data each second of video gets. When there isn't enough, the encoder throws detail away, and you see it first in fast motion: blocky smears when the camera swings, mushy grass and smoke, fuzzy HUD text. It's shared across every pixel of every frame, so the same bitrate goes further at a smaller size or a lower frame rate.")
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .top, spacing: Self.columnSpacing) {
                preview
                chart
            }

            slider

            HStack(spacing: 10) {
                statTile(
                    title: "Each pixel gets",
                    value: String(format: "%.2f bits", BitrateGuide.bitsPerPixel(
                        mbps: mbps,
                        width: context.width,
                        height: context.height,
                        frameRate: context.frameRate
                    )),
                    detail: "\(context.width) × \(context.height) at \(context.frameRate) fps"
                )
                statTile(
                    title: "One minute of video",
                    value: ReplayMemoryEstimate.formatBytes(BitrateGuide.bytesPerMinute(mbps)),
                    detail: "on disk"
                )
                statTile(
                    title: "Your replay buffer",
                    value: ReplayMemoryEstimate.current(bitrateMbps: mbps).formattedRequired,
                    detail: "kept in memory"
                )
            }

            VStack(alignment: .leading, spacing: 8) {
                Label("Above the green, the extra detail only shows on a large, sharp display, or when you pause and look closely. On a laptop screen or a phone you probably won't see a difference, and sites like YouTube compress clips again when you upload them.", systemImage: "display")
                Label("The green moves with your size, frame rate and codec, so the slider doesn't stop at it. Go above it if you edit clips or watch them on a high-end monitor, or below it to save memory and disk.", systemImage: "slider.horizontal.3")
                Label("Fast shooters and racing games benefit from the top of the band. Desktop and strategy footage looks fine near the bottom.", systemImage: "gamecontroller")
                Label("A higher bitrate won't slow your games. Encoding runs on your Mac's media engine, and its work depends on resolution and frame rate. Bitrate costs memory and disk space instead.", systemImage: "cpu")
            }
            .foregroundStyle(AppTheme.textSecondary)
            .font(.system(size: 12, design: .rounded))
            .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                if Int(mbps) == Int(initialMbps) {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(AccentButtonStyle())
                } else {
                    // A plain push button: the main window's accent tint carries
                    // into sheets and would colour a glass button like the default.
                    Button("Cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("Use \(Int(mbps)) Mbps") {
                        apply(mbps)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(AccentButtonStyle())
                }
            }
            .controlSize(.large)
        }
        .padding(Self.padding)
        .frame(width: Self.sheetWidth)
        .onAppear {
            if sceneImage == nil {
                sceneImage = BitrateSampleScene.render()
            }
        }
    }

    private var preview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Simulated busy frame")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
            Group {
                if let sceneImage, let image = BitrateSampleScene.pixelated(sceneImage, quality: quality) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.none)
                } else {
                    Color.secondary.opacity(0.15)
                }
            }
            .frame(
                width: Self.columnWidth,
                height: Self.columnWidth * BitrateSampleScene.size.height / BitrateSampleScene.size.width
            )
            .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall, style: .continuous))
            .accessibilityLabel("Simulated game frame at \(Int(mbps)) Mbps")
            BitrateZoneLabel(guide: guide, bitrateMbps: mbps)
        }
        .frame(width: Self.columnWidth, alignment: .leading)
    }

    private var chart: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Picture quality by bitrate (Mbps)")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
            Chart {
                RectangleMark(
                    xStart: .value("From", guide.sweetSpot.lowerBound),
                    xEnd: .value("To", max(guide.sweetSpot.upperBound, guide.sweetSpot.lowerBound + 0.6)),
                    yStart: .value("Bottom", qualityAxisFloor),
                    yEnd: .value("Top", 1)
                )
                .foregroundStyle(AppTheme.success.opacity(0.15))

                ForEach(Array(stride(from: BitrateGuide.sliderRange.lowerBound, through: BitrateGuide.sliderRange.upperBound, by: 1)), id: \.self) { value in
                    LineMark(
                        x: .value("Mbps", value),
                        y: .value("Quality", guide.illustrativeQuality(at: value))
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(AppTheme.accent)
                }

                PointMark(x: .value("Mbps", mbps), y: .value("Quality", quality))
                    .foregroundStyle(Color.primary)
                    .symbolSize(60)
            }
            .chartXScale(domain: BitrateGuide.sliderRange)
            .chartYScale(domain: qualityAxisFloor...1)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: [10, 20, 30, 40, 50]) { _ in
                    AxisGridLine()
                    AxisValueLabel(anchor: .top)
                }
            }
            .chartPlotStyle { plot in
                plot.padding(.horizontal, 8)
            }
            .frame(height: 170)
            .accessibilityHidden(true)
            Text("Green is the sweet spot. Past it, the line flattens: files keep growing, but on most screens the picture barely changes.")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: Self.columnWidth, alignment: .leading)
    }

    private var slider: some View {
        HStack(spacing: 12) {
            Slider(value: $mbps, in: BitrateGuide.sliderRange, step: 1) {
                Text("Bitrate")
            }
            .labelsHidden()
            .tint(AppTheme.accent)
            .background(BitrateSweetSpotBand(sweetSpot: guide.sweetSpot))
            .accessibilityHint(guide.message(for: mbps))
            Text("\(Int(mbps)) Mbps")
                .foregroundStyle(AppTheme.accent)
                .fontWeight(.semibold)
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
        }
    }

    private func statTile(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(detail)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            Color.primary.opacity(0.05),
            in: RoundedRectangle(cornerRadius: AppTheme.cornerRadiusSmall, style: .continuous)
        )
    }
}

/// A made-up game frame (sky, scenery, HUD text) the explainer breaks into
/// blocks to show what a starved bitrate looks like.
enum BitrateSampleScene {
    static let size = CGSize(width: 320, height: 200)
    static let renderScale: CGFloat = 2

    @MainActor
    static func render() -> CGImage? {
        let renderer = ImageRenderer(content: scene.frame(width: size.width, height: size.height))
        renderer.scale = renderScale
        return renderer.cgImage
    }

    /// Full detail from quality 0.85, the start of the sweet spot, then
    /// coarser blocks the further below it the bitrate falls.
    static func blockSize(forQuality quality: Double) -> Int {
        guard quality < 0.85 else { return 1 }
        return Int((1 + (0.85 - quality) * 30).rounded())
    }

    static func pixelated(_ image: CGImage, quality: Double) -> CGImage? {
        let block = blockSize(forQuality: quality)
        guard block > 1 else { return image }

        let pixelsPerBlock = CGFloat(block) * renderScale
        let width = max(Int(CGFloat(image.width) / pixelsPerBlock), 1)
        let height = max(Int(CGFloat(image.height) / pixelsPerBlock), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static var scene: some View {
        Canvas { context, canvasSize in
            let horizon = canvasSize.height * 0.6
            context.fill(Path(CGRect(origin: .zero, size: canvasSize)), with: .color(Color(red: 0.12, green: 0.23, blue: 0.34)))
            context.fill(
                Path(CGRect(x: 0, y: horizon, width: canvasSize.width, height: canvasSize.height - horizon)),
                with: .color(Color(red: 0.23, green: 0.42, blue: 0.27))
            )

            let palette: [Color] = [
                Color(red: 0.56, green: 0.72, blue: 0.87),
                Color(red: 0.88, green: 0.64, blue: 0.35),
                Color(red: 0.78, green: 0.36, blue: 0.29),
                Color(red: 0.95, green: 0.91, blue: 0.85),
                Color(red: 0.35, green: 0.64, blue: 0.42)
            ]
            for index in 0..<40 {
                let radius = CGFloat(4 + (index * 7) % 14)
                let x = CGFloat((index * 53) % Int(canvasSize.width))
                let y = CGFloat((index * 37) % Int(horizon - 20) + 20)
                context.fill(
                    Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                    with: .color(palette[index % palette.count])
                )
            }
            for index in 0..<60 {
                let blade = CGRect(
                    x: CGFloat((index * 29) % Int(canvasSize.width)),
                    y: horizon + CGFloat((index * 13) % Int(canvasSize.height - horizon)),
                    width: 6,
                    height: CGFloat(3 + (index % 5) * 4)
                )
                let shade = index.isMultiple(of: 2)
                    ? Color(red: 0.31, green: 0.54, blue: 0.36)
                    : Color(red: 0.18, green: 0.32, blue: 0.21)
                context.fill(Path(blade), with: .color(shade))
            }

            let hud = Color(red: 0.95, green: 0.91, blue: 0.85)
            context.draw(
                Text("HP 87   AMMO 24/90").font(.system(size: 15, weight: .semibold)).foregroundStyle(hud),
                at: CGPoint(x: 12, y: 10),
                anchor: .topLeading
            )
            context.draw(
                Text("Player_42 eliminated Raven").font(.system(size: 11)).foregroundStyle(hud),
                at: CGPoint(x: 12, y: canvasSize.height - 8),
                anchor: .bottomLeading
            )

            let centre = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
            var crosshair = Path()
            crosshair.move(to: CGPoint(x: centre.x - 10, y: centre.y))
            crosshair.addLine(to: CGPoint(x: centre.x + 10, y: centre.y))
            crosshair.move(to: CGPoint(x: centre.x, y: centre.y - 10))
            crosshair.addLine(to: CGPoint(x: centre.x, y: centre.y + 10))
            context.stroke(crosshair, with: .color(hud), lineWidth: 2)
        }
    }
}
