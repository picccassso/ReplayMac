# Changelog

## 1.6.8

- Add session recording: start→stop capture that writes continuously and saves one MP4 (screen + system audio + mic) when stopped — available from the menu bar and a new hotkey, independent of the instant-replay buffer
- Add automatic recording while playing games: an opt-in mode that keeps the app idle until a game launches, records only for the duration of that game, and stops when the last game quits. Games are detected from the app's declared App Store "Games" category, plus a user-managed list of bundle identifiers for titles that don't declare one (many Steam games). It only stops recordings it started, so a manual recording is never interrupted
- Let users pick the clip date and time format: Settings > General adds Date format and Time format pickers (including day-first dotted dates) with live examples, feeding the `{date}` and `{time}` filename tokens. Existing users keep the current formats until they choose otherwise
- Make clip deletion discoverable in the library: right-click any row (or selection) for a context menu with Delete, press the Delete key on the selected clips, use the new Delete button in the single-clip detail bar, and double-click a row to preview; the Actions column is wider so the trash icon isn't clipped, and every action icon now has a tooltip
- Name displays in Settings by their actual model name (or "Built-in Display") rather than by their numeric display ID
- Stop losing the selected capture display: the choice was persisted as the raw `CGDirectDisplayID`, which macOS reassigns across reboots, display reconnects, dock/KVM renegotiation and GPU switches, so opening Settings silently reset the selection to the first display (and recordings fell back to it). Selections are now stored by the display's stable EDID identity and resolved at capture time; existing saved IDs — including those inside capture profiles — are migrated automatically while the display is attached. A selected display that is not connected right now stays selected and is shown as such instead of being overwritten
- Name displays in Settings by their actual model name (or "Built-in Display") rather than by their numeric display ID
- Make a wedged trim export recoverable instead of terminal: exports are watched for progress and cancelled after 90 seconds of no movement at all (progress-based, so a slow but advancing export is never killed), and a Cancel Export button appears while one is running. The watchdog runs off the main actor deliberately, so it still fires if the main actor is starved
- Build trim compositions off the main thread: the audio solo composition and the crop video composition were main-actor isolated despite doing synchronous track loading and `insertTimeRange` work that can take real time on a long clip
- Stop the export save panel from freezing the app: `NSSavePanel.runModal()` spun a nested modal run loop that does not service Swift concurrency's main-actor jobs, so while the panel was open every other main-actor continuation in the app — including the export that was about to run — was suspended; export destinations are now chosen with the non-blocking `begin(completionHandler:)`. This is the most likely cause of trim/crop exports hanging on a spinner and of the app then refusing to quit
- Pause the trim preview player before exporting, so the export is not decoding the same file as the still-playing preview
- Never strand the GIF export on a missing frame callback: deduplicate sample times that round onto the same tick (the generator coalesces identical requested times into one callback) and make the frame collector resume exactly once even if callback counts do not match
- Save session recordings without re-encoding the video: merging the system-audio and mic tracks forced a full transcode through `AVAssetExportSession`, decoding and re-encoding every frame just to combine two audio streams — and flattening the output to H.264 at roughly 12x the source bitrate regardless of the configured codec. An `AVAssetReader`/`AVAssetWriter` pair now passes video through in its stored format and confines encoding to audio. On a 5m39s 3024x1964 HEVC capture: 130.3s → 0.89s, 213 MB → 72 MB, codec preserved. Capture ingest also stops before the export so live capture no longer contends with it for the video encoder
- Stop session recording from also starting buffer recording: a session had no capture pipeline of its own, so starting one from idle also filled the quick-replay ring buffers and — with extended replay enabled — wrote a second copy of the same video to disk. The ring buffers are now gated during a session-only capture, the menu bar reports the session alone, and capture started by a session stops with it. A quick replay save during such a capture reports a distinct "replay buffer unavailable" failure instead of promising a buffer that will never fill
- Stop saved recordings from opening on a second or two of black: disk segments were opened on whatever frame arrived first, and a P-frame start left the player decoding frames whose keyframe was in no file. Segments now open only on a sync sample, and the encoder is asked for a keyframe when session recording or the extended buffer is enabled so the wait costs a single frame
- Fix the replay buffer coming up short of the configured window: the time cap was set to exactly the replay window, but eviction drops a whole keyframe group (~2s) at a time, so "Save Last 30 Seconds" handed back about 29s. The buffer now retains the window plus one keyframe interval of headroom while saves still request exactly the configured duration
- Defer auto-start capture past the launch window: starting the capture pipeline during the app's first layout pass was observed on macOS 26.5 corrupting the process's main dispatch queue, crashing every later main-actor isolation check. Auto-start now waits 2s for launch to settle; manual start, wake-resume, and game auto-record are unaffected
- Publish the Mac App Store edition as ReplayCap after App Review rejected "Mac" in the app name (Guideline 5.2.5); the direct/GitHub build keeps the ReplayMac name via a launch-time branding constant shared across both builds
- Share on-disk metadata and long-buffer names between both editions (`.ReplayCapClipLibrary.json`, `.ReplayCapLongBuffer`), migrating existing `.ReplayMac…` files automatically
- Require an explicit output-directory choice in the App Store build: the sandboxed edition has no access to any folder until the user picks one and grants a security-scoped bookmark, so it now starts with no output directory and prompts for one during onboarding, while direct builds keep defaulting to `~/Movies/ReplayMac`
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
