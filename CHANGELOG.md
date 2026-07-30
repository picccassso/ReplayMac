# Changelog

## Unreleased

- Make a wedged trim export recoverable instead of terminal: exports are watched for progress and cancelled after 90 seconds of no movement at all (progress-based, so a slow but advancing export is never killed), and a Cancel Export button appears while one is running. The watchdog runs off the main actor deliberately, so it still fires if the main actor is starved
- Build trim compositions off the main thread: the audio solo composition and the crop video composition were main-actor isolated despite doing synchronous track loading and `insertTimeRange` work that can take real time on a long clip
- Stop the export save panel from freezing the app: `NSSavePanel.runModal()` spun a nested modal run loop that does not service Swift concurrency's main-actor jobs, so while the panel was open every other main-actor continuation in the app — including the export that was about to run — was suspended; export destinations are now chosen with the non-blocking `begin(completionHandler:)`. This is the most likely cause of trim/crop exports hanging on a spinner and of the app then refusing to quit
- Pause the trim preview player before exporting, so the export is not decoding the same file as the still-playing preview
- Never strand the GIF export on a missing frame callback: deduplicate sample times that round onto the same tick (the generator coalesces identical requested times into one callback) and make the frame collector resume exactly once even if callback counts do not match
- Make clip deletion discoverable in the library: right-click any row (or selection) for a context menu with Delete, press the Delete key on the selected clips, use the new Delete button in the single-clip detail bar, and double-click a row to preview; the Actions column is wider so the trash icon isn't clipped, and every action icon now has a tooltip
- Add session recording: start→stop capture that writes continuously and saves one MP4 (screen + system audio + mic) when stopped — available from the menu bar and a new hotkey, independent of the instant-replay buffer
- Publish the Mac App Store edition as ReplayCap after App Review rejected "Mac" in the app name (Guideline 5.2.5); the direct/GitHub build keeps the ReplayMac name via a launch-time branding constant shared across both builds
- Share on-disk metadata and long-buffer names between both editions (`.ReplayCapClipLibrary.json`, `.ReplayCapLongBuffer`), migrating existing `.ReplayMac…` files automatically
- Notarize the direct-download build: release DMGs are signed with a Developer ID certificate, hardened runtime, and a stapled notarization ticket, so the app opens without Gatekeeper workarounds

## 1.6.7

- Add crop support to clip trim and GIF export: a crop toggle in the trim sheet with a draggable selection overlay (resize handles, centre move control, and free/16:9/1:1/4:3/9:16 aspect presets); MP4 exports apply the crop through a video composition with output dimensions snapped to even values for the encoder, and GIF exports crop and rescale each frame with oversampling so narrow crops stay sharp
- Add a first-run welcome flow that guides new users through output-folder selection, capture preferences, hotkeys, and startup options, persisting access to user-selected folders and using standard save dialogs for exports
- First Mac App Store release: sandboxed build with security-scoped bookmarks for custom output folders; the App Store variant relies on the App Store for updates and makes no network connections
- Add audio track selection to clip preview and trim export: when audio tracks are kept separate, Quick Preview and Trim offer an All Tracks / System Audio / Microphone picker, and Trim & Export drops unselected tracks from the output (passthrough, no re-encode) with the track name in the filename
- Add a manual hotkey setup guide (docs/manual-hotkey-setup.md) for macOS versions where a system bug breaks the Settings shortcut recorder, with `defaults write` instructions for all six actions
- Replace the pulsing menu-bar recording dot with a static one, eliminating a continuously repeating animation that redrew the status item while recording
- Cap the displayed recording time at the configured replay window (quick replay, or extended replay when enabled) instead of counting the full session

## 1.6.6

- Recover long-buffer recording after writer failures: reset failed or cancelled writers immediately, remove incomplete segment files, and let the next sample start a fresh segment
- Clarify recording and replay buffer status: keep the menu-bar timer advancing for the full session, and show recording time, quick-replay availability, and extended-replay availability as separate states
- Harden long-buffer saves and capture recovery: serialize extended replay exports, pin segments with deferred deletion, export from isolated copies, reset failed writers, and recover recording after screen sleep or session transitions
- Stabilize capture recovery after wake: preserve resume intent across sleep and session transitions, validate recovery via video callbacks rather than stream-start return values, and retry display-unavailable failures with backoff
- Disable replay saves during export: gray out both quick replay and extended replay menu actions whenever any clip is being written or exported

## 1.6.5

- Add Retina capture resolution for HiDPI displays while keeping the macOS UI at its current scaled size
- Clarify logical, Retina, and custom output sizes in video settings, including dual-display output details
- Fix Swift concurrency warnings in GIF export

## 1.6

- Add "Open Last Clip" and "Reveal Last Clip in Finder" menu bar items, shown after the first successful save of the session and hidden if the clip is later moved or deleted
- Add "Open" and "Reveal in Finder" action buttons to the clip-saved notification banner
- Add a configurable hotkey to open the clip library
- Cache and parallelize clip library thumbnail loading to eliminate reload lag in large libraries
- Add multi-select batch actions to the clip library: favorite/unfavorite, share, add tags to all selected clips, and bulk delete with a confirmation that names the count and warns when favorites are included
- Warn before saving when the disk is nearly full, estimating clip size from the configured bitrate and blocking the save when free space falls below the estimate plus a 200 MB margin; fails open if capacity cannot be determined
- Add GIF export from the clip library (whole clip, Medium size by default) and from the trim view (selected range, with Small/Medium/Large size options); exports are written next to the source clip and revealed in Finder
- Add customizable clip file-name templates with {app}, {date}, and {time} tokens, configurable in Settings > General with a live preview, a token legend, and a reset action; the default template preserves the existing naming behavior
- Fix high-pitched system audio in merged clips

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
