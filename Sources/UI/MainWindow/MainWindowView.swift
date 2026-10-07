import AppKit
import Branding
import SwiftUI

public struct MainWindowView: View {
    @ObservedObject private var state: MainWindowState
    @ObservedObject private var exports: ClipExportCoordinator
    private let menuBar: MenuBarState
    @Environment(\.accessibilityShowBorders) private var showBorders
    @Environment(\.colorSchemeContrast) private var contrast

    public init(state: MainWindowState, menuBar: MenuBarState) {
        self.state = state
        self.exports = state.exports
        self.menuBar = menuBar
    }

    public var body: some View {
        // The sidebar is always shown at a fixed width; it cannot be collapsed
        // or resized, so its layout never needs adjusting.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(Self.sidebarWidth)
                .background(SidebarWidthLock(width: Self.sidebarWidth))
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(pageTitle)
                .toolbar { detailToolbar }
        }
        .tint(AppTheme.accent)
    }

    // MARK: Sidebar

    private static let sidebarWidth: CGFloat = 220

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The app's own icon, so each edition shows its own artwork. The
            // icon's built-in margin keeps the name aligned with the row labels.
            HStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 26, height: 26)
                Text(AppBranding.name)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
            }
            .padding(.leading, 10)
            .padding(.trailing, 12)
            // Clears the traffic lights, which full screen hides.
            .padding(.top, state.isFullScreen ? 20 : 52)
            .padding(.bottom, 22)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppBranding.name)

            ForEach([MainWindowPage.home, .library]) { page in
                sidebarRow(page.title, icon: page.icon,
                           isSelected: state.page == page) { state.select(page) }
            }

            Text("SETTINGS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .padding(.top, 24)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(MainWindowPage.allCases.filter { $0 != .home && $0 != .library }) { page in
                sidebarRow(page.title, icon: page.icon,
                           isSelected: state.page == page) { state.select(page) }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .ignoresSafeArea(.container, edges: .top)
    }

    private func sidebarRow(_ title: String, detail: String? = nil, icon: String,
                            isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).frame(width: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    if let detail {
                        Text(detail)
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(.secondary)
                            .truncationMode(.middle)
                    }
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: isSelected ? .semibold : .medium, design: .rounded))
            .foregroundStyle(isSelected ? AppTheme.accent : AppTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
            .background(isSelected ? AppTheme.accent.opacity(contrast == .increased ? 0.25 : 0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if showBorders || (contrast == .increased && isSelected) {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.primary, lineWidth: 1)
                }
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityLabel(detail.map { "\(title), \($0)" } ?? title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Detail

    private var detail: some View {
        ZStack {
            ClipLibraryView(windowState: state)
                .opacity(state.isLibraryFrontmost ? 1 : 0)
                .allowsHitTesting(state.isLibraryFrontmost)
                .disabled(!state.isLibraryFrontmost)
                .accessibilityHidden(!state.isLibraryFrontmost)
            if state.isLibraryFrontmost {
                // Search and library actions live in the window toolbar, so they
                // are attached only while the library is the visible page.
                ClipLibraryToolbarHost(state: state.library)
            }
            if state.hasVisitedSettings {
                SettingsView(selectedTab: $state.settingsTab,
                             isVisible: state.isSettingsPage && state.isWindowVisible)
                    .opacity(state.isSettingsPage ? 1 : 0)
                    .allowsHitTesting(state.isSettingsPage)
                    .disabled(!state.isSettingsPage)
                    .accessibilityHidden(!state.isSettingsPage)
            }
            if state.page == .home {
                HomeView(windowState: state, menuBar: menuBar)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .floatingBottomBar { statusBars }
    }

    private var pageTitle: String { state.page.title }

    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        // A persistent toolbar item ensures macOS keeps the window toolbar
        // at the exact same height across all pages without collapsing.
        ToolbarItem(placement: .automatic) {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    // MARK: Floating status

    private var showsExportStatus: Bool {
        exports.isBusy || exports.completedURL != nil || exports.errorMessage != nil
    }

    @ViewBuilder
    private var statusBars: some View {
        if showsExportStatus {
            GlassGroup(spacing: 8) {
                exportStatus
            }
            .frame(maxWidth: 620)
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
    }

    private var exportStatus: some View {
        HStack(spacing: 12) {
            if exports.isBusy {
                if let progress = exports.progress {
                    ProgressView(value: progress).frame(width: 100)
                } else { ProgressView().controlSize(.small) }
                Text(exports.title)
                if let source = exports.sourceURL {
                    Text(source.lastPathComponent).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                Button("Cancel Export") { exports.cancel() }
            } else {
                Image(systemName: exports.errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(exports.errorMessage == nil ? AppTheme.success : .orange)
                Text(exports.errorMessage ?? "Export complete")
                    .lineLimit(2).textSelection(.enabled)
                Spacer(minLength: 8)
                if let url = exports.completedURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button { exports.dismissResult() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .help("Dismiss export result")
                    .accessibilityLabel("Dismiss export result")
            }
        }
        .floatingPill()
    }
}

/// Pins the sidebar's split view item to a fixed width. On macOS, SwiftUI's
/// `navigationSplitViewColumnWidth(min:ideal:max:)` leaves the AppKit item
/// resizable, so the limits are set on the item itself, and reapplied on
/// layout in case SwiftUI resets them.
private struct SidebarWidthLock: NSViewRepresentable {
    let width: CGFloat

    func makeNSView(context: Context) -> LockView {
        let view = LockView()
        view.width = width
        return view
    }

    func updateNSView(_ view: LockView, context: Context) {
        view.width = width
        view.needsLayout = true
    }

    final class LockView: NSView {
        var width: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyLock()
        }

        override func layout() {
            super.layout()
            applyLock()
        }

        private func applyLock() {
            var ancestor = superview
            while let view = ancestor, !(view is NSSplitView) { ancestor = view.superview }
            guard let splitView = ancestor as? NSSplitView,
                  let controller = splitView.delegate as? NSSplitViewController,
                  let item = controller.splitViewItems.first,
                  item.minimumThickness != width || item.maximumThickness != width || item.canCollapse
            else { return }
            item.minimumThickness = width
            item.maximumThickness = width
            item.canCollapse = false
        }
    }
}
