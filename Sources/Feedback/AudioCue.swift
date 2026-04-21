import Foundation
import AudioToolbox

public enum AudioCue {
    public static func playSaveSuccess() {
        AudioServicesPlaySystemSound(1113)
    }
}
