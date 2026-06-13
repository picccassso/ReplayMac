# Changelog

## 1.5

- Merge system and microphone audio by default so shared clips keep mic audio on services that ignore secondary audio tracks
- Add a setting to keep system and microphone audio as separate tracks inside the MP4 for editing workflows
- Resume recording after system wake when recording was active before sleep, with a default-on setting to control the behavior
- Clarify the README audio wording: ReplayMac exports MP4 clips and does not create separate `.aac` sidecar files

## 1.4

- Add native macOS share sheet actions to the clip library
- Add copy-file actions to the clip library with short visual confirmation
- Check GitHub Releases for newer versions on app launch
- Show an update link in the menu bar menu when a newer version is available
- Add release tag comparison tests
- Add GitHub Actions CI for Swift builds and tests
- Fix ScreenCaptureKit concurrency import and build on CI
- Roll back partially started dual-display streams when either stream fails to start
- Apply the same dual-display rollback during GPU-pressure stream recreation
- Notify the user and restart capture when live settings reconfiguration fails
- Add a configurable hotkey for saving the extended replay buffer
- Include the extended replay shortcut in configured save hotkey detection
- Add live system audio and microphone level meters to audio settings
- Measure post-volume PCM levels with lightweight RMS sampling and decay
- Reset displayed audio levels when capture or microphone recording stops

## 1.3

- Fix separate dual-display save preflight so saves succeed when both display ring buffers are ready but the primary buffer is empty in separate-file mode
- Add clip organization: favorites, display names, tags, notes, search, and safe file renaming in the clip library
- Add storage visibility and cleanup tools to show total library usage and move non-favorite clips to Trash by age or in bulk
- Add capture profiles in Settings to save, apply, update, and delete named video/audio/buffer configurations
- Add renaming for capture profiles
- Fix a capture-handler MainActor crash during pipeline updates
- Improve capture pipeline backpressure and dual-display concurrency: dedicated secondary-display queue, compositing outside the compositor lock, microphone conversion off the realtime tap path, and a bounded long-buffer append pump with drop tracking in monitoring output
- Update README feature notes and refresh app screenshots

## 1.2

- Add selected-app system audio capture with a clearer System audio mode picker: Off, All apps, or Selected app only
- Refresh the selected-app audio picker while Settings is open when apps launch or quit
- Avoid surprising audio fallback: selected-app mode captures no system audio for the session if the selected app is unavailable
- Add quick trim/export controls to the clip library, using passthrough MP4 export when available
- Add an opt-in extended replay buffer with 5, 10, and 30 minute durations
- Show explicit disk usage and SSD write warnings before enabling the extended replay buffer
- Add a menu action for saving the extended replay window
- Open Settings on the General tab by default whenever the settings window is opened
- Update README feature notes for per-app audio, quick trim, and extended replay
- Add an explanatory note for SCK queue depth in Advanced settings

## 1.1

- Fix buffer duration not being applied to ring buffers
- Update README
- Update AI attribution doc
- Apply capture, encoding, and audio settings while recording without restarting
- Skip unused dual-display pipelines and reduce high-resolution capture overhead
- Improve bitrate slider commit behavior and preset recommendations
- Show honest save status on the menu bar badge and notify on capture/save failures
- Wire mic device selection and memory cap into the live pipeline
- Remove non-functional watermark toggle from settings
- Update README
- Remove Sparkle auto-update integration
- Remove unused watermark code
- Refresh README and screenshots
