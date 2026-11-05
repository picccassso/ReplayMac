import XCTest
import AVFoundation
@testable import Audio

/// Drives the microphone's real tap-to-output conversion with the channel
/// layouts audio interfaces report. Asking AVAudioConverter to change the
/// channel count left numbered (discrete or unknown) inputs silent or kept
/// only the first two, so every input must come through here.
final class MicChannelConversionTests: XCTestCase {
    func testFourInputInterfaceKeepsEveryInput() throws {
        let tags: [(String, AudioChannelLayoutTag)] = [
            ("discrete", kAudioChannelLayoutTag_DiscreteInOrder | 4),
            ("unknown", kAudioChannelLayoutTag_Unknown | 4),
            ("quadraphonic", kAudioChannelLayoutTag_Quadraphonic)
        ]
        for (name, tag) in tags {
            for interleaved in [false, true] {
                guard let layout = AVAudioChannelLayout(layoutTag: tag) else { continue }
                let format = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: 44_100,
                    interleaved: interleaved,
                    channelLayout: layout
                )
                for channel in 0..<4 {
                    let peaks = try convertTone(onChannel: channel, inputFormat: format, outputChannels: 2)
                    let label = "\(name) interleaved=\(interleaved) input \(channel + 1)"
                    XCTAssertEqual(peaks.count, 2, label)
                    // One live input among silent ones keeps its own level.
                    XCTAssertGreaterThan(peaks[channel % 2], 0.45, "\(label) lost or turned down: \(peaks)")
                    XCTAssertLessThan(peaks[(channel + 1) % 2], 0.01, "\(label) leaked: \(peaks)")
                }
            }
        }
    }

    /// Stereo into a mono run is averaged: each side alone comes through at
    /// half level, and the same signal on both sides keeps its level instead
    /// of doubling into clipping.
    func testStereoDeviceIntoMonoRunAveragesBothInputs() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 2))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        for channel in 0..<2 {
            let peaks = try convertTone(onChannel: channel, inputFormat: format, outputChannels: 1)
            XCTAssertEqual(peaks[0], 0.25, accuracy: 0.03, "input \(channel + 1): \(peaks)")
        }
        let both = try convertTone(onChannels: [0, 1], inputFormat: format, outputChannels: 1)
        XCTAssertEqual(both[0], 0.5, accuracy: 0.03, "correlated stereo: \(both)")
    }

    func testMonoDeviceIntoStereoRunFillsBothOutputs() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1))
        let peaks = try convertTone(onChannel: 0, inputFormat: format, outputChannels: 2)
        XCTAssertGreaterThan(peaks[0], 0.3)
        XCTAssertGreaterThan(peaks[1], 0.3)
    }

    /// An 8-input interface with one mic: the voice must not drop by the
    /// number of inputs it is folded with.
    func testWideInterfaceKeepsASingleMicAtFullLevel() throws {
        let layout = try XCTUnwrap(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | 8))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, interleaved: false, channelLayout: layout)
        for outputChannels: AVAudioChannelCount in [1, 2] {
            let peaks = try convertTone(onChannel: 0, inputFormat: format, outputChannels: outputChannels)
            XCTAssertGreaterThan(peaks[0], 0.45, "8 inputs to \(outputChannels): \(peaks)")
        }
    }

    /// Peak level of each output channel after converting 0.1 s of a 0.5
    /// amplitude tone placed on one input channel.
    private func convertTone(
        onChannel toneChannel: Int,
        inputFormat: AVAudioFormat,
        outputChannels: AVAudioChannelCount
    ) throws -> [Float] {
        try convertTone(onChannels: [toneChannel], inputFormat: inputFormat, outputChannels: outputChannels)
    }

    private func convertTone(
        onChannels toneChannels: Set<Int>,
        inputFormat: AVAudioFormat,
        outputChannels: AVAudioChannelCount
    ) throws -> [Float] {
        let conversion = try XCTUnwrap(MicCapture.makeConversion(inputFormat: inputFormat, outputChannels: outputChannels))
        let frames = AVAudioFrameCount(inputFormat.sampleRate / 10)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        let channels = Int(inputFormat.channelCount)
        for frame in 0..<Int(frames) {
            let value = Float(sin(2 * Double.pi * 440 * Double(frame) / inputFormat.sampleRate) * 0.5)
            for channel in 0..<channels {
                let sample = toneChannels.contains(channel) ? value : 0
                if inputFormat.isInterleaved {
                    data[0][frame * buffer.stride + channel] = sample
                } else {
                    data[channel][frame] = sample
                }
            }
        }

        let output = try XCTUnwrap(MicCapture.convert(
            buffer,
            fold: conversion.fold,
            converter: conversion.converter,
            output: conversion.output
        ))
        XCTAssertEqual(output.format.channelCount, outputChannels)
        let samples = try XCTUnwrap(output.floatChannelData)[0]
        var peaks = [Float](repeating: 0, count: Int(outputChannels))
        for frame in 0..<Int(output.frameLength) {
            for channel in 0..<Int(outputChannels) {
                peaks[channel] = max(peaks[channel], abs(samples[frame * Int(outputChannels) + channel]))
            }
        }
        return peaks
    }
}
