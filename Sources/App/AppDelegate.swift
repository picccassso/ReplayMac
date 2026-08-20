import Cocoa
import Branding
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
    lazy var videoRingBuffer = VideoRingBuffer(timeCap: AppSettings.ringBufferTimeCapSeconds)
    let dualDisplay1VideoEncoder = VideoEncoder()
    let dualDisplay2VideoEncoder = VideoEncoder()
    lazy var dualDisplay1VideoRingBuffer = VideoRingBuffer(timeCap: AppSettings.ringBufferTimeCapSeconds)
    lazy var dualDisplay2VideoRingBuffer = VideoRingBuffer(timeCap: AppSettings.ringBufferTimeCapSeconds)

    let systemAudioCapture = SystemAudioCapture()
    let perAppAudioCapture = PerAppAudioCapture()
    let micAudioCapture = MicCapture()
    let systemAudioEncoder = AudioEncoder()
    let micAudioEncoder = AudioEncoder()
    lazy var systemAudioRingBuffer = AudioRingBuffer(timeCap: AppSettings.ringBufferTimeCapSeconds)
    lazy var micAudioRingBuffer = AudioRingBuffer(timeCap: AppSettings.ringBufferTimeCapSeconds)

    lazy var clipSaver = ClipSaver(
        videoRingBuffer: videoRingBuffer,
        dualDisplay1VideoRingBuffer: dualDisplay1VideoRingBuffer,
        dualDisplay2VideoRingBuffer: dualDisplay2VideoRingBuffer,
        systemAudioRingBuffer: systemAudioRingBuffer,
        micRingBuffer: micAudioRingBuffer
    )
    let longBufferRecorder = LongBufferRecorder()
    let sessionRecorder = LongBufferRecorder()
    lazy var longBufferAppendPump = LongBufferAppendPump(
        recorders: [longBufferRecorder, sessionRecorder]
    )
    /// Gates the replay ring buffers. Off while a session recording owns the
    /// capture pipeline, so a session never fills a buffer the user did not ask for.
    let replayBufferGate = ReplayBufferGate()
    /// True when the capture pipeline was started by a session recording rather
    /// than by buffer recording, and so should be torn down when it stops.
    var sessionOwnsCapturePipeline = false
    /// True while a start→stop session recording is actively writing to disk.
    var isSessionRecording = false
    var isSessionFinalizeInProgress = false
    var isTerminatingAfterSessionSave = false

    let menuBarState = MenuBarState()
    let statusItemController = StatusItemController()
    let hotkeyManager = HotkeyManager()
    let gameActivityMonitor = GameActivityMonitor()

    /// True while the current recording was started automatically because a game
    /// is running. Ensures the game watcher only stops recordings it started,
    /// never a manual one.
    var recordingAutoStartedByGame = false

    /// The capture pipeline owns the audio devices while it runs, so the idle
    /// level preview stands down for exactly as long as this is true.
    var isCaptureRunning = false {
        didSet {
            guard isCaptureRunning != oldValue else { return }
            AudioLevelPreview.shared.setCaptureActive(isCaptureRunning)
        }
    }
    var isWorkspaceSessionActive = true
    var areScreensAwake = true
    var shouldResumeCaptureAfterInterruption = false
    var isPreparingCaptureRecovery = false
    var captureRecoveryAttempts = 0
    var captureRecoveryTask: Task<Void, Never>?
    var displayReconfigurationTask: Task<Void, Never>?
    var monitoringTask: Task<Void, Never>?
    var clipLibraryWindowController: NSWindowController?
    var onboardingWindowController: NSWindowController?
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
    var lastMicEnabled = false
    var lastMicDeviceID = ""
    var hasNotifiedMicDenied = false
    /// Latches the system-audio stall warning so a persistent stall logs once
    /// per outage instead of every monitoring tick.
    var hasWarnedSystemAudioStalled = false
    /// Whether system audio is coming from the main ScreenCaptureKit stream
    /// this session. Per-app audio runs its own stream and reports no stats, so
    /// the stall watchdog must not judge it by the main stream's samples.
    var isCapturingMainSystemAudio = false

    override init() {
        // Branding must be set before anything builds user-facing strings or
        // compares against branded defaults (migrateLegacyBrandDefaults). The
        // APPSTORE condition reaches these sources in both build pipelines
        // (build-app.sh --appstore and the Xcode wrapper) but not the package
        // modules — they read AppBranding at runtime.
        #if APPSTORE
        AppBranding.name = "ReplayCap"
        AppBranding.requiresExplicitOutputDirectorySelection = true
        #else
        AppBranding.name = "ReplayMac"
        AppBranding.requiresExplicitOutputDirectorySelection = false
        #endif
        // Capture legacy-install state before any AppSettings access can seed
        // the preferences domain and make a clean install look established.
        OnboardingState.migrateExistingInstallationIfNeeded()
        super.init()
        AppSettings.migrateLegacyBrandDefaults()
        lastMicEnabled = AppSettings.captureMicrophone
        lastMicDeviceID = AppSettings.microphoneID
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Must run before anything touches the output directory: under the
        // sandbox, access to a custom output folder only exists while the
        // security-scoped bookmark is being accessed.
#if APPSTORE
        let restoredOutputDirectoryAccess = OutputDirectoryAccess.restore()
        // App Store builds intentionally have no blanket Movies-folder
        // entitlement. Existing installs from an older build may therefore
        // need to choose their output folder once to create a bookmark.
        if !restoredOutputDirectoryAccess {
            // Do not carry an unbookmarked path forward as a proposed location.
            // The user must make a fresh choice through the standard picker.
            Defaults.reset(.outputDirectoryPath)
            Defaults[.hasCompletedOnboarding] = false
        }
#else
        OutputDirectoryAccess.restore()
#endif

        NotificationManager.shared.requestAuthorization()

        // Must run before the first capture starts, so a selection saved as a raw
        // CGDirectDisplayID is upgraded to a stable key while that display is attached.
        AppSettings.migrateDisplaySelectionsIfNeeded()

        configurePipelines()

        statusItemController.onSaveClip = { [weak self] in
            self?.saveClipFromUI()
        }
        statusItemController.onSaveLongBuffer = { [weak self] in
            self?.saveLongBufferFromUI()
        }
        statusItemController.onToggleSessionRecording = { [weak self] in
            self?.toggleSessionRecording()
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
        setupDisplayObservers()

        // First launch: walk through the setup assistant before anything
        // records. Auto-start (and its screen-recording permission prompt)
        // waits until the user finishes onboarding.
        //
        // When game auto-record is on it owns the recording lifecycle: the app
        // stays idle (no buffering) until a game runs, so it must not auto-start
        // here. If a game is already open at launch, setupGameAutoRecord's scan
        // starts recording instead.
        if !Defaults[.hasCompletedOnboarding] {
            showOnboardingWindow()
        } else if AppSettings.autoStartRecordingOnLaunch, !AppSettings.autoRecordGamesEnabled {
            // Auto-start must not overlap the app's first layout pass: spinning up
            // the capture pipeline during launch-time SwiftUI/AppKit layout has
            // been observed (macOS 26.5) corrupting the process's main dispatch
            // queue header, after which any main-actor isolation check crashes.
            // Deferring capture past the launch window avoids the overlap.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                guard let self, !self.isCaptureRunning else { return }
                self.startCapturePipeline(userInitiated: false)
            }
        }

        bufferDurationObservation = Defaults.observe(.bufferDurationSeconds) { [weak self] _ in
            self?.syncBufferDurationToSettings()
        }

        setupSettingsObservations()
        setupGameAutoRecord()
        syncMemoryCapsToSettings()

        DispatchQueue.main.async { [weak self] in
            self?.updateActivationPolicy(bringVisibleWindowToFront: true)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        monitoringTask?.cancel()
        settingsReconcileTask?.cancel()
        captureRecoveryTask?.cancel()
        displayReconfigurationTask?.cancel()
        if !isTerminatingAfterSessionSave {
            stopCapturePipeline()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Finish an in-progress session recording before quitting so the file
        // is not left as orphaned temp segments.
        guard isSessionRecording || isSessionFinalizeInProgress else {
            return .terminateNow
        }
        if isTerminatingAfterSessionSave {
            return .terminateNow
        }
        isTerminatingAfterSessionSave = true
        Task { @MainActor in
            await stopSessionRecording(userInitiated: false)
            await stopCapturePipelineAsync()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

}
