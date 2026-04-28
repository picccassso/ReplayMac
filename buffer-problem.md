# Buffer Duration Problem

## Issue

ReplayMac exposes a configurable replay buffer duration in settings, but the actual in-memory capture buffers are still capped at 30 seconds. If the user sets the buffer duration to 100 seconds, the save path asks for the last 100 seconds, but the ring buffers can only provide roughly the last 30 seconds because older samples have already been evicted.

This also explains the menu bar mismatch: the menu action can say `Save Last 100 Seconds`, while the buffer status below it still shows about `00:29` or `00:30`. Those two labels come from different pieces of state. The save label reads the configured setting, but the buffer status reads the real duration currently retained by the video ring buffer.

## Why It Happens

The setting is stored in `AppSettings.bufferDurationSeconds` and is read when the user saves a clip:

- `Sources/App/AppDelegate.swift` calls `saveClip(lastSeconds: TimeInterval(AppSettings.bufferDurationSeconds))`.
- `Sources/Save/ClipSaver.swift` then requests `videoRingBuffer.samples(last: lastSeconds)` and matching audio samples for that requested window.
- `Sources/UI/MenuBar/StatusItemController.swift` uses the same setting to label the menu item as `Save Last N Seconds`.

The menu bar buffer status is different. `Sources/App/AppDelegate.swift` periodically reads `videoRingBuffer.duration` and passes that to `MenuBarState`, which formats it as `Buffer: mm:ss / memory`. That value is the actual retained sample duration, not the configured target duration.

However, the buffers that hold the captured samples are created with no configured duration:

- `videoRingBuffer = VideoRingBuffer()`
- `dualDisplay1VideoRingBuffer = VideoRingBuffer()`
- `dualDisplay2VideoRingBuffer = VideoRingBuffer()`
- `systemAudioRingBuffer = AudioRingBuffer()`
- `micAudioRingBuffer = AudioRingBuffer()`

Both ring buffer types default to 30 seconds:

- `VideoRingBuffer.init(timeCap: TimeInterval = 30.0, ...)`
- `AudioRingBuffer.init(timeCap: TimeInterval = 30.0, ...)`

Each buffer evicts old samples during append once its internal `timeCap` is exceeded. Because the app never passes `AppSettings.bufferDurationSeconds` into the ring buffers, changing the UI setting only changes how much time the save operation requests. It does not change how much history is retained.

That means a 100-second save request is made against buffers that have already discarded everything older than about 30 seconds.

In the UI, this produces exactly the observed state:

- `Save Last 100 Seconds` because the settings value is 100.
- `Buffer: 00:29 / ...` because the active video ring buffer is still retaining only about 30 seconds.

## Permanent Fix

Make the configured buffer duration the single source of truth for both retention and saving.

The app should construct or configure every video and audio ring buffer with `AppSettings.bufferDurationSeconds`, not with the ring buffer default. This needs to include:

- the main video ring buffer,
- both dual-display video ring buffers,
- the system audio ring buffer,
- the microphone audio ring buffer.

The fix should also handle runtime settings changes. If the user changes the buffer duration while ReplayMac is running, the active ring buffers must be updated or rebuilt so future retention follows the new duration. Increasing the duration cannot recover already-evicted samples, but it should allow the buffers to grow up to the new limit from that point forward. Decreasing the duration should trim existing buffers down to the new limit.

For a durable design, avoid leaving `30.0` as an implicit production default in the app path. The ring buffer default is fine for tests, but the application should always pass an explicit configured duration so the UI setting, retained samples, menu bar buffer display, and saved clip length all describe the same behavior.

Add regression coverage that creates app-style buffers with a non-default duration, appends more than 30 seconds of samples, and verifies that saving or sample extraction can return the configured window, subject to keyframe alignment and memory limits.
