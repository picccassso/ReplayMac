import AppKit
import Branding
import SwiftUI

public struct MainWindowView: View {
    @ObservedObject private var state: MainWindowState
    @ObservedObject private var exports: ClipExportCoordinator
    @State private var discardPresented = false

    public init(state: MainWindowState) {
        self.state = state
        self.exports = state.exports
    }

    public var body: some View {
        HStack(spacing: 0) {
            if state.sidebarVisible {
                navigation
                    .frame(width: 200)
                Divider()
            }
            VStack(spacing: 0) {
                header
                Divider()
                if exports.isBusy || exports.completedURL != nil || exports.errorMessage != nil {
                    exportStatus
                    Divider()
                }
                if state.page == .library, !state.isEditing, let editor = state.editor {
                    resumeBar(editor)
                    Divider()
                }
                ZStack {
                    ClipLibraryView(windowState: state)
                        .opacity(state.isLibraryFrontmost ? 1 : 0)
                        .allowsHitTesting(state.isLibraryFrontmost)
                        .disabled(!state.isLibraryFrontmost)
                        .accessibilityHidden(!state.isLibraryFrontmost)
                    if state.hasVisitedSettings {
                        SettingsView(selectedTab: $state.settingsTab,
                                     isVisible: state.page != .library && state.isWindowVisible)
                            .opacity(state.page != .library ? 1 : 0)
                            .allowsHitTesting(state.page != .library)
                            .disabled(state.page == .library)
                            .accessibilityHidden(state.page == .library)
                    }
                    if state.isEditing, let editor = state.editor {
                        ClipTrimView(session: editor, exports: exports) { state.select(.library) }
                            .id(editor.url)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onChange(of: state.isWindowVisible) { _, visible in
            if state.isEditing {
                if visible { state.editor?.isVisible = true }
                else { state.editor?.pause() }
            }
        }
        .background(AppTheme.backgroundPrimary)
        .tint(AppTheme.accent)
        .alert("Replace Current Edit?", isPresented: Binding(
            get: { state.replacementCandidate != nil },
            set: { if !$0 { state.replacementCandidate = nil } }
        )) {
            Button("Replace Edit", role: .destructive) { state.replaceEditor() }
            Button("Keep Current Edit", role: .cancel) { state.replacementCandidate = nil }
        } message: {
            Text("Your current trim and crop choices will be discarded. Exported files are kept.")
        }
        .alert("Discard Current Edit?", isPresented: $discardPresented) {
            Button("Discard Edit", role: .destructive) { state.discardEditor() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("This clears your trim and crop choices. The original clip and exported files are kept.")
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "arrow.counterclockwise.circle.fill")
                    .font(.system(size: 23))
                    .foregroundStyle(AppTheme.accent)
                Text(AppBranding.name)
                    .font(.system(size: 17, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 18)
            .padding(.top, 24)
            .padding(.bottom, 26)
            navigationRow(.library)
            Text("SETTINGS")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 22)
                .padding(.top, 28)
                .padding(.bottom, 8)
            ForEach(MainWindowPage.allCases.filter { $0 != .library }) { page in navigationRow(page) }
            Spacer()
        }
        .padding(.horizontal, 10)
        .background(AppTheme.backgroundSecondary)
    }

    private func navigationRow(_ page: MainWindowPage) -> some View {
        Button { state.select(page) } label: {
            HStack(spacing: 10) {
                Image(systemName: page.icon).frame(width: 20)
                Text(page.title)
                Spacer(minLength: 0)
            }
            .font(.system(size: 13, weight: state.page == page ? .semibold : .medium, design: .rounded))
            .foregroundStyle(state.page == page ? AppTheme.accentSecondary : AppTheme.textPrimary)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .background(state.page == page ? AppTheme.accent.opacity(0.13) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .padding(.vertical, 2)
        .accessibilityAddTraits(state.page == page ? .isSelected : [])
    }

    private var header: some View {
        HStack(spacing: 14) {
            Button { state.toggleSidebar() } label: {
                Image(systemName: "sidebar.left").font(.system(size: 17))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(state.sidebarVisible ? "Hide sidebar" : "Show sidebar")
            .accessibilityLabel(state.sidebarVisible ? "Hide sidebar" : "Show sidebar")
            if state.isEditing {
                Button { state.select(.library) } label: { Label("Library", systemImage: "chevron.left") }
                    .buttonStyle(.plain)
                    .foregroundStyle(AppTheme.accent)
            }
            Text(state.isEditing ? "Trim & Export" : state.page.title)
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Spacer()
            if state.isEditing {
                Button("Discard Edit") { discardPresented = true }
                    .disabled(exports.isBusy)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 17)
    }

    private func resumeBar(_ editor: ClipEditorSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "scissors").foregroundStyle(AppTheme.accent)
            Text(editor.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
            Text("Editing paused").foregroundStyle(.secondary)
            Spacer()
            Button("Resume Editing") { state.resumeEditor() }.buttonStyle(AccentButtonStyle())
            Button("Discard") { discardPresented = true }.disabled(exports.isBusy)
        }
        .font(.system(size: 12, design: .rounded))
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(AppTheme.accent.opacity(0.04))
    }

    private var exportStatus: some View {
        HStack(spacing: 12) {
            if exports.isBusy {
                if let progress = exports.progress {
                    ProgressView(value: progress).frame(width: 100)
                } else { ProgressView().controlSize(.small) }
                Text(exports.title)
                if let source = exports.sourceURL {
                    Text(source.lastPathComponent).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if state.editor != nil {
                    Button("Editor") { state.resumeEditor() }
                }
                Button("Cancel Export") { exports.cancel() }
            } else {
                Image(systemName: exports.errorMessage == nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(exports.errorMessage == nil ? AppTheme.success : .orange)
                Text(exports.errorMessage ?? "Export complete")
                    .lineLimit(2).textSelection(.enabled)
                Spacer()
                if let url = exports.completedURL {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                }
                Button { exports.dismissResult() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).help("Dismiss export result")
            }
        }
        .font(.system(size: 12, design: .rounded))
        .padding(.horizontal, 22)
        .padding(.vertical, 10)
        .background(AppTheme.backgroundSecondary)
    }
}
