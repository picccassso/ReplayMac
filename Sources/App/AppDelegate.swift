import Cocoa
import Capture
import Encode
import RingBuffer
import Audio
import Save
import UI
import Hotkeys
import Feedback
import Defaults

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, @unchecked Sendable {
    let captureManager = CaptureManager()
    let frameCompositor = FrameCompositor()
    let videoEncoder = VideoEncoder()
    let videoRingBuffer = VideoRingBuffer(timeCap: TimeInterval(AppSettings.bufferDurationSeconds))
    let dualDisplay1VideoEncoder = VideoEncoder()
    let dualDisplay2VideoEncoder = VideoEncoder()
    let dualDisplay1VideoRingBuffer = VideoRingBuffer(timeCap: TimeInterval(AppSettings.bufferDurationSeconds))
    let dualDisplay2VideoRingBuffer = VideoRingBuffer(timeCap: TimeInterval(AppSettings.bufferDurationSeconds))

    let systemAudioCapture = SystemAudioCapture()
    let perAppAudioCapture = PerAppAudioCapture()
    let micAudioCapture = MicCapture()
    let systemAudioEncoder = AudioEncoder()
    let micAudioEncoder = AudioEncoder()
    let systemAudioRingBuffer = AudioRingBuffer(timeCap: TimeInterval(AppSettings.bufferDurationSeconds))
    let micAudioRingBuffer = AudioRingBuffer(timeCap: TimeInterval(AppSettings.bufferDurationSeconds))

    lazy var clipSaver = ClipSaver(
        videoRingBuffer: videoRingBuffer,
        dualDisplay1VideoRingBuffer: dualDisplay1VideoRingBuffer,
        dualDisplay2VideoRingBuffer: dualDisplay2VideoRingBuffer,
        systemAudioRingBuffer: systemAudioRingBuffer,
        micRingBuffer: micAudioRingBuffer
    )
    let longBufferRecorder = LongBufferRecorder()
    lazy var longBufferAppendPump = LongBufferAppendPump(recorder: longBufferRecorder)

    let menuBarState = MenuBarState()
    let statusItemController = StatusItemController()
    let hotkeyManager = HotkeyManager()

    var isCaptureRunning = false
    var isWorkspaceSessionActive = true
    var areScreensAwake = true
    var shouldResumeCaptureAfterInterruption = false
    var isPreparingCaptureRecovery = false
    var captureRecoveryAttempts = 0
    var captureRecoveryTask: Task<Void, Never>?
    var monitoringTask: Task<Void, Never>?
    var clipLibraryWindowController: NSWindowController?
    var bufferDurationObservation: Defaults.Observation?
    var settingsObservations: [Defaults.Observation] = []
    var settingsReconcileTask: Task<Void, Never>?
    var pendingRuntimeSettingsReconcile = false
    var pendingRuntimeFullRestart = false

    // Current capture dimensions for runtime reconfiguration
    // Stores the original (unscaled) display dimensions so resolution
    // scaling can be re-applied on each pipeline-shape change.
    var originalDisplayWidth: Int = 0
    var originalDisplayHeight: Int = 0
    var originalDisplayPointPixelScale: Double = 1.0
    var originalDisplayPixelWidth: Int = 0
    var originalDisplayPixelHeight: Int = 0
    var currentFPS: Int = 60
    var isDualMode: Bool = false
    var originalDualWidth1: Int = 0
    var originalDualHeight1: Int = 0
    var originalDualPointPixelScale1: Double = 1.0
    var originalDualPixelWidth1: Int = 0
    var originalDualPixelHeight1: Int = 0
    var originalDualWidth2: Int = 0
    var originalDualHeight2: Int = 0
    var originalDualPointPixelScale2: Double = 1.0
    var originalDualPixelWidth2: Int = 0
    var originalDualPixelHeight2: Int = 0
    var lastMicEnabled = AppSettings.captureMicrophone
    var lastMicDeviceID = AppSettings.microphoneID
    var hasNotifiedMicDenied = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.requestAuthorization()

        configurePipelines()

        statusItemController.onSaveClip = { [weak self] in
            self?.saveClipFromUI()
        }
        statusItemController.onSaveLongBuffer = { [weak self] in
            self?.saveLongBufferFromUI()
        }
        statusItemController.onToggleRecording = { [weak self] in
            self?.toggleCapturePipeline()
        }
        statusItemController.onOpenClipLibrary = { [weak self] in
            self?.openClipLibraryWindow()
        }
        statusItemController.onOpenSettings = { [weak self] in
            self?.openSettingsWindow()
        }
        statusItemController.setup(state: menuBarState)
        checkForAvailableUpdate()
        configureHotkeys()
        Task {
            await captureManager.activateDelegateCallbacks()
            await captureManager.setInterruptionHandler { [weak self] interruption in
                Task { @MainActor in
                    self?.handleCaptureInterruption(interruption)
                }
            }
        }

        setupWindowObservers()
        setupPowerObservers()

        if AppSettings.autoStartRecordingOnLaunch {
            startCapturePipeline(userInitiated: false)
        }

        bufferDurationObservation = Defaults.observe(.bufferDurationSeconds) { [weak self] _ in
            self?.syncBufferDurationToSettings()
        }

        setupSettingsObservations()
        syncMemoryCapsToSettings()

        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicy(bringVisibleWindowToFront: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitoringTask?.cancel()
        settingsReconcileTask?.cancel()
        captureRecoveryTask?.cancel()
        stopCapturePipeline()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

}
