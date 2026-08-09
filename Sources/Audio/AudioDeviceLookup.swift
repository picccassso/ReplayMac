import Foundation
@preconcurrency import AVFoundation
import CoreAudio

/// Resolves Core Audio input devices by UID and binds them to an
/// AVAudioEngine input node. Shared by the recording mic capture and the
/// idle level preview so both select the same device for a given setting.
enum AudioDeviceLookup {
    static func applyInputDevice(uid: String, to engine: AVAudioEngine) throws {
        guard let audioDeviceID = deviceID(forUID: uid),
              let inputUnit = engine.inputNode.audioUnit else {
            throw MicCaptureError.deviceNotFound
        }

        var deviceID = audioDeviceID
        let status = AudioUnitSetProperty(
            inputUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard status == noErr else {
            throw MicCaptureError.cannotSetInputDevice(status)
        }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        ) == noErr else {
            return nil
        }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        ) == noErr else {
            return nil
        }

        for deviceID in deviceIDs {
            guard let deviceUID = deviceUID(for: deviceID), deviceUID == uid else {
                continue
            }
            return deviceID
        }

        return nil
    }

    static func deviceUID(for deviceID: AudioDeviceID) -> String? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &propertyAddress, 0, nil, &propertySize) == noErr else {
            return nil
        }

        var uid: CFString?
        let status = withUnsafeMutablePointer(to: &uid) { pointer in
            AudioObjectGetPropertyData(deviceID, &propertyAddress, 0, nil, &propertySize, pointer)
        }
        guard status == noErr, let uid else {
            return nil
        }

        return uid as String
    }
}
