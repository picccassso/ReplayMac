import Foundation
import AudioToolbox
import AVFoundation

public enum AudioCue {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var activePlayer: AVAudioPlayer?
    private static let muteWavData = makeTwoToneWavData(firstHz: 660, secondHz: 440)
    private static let unmuteWavData = makeTwoToneWavData(firstHz: 440, secondHz: 660)

    public static func playSaveSuccess() {
        AudioServicesPlaySystemSound(1113)
    }

    /// Plays a subtle descending two-tone chime in-process so ScreenCaptureKit's
    /// `excludesCurrentProcessAudio` keeps it out of recorded system audio.
    public static func playMute() {
        playWavData(muteWavData)
    }

    /// Plays a subtle ascending two-tone chime in-process so ScreenCaptureKit's
    /// `excludesCurrentProcessAudio` keeps it out of recorded system audio.
    public static func playUnmute() {
        playWavData(unmuteWavData)
    }

    private static func playWavData(_ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        do {
            let player = try AVAudioPlayer(data: data)
            player.volume = 0.28
            player.prepareToPlay()
            player.play()
            activePlayer = player
        } catch {
            AudioServicesPlaySystemSound(1104)
        }
    }

    /// Generates a 16-bit 48 kHz mono WAV containing two short sine notes with
    /// raised-cosine attack/release envelopes so there are no clicks.
    internal static func makeTwoToneWavData(
        firstHz: Double,
        secondHz: Double,
        noteDurationSeconds: Double = 0.045,
        gapDurationSeconds: Double = 0.012,
        sampleRate: Int = 48_000
    ) -> Data {
        let noteFrames = max(1, Int(noteDurationSeconds * Double(sampleRate)))
        let gapFrames = max(0, Int(gapDurationSeconds * Double(sampleRate)))
        let totalFrames = noteFrames * 2 + gapFrames
        var samples = [Int16](repeating: 0, count: totalFrames)

        func writeNote(frequency: Double, startFrame: Int) {
            let fadeFrames = max(1, min(noteFrames / 4, Int(0.008 * Double(sampleRate))))
            for i in 0..<noteFrames {
                let t = Double(i) / Double(sampleRate)
                let envelope: Double
                if i < fadeFrames {
                    envelope = 0.5 * (1.0 - cos(.pi * Double(i) / Double(fadeFrames)))
                } else if i >= noteFrames - fadeFrames {
                    let remaining = noteFrames - 1 - i
                    envelope = 0.5 * (1.0 - cos(.pi * Double(remaining) / Double(fadeFrames)))
                } else {
                    envelope = 1.0
                }
                let raw = sin(2.0 * .pi * frequency * t) * envelope * 0.45
                let clamped = max(-1.0, min(1.0, raw))
                samples[startFrame + i] = Int16(clamped * Double(Int16.max))
            }
        }

        writeNote(frequency: firstHz, startFrame: 0)
        writeNote(frequency: secondHz, startFrame: noteFrames + gapFrames)

        let dataSize = UInt32(totalFrames * MemoryLayout<Int16>.size)
        let riffChunkSize = UInt32(36) + dataSize
        let byteRate = UInt32(sampleRate * MemoryLayout<Int16>.size)
        let blockAlign = UInt16(MemoryLayout<Int16>.size)
        let bitsPerSample = UInt16(16)

        var data = Data(capacity: Int(44 + dataSize))
        data.append(contentsOf: "RIFF".utf8)
        withUnsafeBytes(of: riffChunkSize.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        withUnsafeBytes(of: UInt32(16).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { data.append(contentsOf: $0) } // PCM
        withUnsafeBytes(of: UInt16(1).littleEndian) { data.append(contentsOf: $0) } // Mono
        withUnsafeBytes(of: UInt32(sampleRate).littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { data.append(contentsOf: $0) }
        data.append(contentsOf: "data".utf8)
        withUnsafeBytes(of: dataSize.littleEndian) { data.append(contentsOf: $0) }
        samples.withUnsafeBufferPointer { buffer in
            data.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(buffer.baseAddress)?.assumingMemoryBound(to: UInt8.self),
                count: Int(dataSize)
            ))
        }
        return data
    }
}
