# Changelog

## Unreleased

- Add macOS share sheet and copy-file actions to the clip library
- Check GitHub Releases on launch and show an update link in the menu when a newer version is available

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
