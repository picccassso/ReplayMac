import AppKit
import Branding
import SwiftUI

public struct MainWindowView: View {
    @ObservedObject private var state: MainWindowState
    @ObservedObject private var exports: ClipExportCoordinator
    @Environment(\.accessibilityShowBorders) private var showBorders
    @Environment(\.colorSchemeContrast) private var contrast

    public init(state: MainWindowState) {
        self.state = state
        self.exports = state.exports
    }

    public var body: some View {
        // The sidebar is always shown at a fixed width; there is no collapsing.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            sidebar
                .navigationSplitViewColumnWidth(220)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            detail
                .navigationTitle(pageTitle)
                .toolbar { detailToolbar }
        }
        .tint(AppTheme.accent)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 23))
                    .foregroundStyle(AppTheme.brandAccent)
                    .frame(width: 20)
                Text(AppBranding.name)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 12)
            .padding(.top, 52)
            .padding(.bottom, 22)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AppBranding.name)

            sidebarRow(MainWindowPage.library.title, icon: MainWindowPage.library.icon,
                       isSelected: state.isLibraryFrontmost) { state.select(.library) }

            Text("SETTINGS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 12)
                .padding(.top, 24)
                .padding(.bottom, 8)
                .accessibilityAddTraits(.isHeader)
            ForEach(MainWindowPage.allCases.filter { $0 != .library }) { page in
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
                             isVisible: state.page != .library && state.isWindowVisible)
                    .opacity(state.page != .library ? 1 : 0)
                    .allowsHitTesting(state.page != .library)
                    .disabled(state.page == .library)
                    .accessibilityHidden(state.page == .library)
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
