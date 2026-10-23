import SwiftUI
import AppKit
// @preconcurrency: kept from ClipLibraryView.swift, where this code used to
// live, so Swift 6.1 (GitHub's macos-latest runners) checks it the same way.
@preconcurrency import AVFoundation
import AVKit

struct ClipPreviewView: View {
    let url: URL
    var onClose: () -> Void = {}
    @State private var player: AVPlayer?
    @State private var audioTrackChoices: [AudioTrackChoice] = []
    @State private var selectedAudioTrackID = AudioTrackChoice.allTracksID

    var body: some View {
        VStack(spacing: 14) {
            if let player {
                AVPlayerViewRepresentable(player: player)
                    .frame(minWidth: 640, minHeight: 360)
                    .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 6)
            } else {
                ZStack {
                    AppTheme.backgroundSecondary
                    ProgressView("Loading preview…")
                }
                .frame(minWidth: 640, minHeight: 360)
                .clipShape(RoundedRectangle(cornerRadius: AppTheme.cornerRadiusMedium, style: .continuous))
            }

            if !audioTrackChoices.isEmpty {
                AudioTrackPickerView(choices: audioTrackChoices, selection: $selectedAudioTrackID)
            }

            Text(url.lastPathComponent)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
        }
        .padding(16)
        .background(
            SheetOutsideClickMonitor {
                onClose()
            }
        )
        .onExitCommand {
            onClose()
        }
        .task {
            await loadPlayer()
        }
        .onChange(of: selectedAudioTrackID) { _, newValue in
            ClipAudioTracks.apply(selection: newValue, choices: audioTrackChoices, to: player?.currentItem)
        }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private func loadPlayer() async {
        guard player == nil else { return }
        let asset = AVURLAsset(url: url)
        audioTrackChoices = await ClipAudioTracks.choices(for: asset)
        let newPlayer = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        ClipAudioTracks.apply(selection: selectedAudioTrackID, choices: audioTrackChoices, to: newPlayer.currentItem)
        newPlayer.play()
        player = newPlayer
    }
}

private struct AudioTrackPickerView: View {
    let choices: [AudioTrackChoice]
    @Binding var selection: CMPersistentTrackID
    var help = "Choose which audio track you hear. Playback only — the file keeps all tracks."

    var body: some View {
        HStack(spacing: 8) {
            Label("Audio", systemImage: "speaker.wave.2")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(AppTheme.textSecondary)
            Picker("Audio track", selection: $selection) {
                Text("All Tracks").tag(AudioTrackChoice.allTracksID)
                ForEach(choices) { choice in
                    Text(choice.label).tag(choice.id)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
            .help(help)
            Spacer()
        }
    }
}

private struct AVPlayerViewRepresentable: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}
